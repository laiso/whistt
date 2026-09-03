import AppKit

final class APIKeysWindowController: NSWindowController, NSWindowDelegate {
    private let providers: [TranscriptionProvider] = [.openAI, .gemini, .meta]
    private var fields: [TranscriptionProvider: NSSecureTextField] = [:]
    private var statusLabels: [TranscriptionProvider: NSTextField] = [:]
    private var removeButtons: [TranscriptionProvider: NSButton] = [:]
    var onKeysChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "API Keys"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    func present() {
        refresh()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let window else { return }

        let title = NSTextField(labelWithString: "API Keys")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "Keys are stored securely in the macOS Keychain. Enter a new value to add or replace a key.")
        detail.textColor = .secondaryLabelColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 14
        rows.alignment = .leading

        for provider in providers {
            rows.addArrangedSubview(makeRow(for: provider))
        }

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow(_:)))
        done.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [NSView(), done])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        let content = NSStackView(views: [title, detail, rows, buttonRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            detail.widthAnchor.constraint(equalTo: content.widthAnchor),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func makeRow(for provider: TranscriptionProvider) -> NSView {
        let name = NSTextField(labelWithString: provider.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let field = NSSecureTextField()
        field.placeholderString = placeholder(for: provider)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fields[provider] = field

        let save = NSButton(title: "Save", target: self, action: #selector(saveKey(_:)))
        save.tag = providerTag(provider)

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey(_:)))
        remove.tag = providerTag(provider)
        removeButtons[provider] = remove

        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        statusLabels[provider] = status

        let controls = NSStackView(views: [field, save, remove])
        controls.orientation = .horizontal
        controls.spacing = 8

        let right = NSStackView(views: [controls, status])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 4

        let row = NSStackView(views: [name, right])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 472).isActive = true
        right.widthAnchor.constraint(equalToConstant: 396).isActive = true
        controls.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        return row
    }

    private func refresh() {
        for provider in providers {
            let isSet = KeychainStore.value(for: provider.apiKeyAccount) != nil
            statusLabels[provider]?.stringValue = isSet ? "Saved in Keychain" : "Not set"
            statusLabels[provider]?.textColor = isSet ? .systemGreen : .secondaryLabelColor
            removeButtons[provider]?.isEnabled = isSet
            fields[provider]?.stringValue = ""
        }
    }

    @objc private func saveKey(_ sender: NSButton) {
        guard let provider = provider(forTag: sender.tag), let field = fields[provider] else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(field)
            return
        }
        guard KeychainStore.set(value, for: provider.apiKeyAccount) else {
            showError("Could not save the key to the macOS Keychain.")
            return
        }
        refresh()
        onKeysChanged?()
    }

    @objc private func removeKey(_ sender: NSButton) {
        guard let provider = provider(forTag: sender.tag) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove (provider.displayName) API key?"
        alert.informativeText = "The key will be removed from the macOS Keychain."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard KeychainStore.delete(for: provider.apiKeyAccount) else {
            showError("Could not remove the key from the macOS Keychain.")
            return
        }
        refresh()
        onKeysChanged?()
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Keychain Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func placeholder(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .openAI: return "sk-…"
        case .gemini: return "Gemini API key"
        case .meta: return "Meta API key"
        }
    }

    private func providerTag(_ provider: TranscriptionProvider) -> Int {
        providers.firstIndex(of: provider) ?? 0
    }

    private func provider(forTag tag: Int) -> TranscriptionProvider? {
        providers.indices.contains(tag) ? providers[tag] : nil
    }
}
