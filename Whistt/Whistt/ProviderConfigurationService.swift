import Foundation

public enum ProviderConfigurationStatus: Equatable {
    case configured
    case notConfigured
    case endpointMissing
}

public enum ProviderConfigurationError: Error, Equatable {
    case apiKeyMissing
    case endpointMissing
    case endpointInvalid
    case keySaveFailed
    case keyDeleteFailed
}

/// Coordinates provider configuration without depending on AppKit or SwiftUI.
/// Storage operations are injected so validation and mutation ordering can be
/// covered by fast integration tests without touching a user's Keychain.
public struct ProviderConfigurationService {
    public var containsKey: (String) -> Bool
    public var saveKey: (String, String) -> Bool
    public var deleteKey: (String) -> Bool
    public var storedAzureEndpoint: () -> String?
    public var resolvedAzureEndpoint: () -> String?
    public var saveAzureEndpoint: (String) -> Bool
    public var removeAzureEndpoint: () -> Void

    public init(
        containsKey: @escaping (String) -> Bool,
        saveKey: @escaping (String, String) -> Bool,
        deleteKey: @escaping (String) -> Bool,
        storedAzureEndpoint: @escaping () -> String?,
        resolvedAzureEndpoint: @escaping () -> String?,
        saveAzureEndpoint: @escaping (String) -> Bool,
        removeAzureEndpoint: @escaping () -> Void
    ) {
        self.containsKey = containsKey
        self.saveKey = saveKey
        self.deleteKey = deleteKey
        self.storedAzureEndpoint = storedAzureEndpoint
        self.resolvedAzureEndpoint = resolvedAzureEndpoint
        self.saveAzureEndpoint = saveAzureEndpoint
        self.removeAzureEndpoint = removeAzureEndpoint
    }

    public func status(for provider: TranscriptionProvider) -> ProviderConfigurationStatus {
        let hasKey = containsKey(provider.apiKeyAccount)
        guard provider == .azure else {
            return hasKey ? .configured : .notConfigured
        }
        guard hasKey else { return .notConfigured }
        return resolvedAzureEndpoint() == nil ? .endpointMissing : .configured
    }

    public func hasConfiguration(for provider: TranscriptionProvider) -> Bool {
        containsKey(provider.apiKeyAccount)
            || (provider == .azure && storedAzureEndpoint() != nil)
    }

    public func save(
        provider: TranscriptionProvider,
        rawAPIKey: String,
        rawAzureEndpoint: String
    ) -> Result<Void, ProviderConfigurationError> {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStoredKey = containsKey(provider.apiKeyAccount)
        guard !apiKey.isEmpty || hasStoredKey else { return .failure(.apiKeyMissing) }

        let normalizedAzureEndpoint: String?
        if provider == .azure {
            let endpoint = rawAzureEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else { return .failure(.endpointMissing) }
            guard let normalized = AzureVoiceLiveSettings.normalizedEndpoint(endpoint) else {
                return .failure(.endpointInvalid)
            }
            normalizedAzureEndpoint = normalized
        } else {
            normalizedAzureEndpoint = nil
        }

        if !apiKey.isEmpty && !saveKey(apiKey, provider.apiKeyAccount) {
            return .failure(.keySaveFailed)
        }
        if let normalizedAzureEndpoint {
            _ = saveAzureEndpoint(normalizedAzureEndpoint)
        }
        return .success(())
    }

    public func remove(provider: TranscriptionProvider) -> Result<Void, ProviderConfigurationError> {
        guard deleteKey(provider.apiKeyAccount) else { return .failure(.keyDeleteFailed) }
        if provider == .azure {
            removeAzureEndpoint()
        }
        return .success(())
    }
}
