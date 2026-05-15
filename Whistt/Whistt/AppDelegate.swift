import AppKit
import ApplicationServices

enum OutputMode: String {
    case typing
    case clipboard
}

private enum StatusIcon {
    case idle
    case active
    case warning
}

// Models known to work over the GA Realtime WS endpoint (validated via realtime-probe).
// Grouped by transcription delivery: streaming sends per-word deltas live, final-only
// returns the entire transcript at commit time.
private struct ModelGroup {
    let title: String
    let models: [String]
}

private let modelGroups: [ModelGroup] = [
    ModelGroup(title: "Realtime (streaming deltas)", models: [
        "gpt-realtime-whisper",
    ]),
    ModelGroup(title: "Final-only (no deltas)", models: [
        "gpt-4o-transcribe",
        "gpt-4o-mini-transcribe",
        "whisper-1",
    ]),
]

private let availableModels: [String] = modelGroups.flatMap(\.models)
private let defaultModel = availableModels[0]

private func groupTitle(forModel name: String) -> String? {
    modelGroups.first { $0.models.contains(name) }?.title
}

private let modelDefaultsKey = "WHISTT_MODEL"
private let apiKeyKeychainAccount = "OPENAI_API_KEY"
private let envMigrationNoticeKey = "WHISTT_ENV_MIGRATION_NOTICE_SHOWN"
private let shortcutKeyCodeDefaultsKey = "WHISTT_SHORTCUT_KEYCODE"
private let shortcutModifiersDefaultsKey = "WHISTT_SHORTCUT_MODIFIERS"

private let shortcutPresets: [HotKey] = [
    HotKey(keyCode: 49, modifiers: .maskAlternate),
    HotKey(keyCode: 49, modifiers: .maskControl),
    HotKey(keyCode: 49, modifiers: [.maskCommand, .maskAlternate]),
    HotKey(keyCode: 50, modifiers: .maskAlternate),
]

private let defaultHotKey = shortcutPresets[0]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private var agent: WhisperNativeAgent?
    private var outputMode: OutputMode = .typing
    private var apiKey: String?
    private var currentModel: String = ""
    private var currentHotKey: HotKey = defaultHotKey

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        guard let key = resolveAPIKey() else {
            NSApp.terminate(nil)
            return
        }

        self.apiKey = key

        let savedModel = UserDefaults.standard.string(forKey: modelDefaultsKey)
        let envModel = EnvLoader.value(for: "WHISTT_MODEL")
        currentModel = savedModel ?? envModel ?? defaultModel

        if let kc = UserDefaults.standard.object(forKey: shortcutKeyCodeDefaultsKey) as? NSNumber,
           let mods = UserDefaults.standard.object(forKey: shortcutModifiersDefaultsKey) as? NSNumber {
            currentHotKey = HotKey(keyCode: kc.int64Value, modifiers: CGEventFlags(rawValue: mods.uint64Value))
        }
        hotKey.hotKey = currentHotKey

        rebuildAgent()
        rebuildMenu()

        hotKey.onStart = { [weak self] in
            DispatchQueue.main.async {
                self?.setStatusIcon(.active)
                self?.agent?.start()
            }
        }
        hotKey.onStop = { [weak self] in
            DispatchQueue.main.async {
                self?.setStatusIcon(.idle)
                self?.agent?.stop()
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
            return
        }
        let agent = WhisperNativeAgent(apiKey: key, model: currentModel)
        agent.onTranscriptDelta = { [weak self] delta in
            DispatchQueue.main.async { self?.handle(delta: delta) }
        }
        agent.onTranscriptComplete = { [weak self] full in
            DispatchQueue.main.async { self?.handleFinal(full) }
        }
        agent.onError = { [weak self] msg in
            WhisttLog.error(msg)
            DispatchQueue.main.async {
                self?.setStatusIcon(.warning)
            }
        }
        self.agent = agent
    }

    private func handle(delta: String) {
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
        if outputMode == .clipboard {
            ClipboardOutput.set(full)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon(.idle)
    }

    private func setStatusIcon(_ icon: StatusIcon) {
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

        let shortcutTitle = currentHotKey.displayName
        let shortcutHeader = NSMenuItem(title: "Shortcut: \(shortcutTitle)", action: nil, keyEquivalent: "")
        let shortcutSubmenu = NSMenu()
        for (idx, preset) in shortcutPresets.enumerated() {
            let it = NSMenuItem(title: preset.displayName, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            it.target = self
            it.state = (preset == currentHotKey) ? .on : .off
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

        let setKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(setAPIKey(_:)), keyEquivalent: "")
        setKeyItem.target = self
        menu.addItem(setKeyItem)

        let clearKeyItem = NSMenuItem(title: "Clear API Key", action: #selector(clearAPIKey(_:)), keyEquivalent: "")
        clearKeyItem.target = self
        menu.addItem(clearKeyItem)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Hold \(shortcutTitle) to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func resolveAPIKey() -> String? {
        if let raw = ProcessInfo.processInfo.environment[apiKeyKeychainAccount] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let stored = KeychainStore.value(for: apiKeyKeychainAccount) {
            return stored
        }
        if let legacy = EnvLoader.value(for: apiKeyKeychainAccount) {
            if KeychainStore.set(legacy, for: apiKeyKeychainAccount) {
                WhisttLog.event("migrated \(apiKeyKeychainAccount) from .env to Keychain")
                showMigrationNoticeIfNeeded()
            }
            return legacy
        }
        return promptForAPIKey(initial: nil)
    }

    private func showMigrationNoticeIfNeeded() {
        if UserDefaults.standard.bool(forKey: envMigrationNoticeKey) { return }
        UserDefaults.standard.set(true, forKey: envMigrationNoticeKey)
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(
                title: "API key moved to Keychain",
                message: "OPENAI_API_KEY was copied from your .env into the macOS Keychain. You can remove the line from .env — Whistt will not read it again."
            )
        }
    }

    private func promptForAPIKey(initial: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Paste your OpenAI API key. It will be stored in the macOS Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-..."
        if let initial = initial { field.stringValue = initial }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == initial { return value }
        if !KeychainStore.set(value, for: apiKeyKeychainAccount) {
            showAlert(title: "Failed to save API key",
                      message: "Could not write to the macOS Keychain.")
            return nil
        }
        return value
    }

    @objc private func setAPIKey(_ sender: NSMenuItem) {
        guard let newKey = promptForAPIKey(initial: apiKey), newKey != apiKey else { return }
        apiKey = newKey
        rebuildAgent()
        setStatusIcon(.idle)
    }

    @objc private func clearAPIKey(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Clear API key?"
        alert.informativeText = "The key will be removed from the macOS Keychain. Use Set API Key… to enter a new key without relaunching."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = KeychainStore.delete(for: apiKeyKeychainAccount)
        // Drop the agent immediately; the user explicitly revoked the key, so any in-flight
        // transcript draining over the 3s grace is acceptable to lose.
        agent?.stop()
        agent = nil
        apiKey = nil
        setStatusIcon(.warning)
        rebuildMenu()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != currentModel else { return }
        WhisttLog.event("switching model: \(currentModel) -> \(name)")
        currentModel = name
        UserDefaults.standard.set(name, forKey: modelDefaultsKey)
        rebuildAgent()
        rebuildMenu()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard shortcutPresets.indices.contains(idx) else { return }
        applyHotKey(shortcutPresets[idx])
    }

    @objc private func customizeShortcut(_ sender: NSMenuItem) {
        presentShortcutRecorder()
    }

    private func applyHotKey(_ newHotKey: HotKey) {
        guard newHotKey != currentHotKey else { return }
        WhisttLog.event("switching shortcut: \(currentHotKey.displayName) -> \(newHotKey.displayName)")
        currentHotKey = newHotKey
        UserDefaults.standard.set(NSNumber(value: newHotKey.keyCode), forKey: shortcutKeyCodeDefaultsKey)
        UserDefaults.standard.set(NSNumber(value: newHotKey.modifiers.rawValue), forKey: shortcutModifiersDefaultsKey)
        hotKey.updateHotKey(newHotKey)
        rebuildMenu()
    }

    private func presentShortcutRecorder() {
        // Stop the global tap so the existing shortcut doesn't fire during recording.
        hotKey.stop()
        defer { hotKey.start() }

        let alert = NSAlert()
        alert.messageText = "Record Shortcut"
        alert.informativeText = "Press a combination with at least one of ⌘ ⌥ ⌃ ⇧.\nThen release the keys and click Save (or press Return)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let label = NSTextField(labelWithString: "Press a key combination…")
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        alert.accessoryView = label

        let saveButton = alert.buttons[0]
        saveButton.isEnabled = false

        var captured: HotKey?
        let modifierSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(modifierSet)
            let cgFlags = CGEventFlags(rawValue: UInt64(mods.rawValue))

            switch event.type {
            case .flagsChanged:
                // Once something has been captured, leave the display alone so the user can
                // release the keys without thinking the binding was lost.
                if captured == nil {
                    if mods.isEmpty {
                        label.stringValue = "Press a key combination…"
                    } else {
                        label.stringValue = HotKey.modifierSymbols(for: cgFlags) + " + …"
                    }
                }
                return nil
            case .keyDown:
                guard !mods.isEmpty else { return event }
                let hot = HotKey(keyCode: Int64(event.keyCode), modifiers: cgFlags)
                captured = hot
                label.stringValue = "Captured: \(hot.displayName)"
                saveButton.isEnabled = true
                return nil
            default:
                return event
            }
        }
        defer { if let m = monitor { NSEvent.removeMonitor(m) } }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let hot = captured else { return }
        applyHotKey(hot)
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
}
