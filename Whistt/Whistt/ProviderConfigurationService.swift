import Foundation

public enum OpenAIModelAccessStatus: Equatable {
    case available
    case unavailable(String)
}

public struct OpenAIModelAccess: Identifiable, Equatable {
    public let model: String
    public let status: OpenAIModelAccessStatus

    public var id: String { model }
}

public typealias OpenAIModelAccessRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)
public typealias OpenAIModelAccessCheck = @Sendable (String, [String]) async -> [OpenAIModelAccess]
public typealias OpenAIModelAccessPause = @Sendable () async throws -> Void

public enum OpenAIModelAccessValidator {
    public static func validate(rawAPIKey: String, models: [String]) async -> [OpenAIModelAccess]? {
        await validate(
            rawAPIKey: rawAPIKey,
            models: models,
            pause: { try await Task.sleep(for: .milliseconds(600)) },
            check: { apiKey, models in
                await OpenAIModelAccessChecker.check(apiKey: apiKey, models: models)
            }
        )
    }

    public static func validate(
        rawAPIKey: String,
        models: [String],
        pause: OpenAIModelAccessPause,
        check: OpenAIModelAccessCheck
    ) async -> [OpenAIModelAccess]? {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return [] }
        do {
            try await pause()
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let results = await check(apiKey, models)
        guard !Task.isCancelled else { return nil }
        return results
    }
}

public enum OpenAIModelAccessChecker {
    public static func check(apiKey: String, models: [String]) async -> [OpenAIModelAccess] {
        await check(apiKey: apiKey, models: models) { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public static func check(
        apiKey: String,
        models: [String],
        request: @escaping OpenAIModelAccessRequest
    ) async -> [OpenAIModelAccess] {
        await withTaskGroup(of: OpenAIModelAccess.self) { group in
            for model in models {
                group.addTask { await check(apiKey: apiKey, model: model, request: request) }
            }
            var results: [String: OpenAIModelAccess] = [:]
            for await result in group { results[result.model] = result }
            return models.compactMap { results[$0] }
        }
    }

    private static func check(
        apiKey: String,
        model: String,
        request performRequest: OpenAIModelAccessRequest
    ) async -> OpenAIModelAccess {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/\(model)")!)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse else {
                return OpenAIModelAccess(model: model, status: .unavailable("Could not verify access."))
            }
            if http.statusCode == 200 {
                return OpenAIModelAccess(model: model, status: .available)
            }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            return OpenAIModelAccess(
                model: model,
                status: .unavailable(message ?? "OpenAI returned HTTP \(http.statusCode).")
            )
        } catch {
            return OpenAIModelAccess(model: model, status: .unavailable(error.localizedDescription))
        }
    }
}

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
