import Foundation

/// Storage and validation for the Azure Voice Live endpoint.
///
/// The endpoint is not a secret, so it lives in `UserDefaults` while the API
/// key stays in the Keychain. Process environment / `.env` values take
/// precedence over the stored value to match the development-launch behavior
/// of the other providers.
public enum AzureVoiceLiveSettings {
    public static let endpointDefaultsKey = "WHISTT_AZURE_SPEECH_ENDPOINT"

    /// Trims whitespace and a trailing slash; returns nil unless the result is
    /// an `https://` URL with a host.
    public static func normalizedEndpoint(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard value.hasPrefix("https://"), value.count > "https://".count else { return nil }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return value
    }

    public static func storedEndpoint(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: endpointDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Validates and saves the endpoint. Returns false without saving when the
    /// value is not a usable `https://` endpoint.
    @discardableResult
    public static func saveEndpoint(_ raw: String, defaults: UserDefaults = .standard) -> Bool {
        guard let normalized = normalizedEndpoint(raw) else { return false }
        defaults.set(normalized, forKey: endpointDefaultsKey)
        return true
    }

    public static func removeEndpoint(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: endpointDefaultsKey)
    }

    /// Production resolution order: process environment, `.env`, preferences.
    public static func resolveEndpoint() -> String? {
        resolveEndpoint(
            environment: ProcessInfo.processInfo.environment,
            defaults: .standard,
            dotenvValue: EnvLoader.value(for: "AZURE_SPEECH_ENDPOINT")
        )
    }

    /// Injectable resolution used by tests. Process environment wins over a
    /// value loaded from `.env`, which in turn wins over preferences.
    public static func resolveEndpoint(
        environment: [String: String],
        defaults: UserDefaults,
        dotenvValue: String? = nil
    ) -> String? {
        if let fromEnv = environment["AZURE_SPEECH_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !fromEnv.isEmpty {
            return fromEnv
        }
        if let fromFile = dotenvValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromFile.isEmpty {
            return fromFile
        }
        return storedEndpoint(defaults: defaults)
    }
}
