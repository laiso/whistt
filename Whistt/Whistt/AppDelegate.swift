import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ServiceManagement

private enum StatusIcon: Equatable {
    case idle
    case active
    case processing
    case warning
}

// Models known to work with Whistt's push-to-talk lifecycle.
struct ModelGroup: Identifiable {
    let vendor: String
    let provider: TranscriptionProvider
    let models: [String]

    var id: String { "\(vendor):\(models.joined(separator: ","))" }
}

let modelGroups: [ModelGroup] = [
    ModelGroup(vendor: "OpenAI", provider: .openAI, models: [
        "gpt-transcribe",
        "gpt-live-transcribe",
    ]),
    ModelGroup(vendor: "Google", provider: .gemini, models: [
        "gemini-3.5-transcribe-live",
    ]),
    ModelGroup(vendor: "Meta", provider: .meta, models: [
        "muse-voice-transcribe-1.0",
    ]),
    ModelGroup(vendor: "xAI", provider: .xAI, models: [
        "xai-streaming-stt",
    ]),
    ModelGroup(vendor: "Microsoft", provider: .azure, models: [
        "mai-transcribe-2",
    ]),
]

let modelReferencePricePerHour: [String: String] = [
    "mai-transcribe-2": "$0.10*",
    "muse-voice-transcribe-1.0": "$0.18",
    "xai-streaming-stt": "$0.20",
    "gpt-transcribe": "$0.27",
    "gemini-3.5-transcribe-live": "~$0.54",
    "gpt-live-transcribe": "$1.02",
]

func modelDisplayName(_ name: String, vendor: String) -> String {
    guard let price = modelReferencePricePerHour[name] else { return "\(vendor) · \(name)" }
    return "\(vendor) · \(name) · \(price)/hour"
}

private let availableModels: [String] = modelGroups.flatMap(\.models)
private let defaultModel = availableModels[0]

private func vendorName(forModel name: String) -> String? {
    modelGroups.first { $0.models.contains(name) }?.vendor
}

private let modelDefaultsKey = "WHISTT_MODEL"
private let envMigrationNoticeKey = "WHISTT_ENV_MIGRATION_NOTICE_SHOWN"

enum SettingsTab: String, Hashable {
    case general
    case shortcut
    case providers
}

extension ProviderConfigurationStatus {
    var title: String {
        switch self {
        case .configured: return "Configured"
        case .notConfigured: return "Not configured"
        case .endpointMissing: return "Endpoint missing"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private var agent: WhisperNativeAgent?
    @Published private(set) var outputMode: OutputMode = .typing
    private var apiKey: String?
    @Published private(set) var currentModel: String = ""
    @Published private(set) var currentBinding: ShortcutBinding = .defaultBinding
    @Published private(set) var playsRecordingStartSound = true
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published private(set) var providerConfigurationRevision = 0
    private lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
    private lazy var providerConfiguration = ProviderConfigurationService(
        containsKey: { KeychainStore.contains(account: $0) },
        saveKey: { KeychainStore.set($0, for: $1) },
        deleteKey: { KeychainStore.delete(for: $0) },
        storedAzureEndpoint: { AzureVoiceLiveSettings.storedEndpoint() },
        resolvedAzureEndpoint: { AzureVoiceLiveSettings.resolveEndpoint() },
        saveAzureEndpoint: { AzureVoiceLiveSettings.saveEndpoint($0) },
        removeAzureEndpoint: { AzureVoiceLiveSettings.removeEndpoint() }
    )
    private var currentStatusIcon: StatusIcon = .idle
    private var transcriptionFailed = false
    private var lastPresentedTranscriptionError: String?
    // Set when a cancelled shortcut gesture discards an in-flight capture;
    // its pending final transcript is ignored.
    private var discardCurrentCapture = false
    // Modifier-only gestures remain cancellable until the modifier is released.
    // Keep their output local so a later Control-C/mouse press cannot leave
    // already-typed text behind.
    private var modifierOnlyCapturePending = false
    private var bufferedModifierOnlyFinals: [String] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        outputMode = AppPreferences.outputMode()
        playsRecordingStartSound = AppPreferences.playsRecordingStartSound()

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
            currentBinding = .defaultBinding
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
                self.modifierOnlyCapturePending = self.currentBinding.isModifierOnly
                self.bufferedModifierOnlyFinals.removeAll(keepingCapacity: true)
                self.lastPresentedTranscriptionError = nil
                self.setStatusIcon(.active)
                if self.playsRecordingStartSound {
                    SoundFeedback.playRecordingStarted()
                }
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
                self.commitModifierOnlyOutputIfNeeded()
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
                self.modifierOnlyCapturePending = false
                self.bufferedModifierOnlyFinals.removeAll(keepingCapacity: true)
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

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["WHISTT_FORCE_LIGHT_APPEARANCE"] == "1" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if let settingsTab = SettingsTab(rawValue: environment["WHISTT_SHOW_SETTINGS"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettings(settingsTab)
            }
        }
        #endif
    }

    private func startAccessibilityWatchdog() {
        // Until Accessibility is granted, CGEvent.tapCreate fails silently and the shortcut leaks
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

    private func handleFinal(_ full: String) {
        if discardCurrentCapture {
            // The capture was cancelled; keep swallowing every result from
            // this session. The next successful onStart resets the flag after
            // WhisperNativeAgent has advanced its session generation.
            WhisttLog.event("final transcript discarded (cancelled capture, \(full.count) chars)")
            return
        }
        if modifierOnlyCapturePending {
            bufferedModifierOnlyFinals.append(full)
            return
        }
        outputFinal(full)
    }

    private func outputFinal(_ full: String) {
        switch outputMode {
        case .typing:
            TypingEmulator.type(full)
        case .clipboard:
            ClipboardOutput.set(full)
        }
        WhisttLog.event("timing provider=\(currentProvider.rawValue) milestone=output_applied mode=\(outputMode.rawValue) chars=\(full.count)")
        if currentStatusIcon != .active { setStatusIcon(.idle) }
    }

    private func commitModifierOnlyOutputIfNeeded() {
        guard modifierOnlyCapturePending else { return }
        modifierOnlyCapturePending = false

        let finals = bufferedModifierOnlyFinals
        bufferedModifierOnlyFinals.removeAll(keepingCapacity: true)
        finals.forEach(outputFinal)
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
        if let vendor = vendorName(forModel: currentModel) {
            modelHeaderTitle = "Model: \(vendor) · \(currentModel)"
        } else {
            modelHeaderTitle = "Model: \(currentModel)"
        }
        let modelHeader = NSMenuItem(title: modelHeaderTitle, action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()
        for group in modelGroups {
            for name in group.models {
                let it = NSMenuItem(title: modelDisplayName(name, vendor: group.vendor), action: #selector(selectModel(_:)), keyEquivalent: "")
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
        for (idx, preset) in ShortcutBinding.recommended.enumerated() {
            let title = preset == .defaultBinding ? "\(preset.displayName) (Default)" : preset.displayName
            let it = NSMenuItem(title: title, action: #selector(selectShortcut(_:)), keyEquivalent: "")
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    private func resolveAPIKey(for provider: TranscriptionProvider, promptIfMissing: Bool = true) -> String? {
        if provider == .azure { return resolveAzureConfig(promptIfMissing: promptIfMissing) }
        let account = provider.apiKeyAccount
        // `make debug` opts into using the keys exported from the repository's
        // .env without reading or updating Keychain. A missing environment key
        // still falls back to the normal Keychain-based behavior.
        if ProcessInfo.processInfo.environment["WHISTT_PREFER_ENV_API_KEYS"] == "1",
           let environmentValue = ProcessInfo.processInfo.environment[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
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
        if promptIfMissing {
            DispatchQueue.main.async { [weak self] in
                self?.openSettings(.providers)
            }
        }
        return nil
    }

    /// Azure needs both an API key and a Voice Live endpoint. Instead of the
    /// key-only prompt, either piece missing opens Settings → Providers
    /// window so the user can complete the configuration in one place.
    private func resolveAzureConfig(promptIfMissing: Bool) -> String? {
        let account = TranscriptionProvider.azure.apiKeyAccount
        var apiKey: String?
        if let environmentValue = ProcessInfo.processInfo.environment[account]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !environmentValue.isEmpty {
            apiKey = environmentValue
        } else if let stored = KeychainStore.value(for: account) {
            apiKey = stored
        } else if let legacy = EnvLoader.value(for: account) {
            if KeychainStore.set(legacy, for: account) {
                WhisttLog.event("migrated \(account) from .env to Keychain")
                showMigrationNoticeIfNeeded()
            }
            apiKey = legacy
        }

        let endpointResolved = AzureVoiceLiveSettings.resolveEndpoint() != nil
        if apiKey != nil && endpointResolved { return apiKey }
        guard promptIfMissing else { return nil }
        WhisttLog.event(
            "azure configuration incomplete (key=\(apiKey != nil), endpoint=\(endpointResolved)); opening Provider Settings"
        )
        DispatchQueue.main.async { [weak self] in
            self?.openSettings(.providers)
        }
        return nil
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

    @objc private func showSettings(_ sender: NSMenuItem) {
        openSettings(.general)
    }

    private func reloadCurrentAPIKey() {
        apiKey = resolveAPIKey(for: currentProvider, promptIfMissing: false)
        rebuildAgent()
        rebuildMenu()
        providerConfigurationRevision += 1
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != currentModel else { return }
        applyModel(name)
    }

    func applyModel(_ name: String) {
        guard availableModels.contains(name), name != currentModel else { return }
        WhisttLog.event("switching model: \(currentModel) -> \(name)")
        currentModel = name
        UserDefaults.standard.set(name, forKey: modelDefaultsKey)
        apiKey = resolveAPIKey(for: currentProvider)
        rebuildAgent()
        rebuildMenu()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard ShortcutBinding.recommended.indices.contains(idx) else { return }
        applyBinding(ShortcutBinding.recommended[idx])
    }

    @objc private func customizeShortcut(_ sender: NSMenuItem) {
        // Let status-menu tracking finish before opening a modal window. LSUIElement apps
        // can otherwise leave keyboard focus on the previously active application, causing
        // the local event monitor in the recorder to receive no key events.
        DispatchQueue.main.async { [weak self] in
            self?.presentShortcutRecorder()
        }
    }

    func applyBinding(_ newBinding: ShortcutBinding) {
        guard newBinding != currentBinding else { return }
        WhisttLog.event("switching shortcut: \(currentBinding.displayName) -> \(newBinding.displayName)")
        currentBinding = newBinding
        ShortcutBindingStore.save(newBinding, defaults: .standard)
        hotKey.updateBinding(newBinding)
        rebuildMenu()
    }

    func presentShortcutRecorder() {
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

                // `modifierFlags` combines left and right variants. Once this
                // exact key is the candidate, its next flagsChanged event is
                // its release even if the opposite-side key keeps the shared
                // flag set.
                if let candidate = modifierCandidate, candidate.keyCode == keyCode {
                    if !otherKeyPressed {
                        captured = .modifierOnly(keyCode: candidate.keyCode, modifier: candidate.flag)
                        label.stringValue = "Captured: \(captured!.displayName) (hold to talk)"
                        saveButton.isEnabled = true
                    }
                    modifierCandidate = nil
                    return nil
                }

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
                if modifierCandidate != nil {
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

    func setOutputMode(_ mode: OutputMode) {
        guard mode != outputMode else { return }
        outputMode = mode
        AppPreferences.setOutputMode(mode)
        rebuildMenu()
    }

    func setPlaysRecordingStartSound(_ enabled: Bool) {
        guard enabled != playsRecordingStartSound else { return }
        playsRecordingStartSound = enabled
        AppPreferences.setPlaysRecordingStartSound(enabled)
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var launchAtLoginRequiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
            return nil
        } catch {
            objectWillChange.send()
            return error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openSettings(_ tab: SettingsTab) {
        selectedSettingsTab = tab
        // Let launch and status-menu tracking finish before activating the utility window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.settingsWindowController.present()
        }
    }

    func providerConfigurationStatus(for provider: TranscriptionProvider) -> ProviderConfigurationStatus {
        providerConfiguration.status(for: provider)
    }

    func hasProviderConfiguration(for provider: TranscriptionProvider) -> Bool {
        providerConfiguration.hasConfiguration(for: provider)
    }

    func storedAzureEndpoint() -> String {
        AzureVoiceLiveSettings.storedEndpoint() ?? ""
    }

    func saveProviderConfiguration(
        for provider: TranscriptionProvider,
        apiKey rawAPIKey: String,
        azureEndpoint rawEndpoint: String
    ) -> String? {
        switch providerConfiguration.save(
            provider: provider,
            rawAPIKey: rawAPIKey,
            rawAzureEndpoint: rawEndpoint
        ) {
        case .success:
            reloadCurrentAPIKey()
            return nil
        case .failure(let error):
            return providerConfigurationMessage(for: error)
        }
    }

    func removeProviderConfiguration(for provider: TranscriptionProvider) -> String? {
        switch providerConfiguration.remove(provider: provider) {
        case .success:
            reloadCurrentAPIKey()
            return nil
        case .failure(let error):
            return providerConfigurationMessage(for: error)
        }
    }

    private func providerConfigurationMessage(for error: ProviderConfigurationError) -> String {
        switch error {
        case .apiKeyMissing: return "Enter an API key."
        case .endpointMissing: return "Enter the Azure Voice Live endpoint."
        case .endpointInvalid:
            return "Enter an https:// URL with a host name, such as https://<resource>.services.ai.azure.com/."
        case .keySaveFailed: return "Could not save the key to the macOS Keychain."
        case .keyDeleteFailed: return "Could not remove the key from the macOS Keychain."
        }
    }

    func suspendShortcutHandling() {
        hotKey.stop()
    }

    func resumeShortcutHandling() {
        hotKey.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.shutdown()
    }

    @objc private func setTyping(_ sender: NSMenuItem) {
        setOutputMode(.typing)
    }

    @objc private func setClipboard(_ sender: NSMenuItem) {
        setOutputMode(.clipboard)
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
            return "The API key was rejected. Open Settings → Providers and save a valid key, then try again."
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
