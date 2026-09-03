import AppKit
import ApplicationServices
import CoreGraphics

enum OutputMode: String {
    case typing
    case clipboard
}

private enum StatusIcon: Equatable {
    case idle
    case active
    case processing
    case warning
}

// Models known to work over the GA Realtime WS endpoint (validated via realtime-probe).
// Grouped by transcription delivery: streaming sends per-word deltas live, final-only
// returns the entire transcript at commit time.
private struct ModelGroup {
    let title: String
    let provider: TranscriptionProvider
    let streamsDeltas: Bool
    let models: [String]
}

private let modelGroups: [ModelGroup] = [
    ModelGroup(title: "OpenAI — realtime", provider: .openAI, streamsDeltas: true, models: [
        "gpt-realtime-whisper",
    ]),
    ModelGroup(title: "Google Gemini — final only", provider: .gemini, streamsDeltas: false, models: [
        "gemini-3.5-transcribe-live",
    ]),
    ModelGroup(title: "Meta — final only", provider: .meta, streamsDeltas: false, models: [
        "muse-voice-transcribe-1.0",
    ]),
]

private let availableModels: [String] = modelGroups.flatMap(\.models)
private let defaultModel = availableModels[0]

private func groupTitle(forModel name: String) -> String? {
    modelGroups.first { $0.models.contains(name) }?.title
}

private let modelDefaultsKey = "WHISTT_MODEL"
private let envMigrationNoticeKey = "WHISTT_ENV_MIGRATION_NOTICE_SHOWN"

private let shortcutPresets: [ShortcutBinding] = [
    .chord(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue),
    .chord(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue),
    .chord(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue),
    .chord(keyCode: 50, modifiers: CGEventFlags.maskAlternate.rawValue),
]

private let defaultBinding = shortcutPresets[0]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private var agent: WhisperNativeAgent?
    private var outputMode: OutputMode = .typing
    private var apiKey: String?
    private var currentModel: String = ""
    private var currentBinding: ShortcutBinding = defaultBinding
    private var currentStatusIcon: StatusIcon = .idle
    private var transcriptionFailed = false
    private var lastPresentedTranscriptionError: String?
    // Set when a cancelled shortcut gesture discards an in-flight capture;
    // its pending deltas and final transcript are ignored.
    private var discardCurrentCapture = false
    private lazy var apiKeysWindowController: APIKeysWindowController = {
        let controller = APIKeysWindowController()
        controller.onKeysChanged = { [weak self] in
            self?.reloadCurrentAPIKey()
        }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let savedModel = UserDefaults.standard.string(forKey: modelDefaultsKey)
        let envModel = EnvLoader.value(for: "WHISTT_MODEL")
        let preferredModel = savedModel ?? envModel
        currentModel = preferredModel.flatMap { availableModels.contains($0) ? $0 : nil } ?? defaultModel
        if savedModel != nil, savedModel != currentModel {
            UserDefaults.standard.set(currentModel, forKey: modelDefaultsKey)
        }
        self.apiKey = resolveAPIKey(for: currentProvider)

        if let stored = ShortcutBindingStore.load(defaults: .standard) {
            currentBinding = stored
        } else {
            currentBinding = defaultBinding
            WhisttLog.event("no valid stored shortcut; falling back to default binding")
        }
        hotKey.updateBinding(currentBinding)

        rebuildAgent()
        rebuildMenu()

        hotKey.onStart = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let agent = self.agent else {
                    self.setStatusIcon(.warning)
                    return
                }
                self.transcriptionFailed = false
                self.discardCurrentCapture = false
                self.lastPresentedTranscriptionError = nil
                self.setStatusIcon(.active)
                SoundFeedback.playRecordingStarted()
                agent.start()
            }
        }
        hotKey.onStop = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let agent = self.agent else {
                    self.setStatusIcon(.warning)
                    return
                }
                let awaitingFinal = agent.stop()
                if self.transcriptionFailed {
                    self.setStatusIcon(.warning)
                } else {
                    self.setStatusIcon(awaitingFinal ? .processing : .idle)
                }
                // Network failures already switch to warning. This fallback prevents a
                // permanently spinning state if a provider closes without a final event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.currentStatusIcon == .processing else { return }
                    self.setStatusIcon(.idle)
                }
            }
        }
        hotKey.onDiscard = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // A cancelled gesture must not type or copy anything from the
                // discarded capture.
                self.discardCurrentCapture = true
                _ = self.agent?.stop()
                if self.currentStatusIcon == .active { self.setStatusIcon(.idle) }
                WhisttLog.event("capture discarded: shortcut gesture cancelled")
            }
        }
        hotKey.start()
        if !hotKey.isRunning {
            setStatusIcon(.warning)
        }

        ensureAccessibility()
        startAccessibilityWatchdog()
    }

    private func startAccessibilityWatchdog() {
        // Until Accessibility is granted, CGEvent.tapCreate fails silently and ⌥+Space leaks
        // through to the focused app. Poll until granted, then retry the tap — avoids the
        // "must relaunch after granting" footgun.
        guard !hotKey.isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if self.hotKey.isRunning { return }
            if AXIsProcessTrusted() {
                self.hotKey.start()
                if self.hotKey.isRunning {
                    self.setStatusIcon(.idle)
                    return
                }
            }
            self.startAccessibilityWatchdog()
        }
    }

    private func rebuildAgent() {
        agent?.stop()
        guard let key = apiKey else {
            agent = nil
            setStatusIcon(.warning)
            return
        }
        let agent = WhisperNativeAgent(apiKey: key, model: currentModel, provider: currentProvider)
        agent.onTranscriptDelta = { [weak self] delta in
            DispatchQueue.main.async { self?.handle(delta: delta) }
        }
        agent.onTranscriptComplete = { [weak self] full in
            DispatchQueue.main.async { self?.handleFinal(full) }
        }
        agent.onError = { [weak self] msg in
            WhisttLog.error(msg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.transcriptionFailed = true
                // Stop capturing immediately. Once the transport has failed,
                // continuing to record only makes the user speak into a dead
                // session and that audio cannot be recovered.
                _ = self.agent?.stop()
                self.setStatusIcon(.warning)
                let message = self.userFacingTranscriptionError(from: msg)
                self.presentTranscriptionError(message)
            }
        }
        self.agent = agent
    }

    private func handle(delta: String) {
        if discardCurrentCapture { return }
        switch outputMode {
        case .typing:
            TypingEmulator.type(delta)
        case .clipboard:
            // Writing per-delta would spam clipboard-history tools with every intermediate
            // state. Wait for the final transcript so only one entry is captured.
            break
        }
    }

    private func handleFinal(_ full: String) {
        if discardCurrentCapture {
            // The capture was cancelled; swallow the final transcript and
            // re-enable normal output for the next hold.
            discardCurrentCapture = false
            WhisttLog.event("final transcript discarded (cancelled capture, \(full.count) chars)")
            return
        }
        switch outputMode {
        case .typing where !currentModelStreamsDeltas:
            TypingEmulator.type(full)
        case .clipboard:
            ClipboardOutput.set(full)
        case .typing:
            // Streaming models have already typed every delta; typing the final again
            // would duplicate the transcript.
            break
        }
        WhisttLog.event("timing provider=\(currentProvider.rawValue) milestone=output_applied mode=\(outputMode.rawValue) chars=\(full.count)")
        if currentStatusIcon != .active { setStatusIcon(.idle) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon(.idle)
    }

    private func setStatusIcon(_ icon: StatusIcon) {
        currentStatusIcon = icon
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tint: NSColor?
        switch icon {
        case .idle:
            symbolName = "mic"
            tint = nil
        case .active:
            symbolName = "mic.fill"
            tint = .systemRed
        case .processing:
            symbolName = "ellipsis.circle.fill"
            tint = .systemBlue
        case .warning:
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemOrange
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Whistt")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.title = ""
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let typingItem = NSMenuItem(title: "Output: Type at cursor", action: #selector(setTyping(_:)), keyEquivalent: "")
        typingItem.target = self
        typingItem.state = (outputMode == .typing) ? .on : .off
        menu.addItem(typingItem)

        let clipboardItem = NSMenuItem(title: "Output: Clipboard", action: #selector(setClipboard(_:)), keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.state = (outputMode == .clipboard) ? .on : .off
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        let modelHeaderTitle: String
        if let kind = groupTitle(forModel: currentModel) {
            modelHeaderTitle = "Model: \(currentModel) (\(kind))"
        } else {
            modelHeaderTitle = "Model: \(currentModel)"
        }
        let modelHeader = NSMenuItem(title: modelHeaderTitle, action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()
        for (idx, group) in modelGroups.enumerated() {
            if idx > 0 { modelSubmenu.addItem(.separator()) }
            let section = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            section.isEnabled = false
            modelSubmenu.addItem(section)
            for name in group.models {
                let it = NSMenuItem(title: name, action: #selector(selectModel(_:)), keyEquivalent: "")
                it.target = self
                it.state = (name == currentModel) ? .on : .off
                it.representedObject = name
                modelSubmenu.addItem(it)
            }
        }
        modelHeader.submenu = modelSubmenu
        menu.addItem(modelHeader)

        let shortcutTitle = currentBinding.displayName
        let shortcutHeader = NSMenuItem(title: "Shortcut: \(shortcutTitle)", action: nil, keyEquivalent: "")
        let shortcutSubmenu = NSMenu()
        for (idx, preset) in shortcutPresets.enumerated() {
            let it = NSMenuItem(title: preset.displayName, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            it.target = self
            it.state = (preset == currentBinding) ? .on : .off
            it.tag = idx
            shortcutSubmenu.addItem(it)
        }
        shortcutSubmenu.addItem(.separator())
        let customizeItem = NSMenuItem(title: "Customize…", action: #selector(customizeShortcut(_:)), keyEquivalent: "")
        customizeItem.target = self
        shortcutSubmenu.addItem(customizeItem)
        shortcutHeader.submenu = shortcutSubmenu
        menu.addItem(shortcutHeader)

        menu.addItem(.separator())

        let apiKeysItem = NSMenuItem(title: "API Keys…", action: #selector(showAPIKeys(_:)), keyEquivalent: "")
        apiKeysItem.target = self
        menu.addItem(apiKeysItem)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Hold \(shortcutTitle) to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var currentProvider: TranscriptionProvider {
        modelGroups.first { $0.models.contains(currentModel) }?.provider ?? .openAI
    }

    private var currentModelStreamsDeltas: Bool {
        modelGroups.first { $0.models.contains(currentModel) }?.streamsDeltas ?? false
    }

    private func resolveAPIKey(for provider: TranscriptionProvider, promptIfMissing: Bool = true) -> String? {
        let account = provider.apiKeyAccount
        // The settings window writes to Keychain, so a saved value must be
        // authoritative. Environment and .env values are legacy/development
        // fallbacks used only to seed Keychain when no saved value exists.
        if let stored = KeychainStore.value(for: account) {
            return stored
        }
        if let legacy = EnvLoader.value(for: account) {
            if KeychainStore.set(legacy, for: account) {
                WhisttLog.event("migrated \(account) from .env to Keychain")
                showMigrationNoticeIfNeeded()
            }
            return legacy
        }
        return promptIfMissing ? promptForAPIKey(provider: provider, initial: nil) : nil
    }

    private func showMigrationNoticeIfNeeded() {
        if UserDefaults.standard.bool(forKey: envMigrationNoticeKey) { return }
        UserDefaults.standard.set(true, forKey: envMigrationNoticeKey)
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(
                title: "API key moved to Keychain",
                message: "An API key was copied from your .env into the macOS Keychain. You can remove that entry from .env."
            )
        }
    }

    private func promptForAPIKey(provider: TranscriptionProvider, initial: String?) -> String? {
        let alert = NSAlert()
        let label = provider.displayName
        alert.messageText = "\(label) API Key"
        alert.informativeText = "Paste your \(label) API key. It will be stored in the macOS Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        switch provider {
        case .openAI: field.placeholderString = "sk-..."
        case .gemini: field.placeholderString = "Gemini API key"
        case .meta: field.placeholderString = "Meta Model API key"
        }
        if let initial = initial { field.stringValue = initial }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == initial { return value }
        if !KeychainStore.set(value, for: provider.apiKeyAccount) {
            showAlert(title: "Failed to save API key",
                      message: "Could not write to the macOS Keychain.")
            return nil
        }
        return value
    }

    @objc private func showAPIKeys(_ sender: NSMenuItem) {
        apiKeysWindowController.present()
    }

    private func reloadCurrentAPIKey() {
        apiKey = resolveAPIKey(for: currentProvider, promptIfMissing: false)
        rebuildAgent()
        rebuildMenu()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != currentModel else { return }
        WhisttLog.event("switching model: \(currentModel) -> \(name)")
        currentModel = name
        UserDefaults.standard.set(name, forKey: modelDefaultsKey)
        apiKey = resolveAPIKey(for: currentProvider)
        rebuildAgent()
        rebuildMenu()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard shortcutPresets.indices.contains(idx) else { return }
        applyBinding(shortcutPresets[idx])
    }

    @objc private func customizeShortcut(_ sender: NSMenuItem) {
        // Let status-menu tracking finish before opening a modal window. LSUIElement apps
        // can otherwise leave keyboard focus on the previously active application, causing
        // the local event monitor in the recorder to receive no key events.
        DispatchQueue.main.async { [weak self] in
            self?.presentShortcutRecorder()
        }
    }

    private func applyBinding(_ newBinding: ShortcutBinding) {
        guard newBinding != currentBinding else { return }
        WhisttLog.event("switching shortcut: \(currentBinding.displayName) -> \(newBinding.displayName)")
        currentBinding = newBinding
        ShortcutBindingStore.save(newBinding, defaults: .standard)
        hotKey.updateBinding(newBinding)
        rebuildMenu()
    }

    private func presentShortcutRecorder() {
        // Stop the global tap so the existing shortcut doesn't fire during recording.
        hotKey.stop()
        defer { hotKey.start() }

        // Remember the app the user was working in; reactivate it after Save or
        // Cancel so dictation returns to the original target.
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        defer {
            previousApp?.activate(options: [])
        }

        let alert = NSAlert()
        alert.messageText = "Record Shortcut"
        alert.informativeText = "Press a combination with at least one of ⌘ ⌥ ⌃ ⇧,\nor hold and release a single modifier key for push-to-talk.\nThen click Save (or press Return)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let label = NSTextField(labelWithString: "Press a key combination…")
        label.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        alert.accessoryView = label

        let saveButton = alert.buttons[0]
        saveButton.isEnabled = false

        var captured: ShortcutBinding?
        // A single modifier currently held, waiting to become a modifier-only
        // binding once released without any other key pressed in between.
        var modifierCandidate: (keyCode: Int64, flag: UInt64)?
        var otherKeyPressed = false
        let modifierSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(modifierSet)
            let cgFlags = CGEventFlags(rawValue: UInt64(mods.rawValue))

            switch event.type {
            case .flagsChanged:
                let keyCode = Int64(event.keyCode)
                let flag = ShortcutBinding.modifierFlag(forKeyCode: keyCode)

                if let flag, event.modifierFlags.contains(Self.nsFlag(for: flag)) {
                    // A modifier just went down. A modifier-only candidate is
                    // only valid when that is the sole modifier held.
                    let nsFlag = Self.nsFlag(for: flag)
                    if captured == nil && modifierCandidate == nil && mods == nsFlag {
                        modifierCandidate = (keyCode, flag)
                        otherKeyPressed = false
                        label.stringValue = "Hold \(ShortcutBinding.modifierKeyName(for: keyCode)) and release to capture…"
                    } else if modifierCandidate != nil {
                        // A second modifier invalidates the modifier-only candidate.
                        modifierCandidate = nil
                        label.stringValue = ShortcutBinding.modifierSymbols(for: cgFlags.rawValue) + " + …"
                    }
                    return nil
                }
                // A modifier went up.
                if let candidate = modifierCandidate, candidate.keyCode == keyCode, !otherKeyPressed {
                    captured = .modifierOnly(keyCode: candidate.keyCode, modifier: candidate.flag)
                    modifierCandidate = nil
                    label.stringValue = "Captured: \(captured!.displayName) (hold to talk)"
                    saveButton.isEnabled = true
                } else if modifierCandidate != nil {
                    modifierCandidate = nil
                }
                if captured == nil {
                    if mods.isEmpty {
                        label.stringValue = "Press a key combination…"
                    } else {
                        label.stringValue = ShortcutBinding.modifierSymbols(for: cgFlags.rawValue) + " + …"
                    }
                }
                return nil
            case .keyDown:
                if modifierCandidate != nil { otherKeyPressed = true }
                guard !mods.isEmpty else { return event }
                let hot = ShortcutBinding.chord(keyCode: Int64(event.keyCode), modifiers: cgFlags.rawValue)
                captured = hot
                modifierCandidate = nil
                label.stringValue = "Captured: \(hot.displayName)"
                saveButton.isEnabled = true
                return nil
            default:
                return event
            }
        }
        defer { if let m = monitor { NSEvent.removeMonitor(m) } }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let binding = captured, binding.isValid else { return }
        applyBinding(binding)
    }

    private static func nsFlag(for cgFlag: UInt64) -> NSEvent.ModifierFlags {
        switch cgFlag {
        case CGEventFlags.maskCommand.rawValue: return .command
        case CGEventFlags.maskControl.rawValue: return .control
        case CGEventFlags.maskAlternate.rawValue: return .option
        case CGEventFlags.maskShift.rawValue: return .shift
        default: return []
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.shutdown()
    }

    @objc private func setTyping(_ sender: NSMenuItem) {
        outputMode = .typing
        rebuildMenu()
    }

    @objc private func setClipboard(_ sender: NSMenuItem) {
        outputMode = .clipboard
        rebuildMenu()
    }

    private func ensureAccessibility() {
        let opts: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            NSLog("[Whistt] Accessibility permission required. Grant in System Settings → Privacy & Security → Accessibility.")
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func userFacingTranscriptionError(from technicalMessage: String) -> String {
        if technicalMessage.contains("Incorrect API key") {
            return "The API key was rejected. Open API Keys… and save a valid key, then try again."
        }
        if technicalMessage.contains("Meta"),
           technicalMessage.contains("Protocol error") {
            return "The connection to Meta was interrupted while transcribing. No text was inserted. Please try speaking again or switch to another model."
        }
        return "Transcription failed, so no text was inserted. Please try again. Technical details were written to debug.log."
    }

    private func presentTranscriptionError(_ message: String) {
        guard message != lastPresentedTranscriptionError else { return }
        lastPresentedTranscriptionError = message
        showAlert(title: "Transcription Failed", message: message)
    }
}
