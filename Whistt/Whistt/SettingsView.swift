import AppKit
import Combine
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum ToolbarIdentifier {
        static let general = NSToolbarItem.Identifier("Whistt.Settings.General")
        static let shortcut = NSToolbarItem.Identifier("Whistt.Settings.Shortcut")
        static let providers = NSToolbarItem.Identifier("Whistt.Settings.Providers")
    }

    private let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let controller = NSHostingController(rootView: SettingsPaneView(appDelegate: appDelegate))
        let window = NSWindow(contentViewController: controller)
        window.title = "Whistt Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Whistt.Settings.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.toolbar?.selectedItemIdentifier = toolbarIdentifier(for: appDelegate.selectedSettingsTab)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarIdentifier.general, ToolbarIdentifier.shortcut, ToolbarIdentifier.providers, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarIdentifier.general, ToolbarIdentifier.shortcut, ToolbarIdentifier.providers, .flexibleSpace]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarIdentifier.general, ToolbarIdentifier.shortcut, ToolbarIdentifier.providers]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(selectToolbarItem(_:))

        switch itemIdentifier {
        case ToolbarIdentifier.general:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case ToolbarIdentifier.shortcut:
            item.label = "Shortcut"
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcut")
        case ToolbarIdentifier.providers:
            item.label = "Providers"
            item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Providers")
        default:
            return nil
        }
        item.paletteLabel = item.label
        return item
    }

    @objc private func selectToolbarItem(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case ToolbarIdentifier.general: appDelegate.selectedSettingsTab = .general
        case ToolbarIdentifier.shortcut: appDelegate.selectedSettingsTab = .shortcut
        case ToolbarIdentifier.providers: appDelegate.selectedSettingsTab = .providers
        default: return
        }
        window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }

    private func toolbarIdentifier(for tab: SettingsTab) -> NSToolbarItem.Identifier {
        switch tab {
        case .general: return ToolbarIdentifier.general
        case .shortcut: return ToolbarIdentifier.shortcut
        case .providers: return ToolbarIdentifier.providers
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        TabView(selection: $appDelegate.selectedSettingsTab) {
            GeneralSettingsView(appDelegate: appDelegate)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ShortcutSettingsView(appDelegate: appDelegate)
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
                .tag(SettingsTab.shortcut)

            ProviderSettingsView(appDelegate: appDelegate)
                .tabItem { Label("Providers", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.providers)
        }
        .frame(width: 760, height: 480)
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            switch appDelegate.selectedSettingsTab {
            case .general:
                GeneralSettingsView(appDelegate: appDelegate)
            case .shortcut:
                ShortcutSettingsView(appDelegate: appDelegate)
            case .providers:
                ProviderSettingsView(appDelegate: appDelegate)
            }
        }
        .frame(width: 760, height: 480)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var launchAtLogin = false
    @State private var launchAtLoginRequiresApproval = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Output", selection: Binding(
                    get: { appDelegate.outputMode },
                    set: { appDelegate.setOutputMode($0) }
                )) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Model", selection: Binding(
                    get: { appDelegate.currentModel },
                    set: { appDelegate.applyModel($0) }
                )) {
                    ForEach(modelGroups) { group in
                        ForEach(group.models, id: \.self) { model in
                            Text(modelDisplayName(model, vendor: group.vendor)).tag(model)
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch Whistt at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLaunchAtLogin
                ))

                if launchAtLoginRequiresApproval {
                    HStack {
                        Text("Approval is required in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") {
                            appDelegate.openLoginItemsSettings()
                        }
                    }
                }

                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section("Feedback") {
                Toggle("Play sound when recording starts", isOn: Binding(
                    get: { appDelegate.playsRecordingStartSound },
                    set: { appDelegate.setPlaysRecordingStartSound($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            refreshLaunchAtLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLoginStatus()
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        launchError = appDelegate.setLaunchAtLogin(enabled)
        refreshLaunchAtLoginStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = appDelegate.launchAtLoginEnabled
        launchAtLoginRequiresApproval = appDelegate.launchAtLoginRequiresApproval
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var showsRecorder = false

    var body: some View {
        Form {
            Section("Push to Talk") {
                LabeledContent("Current shortcut") {
                    Text(appDelegate.currentBinding.displayName)
                        .monospaced()
                }

                LabeledContent("Preset") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(shortcutOptions, id: \.self) { preset in
                            Button {
                                appDelegate.applyBinding(preset)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: appDelegate.currentBinding == preset
                                          ? "largecircle.fill.circle"
                                          : "circle")
                                        .foregroundStyle(appDelegate.currentBinding == preset
                                                         ? Color.accentColor
                                                         : Color.secondary)
                                    Text(shortcutLabel(for: preset))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(appDelegate.currentBinding == preset ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Text("Hold the shortcut while speaking, then release to transcribe.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Customize…") {
                        showsRecorder = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .sheet(isPresented: $showsRecorder) {
            ShortcutRecorderSheet(appDelegate: appDelegate)
        }
    }

    private var shortcutOptions: [ShortcutBinding] {
        guard !ShortcutBinding.recommended.contains(appDelegate.currentBinding) else {
            return ShortcutBinding.recommended
        }
        return [appDelegate.currentBinding] + ShortcutBinding.recommended
    }

    private func shortcutLabel(for binding: ShortcutBinding) -> String {
        if binding == .defaultBinding {
            return "\(binding.displayName) (Default)"
        }
        return ShortcutBinding.recommended.contains(binding)
            ? binding.displayName
            : "Custom — \(binding.displayName)"
    }
}

private struct ProviderSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var selectedProvider: TranscriptionProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                ForEach(Array(TranscriptionProvider.allCases.enumerated()), id: \.element) { index, provider in
                    providerRow(provider)
                    if index < TranscriptionProvider.allCases.count - 1 {
                        Divider()
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator, lineWidth: 1)
            }

            Label("API keys are stored securely in the macOS Keychain.", systemImage: "lock")
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.leading, 4)

            Spacer()
        }
        .padding(28)
        .sheet(item: $selectedProvider) { provider in
            ProviderConfigurationSheet(provider: provider, appDelegate: appDelegate)
        }
    }

    private func providerRow(_ provider: TranscriptionProvider) -> some View {
        let status = appDelegate.providerConfigurationStatus(for: provider)
        return HStack(spacing: 20) {
            Text(provider.displayName)
                .font(.body.weight(.medium))
                .frame(width: 110, alignment: .leading)

            Spacer()

            Text(status.title)
                .foregroundStyle(statusColor(status))
                .frame(width: 150, alignment: .leading)

            Button("Configure…") {
                selectedProvider = provider
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    private func statusColor(_ status: ProviderConfigurationStatus) -> Color {
        switch status {
        case .configured: return .green
        case .endpointMissing: return .orange
        case .notConfigured: return .secondary
        }
    }
}

private struct ProviderConfigurationSheet: View {
    let provider: TranscriptionProvider
    @ObservedObject var appDelegate: AppDelegate
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var azureEndpoint: String
    @State private var errorMessage: String?
    @State private var confirmsRemoval = false
    @State private var isCheckingOpenAIModels = false
    @State private var openAIModelAccess: [OpenAIModelAccess] = []

    init(provider: TranscriptionProvider, appDelegate: AppDelegate) {
        self.provider = provider
        self.appDelegate = appDelegate
        _azureEndpoint = State(initialValue: provider == .azure ? appDelegate.storedAzureEndpoint() : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(provider.displayName) Configuration")
                .font(.title2.weight(.semibold))

            Text("Leave the API key blank to keep the value already stored in Keychain.")
                .foregroundStyle(.secondary)

            Form {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)

                if provider == .azure {
                    TextField("Voice Live Endpoint", text: $azureEndpoint, prompt: Text("https://<resource>.services.ai.azure.com/"))
                }
            }
            .formStyle(.grouped)

            if provider == .openAI, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openAIModelAccessView
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Remove…", role: .destructive) {
                    confirmsRemoval = true
                }
                .disabled(!appDelegate.hasProviderConfiguration(for: provider))

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provider == .openAI && isCheckingOpenAIModels)
            }
        }
        .padding(24)
        .frame(width: provider == .azure ? 560 : 480)
        .confirmationDialog(
            "Remove \(provider.displayName) configuration?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let error = appDelegate.removeProviderConfiguration(for: provider) {
                    errorMessage = error
                } else {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(provider == .azure
                 ? "The API key and Voice Live endpoint will be removed."
                 : "The API key will be removed from the macOS Keychain.")
        }
        .task(id: apiKey) {
            await checkOpenAIModelsAfterTypingPause()
        }
    }

    @ViewBuilder
    private var openAIModelAccessView: some View {
        if isCheckingOpenAIModels {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking model access…")
            }
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(openAIModelAccess) { result in
                    switch result.status {
                    case .available:
                        Label("\(result.model): Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable(let message):
                        Label("\(result.model): Not available", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(message)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func checkOpenAIModelsAfterTypingPause() async {
        guard provider == .openAI else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            isCheckingOpenAIModels = false
            openAIModelAccess = []
            return
        }
        isCheckingOpenAIModels = true
        openAIModelAccess = []
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let models = modelGroups
            .filter { $0.provider == .openAI }
            .flatMap(\.models)
        let results = await OpenAIModelAccessChecker.check(apiKey: key, models: models)
        guard !Task.isCancelled else { return }
        openAIModelAccess = results
        isCheckingOpenAIModels = false
    }

    private func save() {
        errorMessage = appDelegate.saveProviderConfiguration(
            for: provider,
            apiKey: apiKey,
            azureEndpoint: azureEndpoint
        )
        if errorMessage == nil {
            dismiss()
        }
    }
}

private struct ShortcutRecorderSheet: View {
    @ObservedObject var appDelegate: AppDelegate
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(spacing: 20) {
            Text("Record Shortcut")
                .font(.title2.weight(.semibold))

            Text("Press a combination with ⌘, ⌥, ⌃, or ⇧, or hold and release a single modifier key.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text(recorder.displayText)
                .font(.title3.weight(.medium))
                .monospaced()
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let binding = recorder.captured else { return }
                    appDelegate.applyBinding(binding)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.captured == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            appDelegate.suspendShortcutHandling()
            recorder.start()
        }
        .onDisappear {
            recorder.stop()
            appDelegate.resumeShortcutHandling()
        }
    }
}

@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published private(set) var displayText = "Press a key combination…"
    @Published private(set) var captured: ShortcutBinding?

    private var monitor: Any?
    private var modifierCandidate: (keyCode: Int64, flag: UInt64)?
    private var otherKeyPressed = false
    private let modifierSet: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(modifierSet)
        let flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))

        switch event.type {
        case .flagsChanged:
            let keyCode = Int64(event.keyCode)
            let flag = ShortcutBinding.modifierFlag(forKeyCode: keyCode)

            if let candidate = modifierCandidate, candidate.keyCode == keyCode {
                if !otherKeyPressed {
                    captured = .modifierOnly(keyCode: candidate.keyCode, modifier: candidate.flag)
                    displayText = "Captured: \(captured!.displayName)"
                }
                modifierCandidate = nil
                return nil
            }

            if let flag, event.modifierFlags.contains(Self.nsFlag(for: flag)) {
                let modifier = Self.nsFlag(for: flag)
                if captured == nil && modifierCandidate == nil && modifiers == modifier {
                    modifierCandidate = (keyCode, flag)
                    otherKeyPressed = false
                    displayText = "Hold \(ShortcutBinding.modifierKeyName(for: keyCode)) and release…"
                } else if modifierCandidate != nil {
                    modifierCandidate = nil
                    displayText = ShortcutBinding.modifierSymbols(for: flags.rawValue) + " + …"
                }
                return nil
            }

            modifierCandidate = nil
            if captured == nil {
                displayText = modifiers.isEmpty
                    ? "Press a key combination…"
                    : ShortcutBinding.modifierSymbols(for: flags.rawValue) + " + …"
            }
            return nil

        case .keyDown:
            if modifierCandidate != nil { otherKeyPressed = true }
            guard !modifiers.isEmpty else { return event }
            let binding = ShortcutBinding.chord(keyCode: Int64(event.keyCode), modifiers: flags.rawValue)
            captured = binding
            modifierCandidate = nil
            displayText = "Captured: \(binding.displayName)"
            return nil

        default:
            return event
        }
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
}
