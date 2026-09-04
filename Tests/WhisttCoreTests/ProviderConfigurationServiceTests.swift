import XCTest
@testable import WhisttCore

final class ProviderConfigurationServiceTests: XCTestCase {
    private final class Storage {
        var keys: [String: String] = [:]
        var endpoint: String?
        var keySaveSucceeds = true
        var keyDeleteSucceeds = true
        var events: [String] = []
    }

    private func makeService(_ storage: Storage) -> ProviderConfigurationService {
        ProviderConfigurationService(
            containsKey: { storage.keys[$0] != nil },
            saveKey: { value, account in
                storage.events.append("save-key")
                guard storage.keySaveSucceeds else { return false }
                storage.keys[account] = value
                return true
            },
            deleteKey: { account in
                storage.events.append("delete-key")
                guard storage.keyDeleteSucceeds else { return false }
                storage.keys.removeValue(forKey: account)
                return true
            },
            storedAzureEndpoint: { storage.endpoint },
            resolvedAzureEndpoint: { storage.endpoint },
            saveAzureEndpoint: { endpoint in
                storage.events.append("save-endpoint")
                storage.endpoint = endpoint
                return true
            },
            removeAzureEndpoint: {
                storage.events.append("remove-endpoint")
                storage.endpoint = nil
            }
        )
    }

    private func assertSuccess(
        _ result: Result<Void, ProviderConfigurationError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ expected: ProviderConfigurationError,
        _ result: Result<Void, ProviderConfigurationError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            XCTFail("Expected failure \(expected), got success", file: file, line: line)
            return
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    func testNewProviderRequiresAPIKey() {
        let storage = Storage()
        let result = makeService(storage).save(provider: .openAI, rawAPIKey: " ", rawAzureEndpoint: "")

        assertFailure(.apiKeyMissing, result)
        XCTAssertTrue(storage.events.isEmpty)
    }

    func testBlankAPIKeyKeepsStoredValue() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.openAI.apiKeyAccount] = "existing"

        assertSuccess(makeService(storage).save(provider: .openAI, rawAPIKey: "", rawAzureEndpoint: ""))
        XCTAssertEqual(storage.keys[TranscriptionProvider.openAI.apiKeyAccount], "existing")
        XCTAssertTrue(storage.events.isEmpty)
    }

    func testInvalidAzureEndpointChangesNothing() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.azure.apiKeyAccount] = "old-key"
        storage.endpoint = "https://old.services.ai.azure.com"

        let result = makeService(storage).save(
            provider: .azure,
            rawAPIKey: "new-key",
            rawAzureEndpoint: "not-a-url"
        )

        assertFailure(.endpointInvalid, result)
        XCTAssertEqual(storage.keys[TranscriptionProvider.azure.apiKeyAccount], "old-key")
        XCTAssertEqual(storage.endpoint, "https://old.services.ai.azure.com")
        XCTAssertTrue(storage.events.isEmpty)
    }

    func testAzureRequiresEndpointBeforeChangingKey() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.azure.apiKeyAccount] = "old-key"

        let result = makeService(storage).save(
            provider: .azure,
            rawAPIKey: "new-key",
            rawAzureEndpoint: "  "
        )

        assertFailure(.endpointMissing, result)
        XCTAssertEqual(storage.keys[TranscriptionProvider.azure.apiKeyAccount], "old-key")
        XCTAssertTrue(storage.events.isEmpty)
    }

    func testAzureValidatesThenStoresKeyAndNormalizedEndpoint() {
        let storage = Storage()

        let result = makeService(storage).save(
            provider: .azure,
            rawAPIKey: " new-key ",
            rawAzureEndpoint: " https://new.services.ai.azure.com/ "
        )

        assertSuccess(result)
        XCTAssertEqual(storage.keys[TranscriptionProvider.azure.apiKeyAccount], "new-key")
        XCTAssertEqual(storage.endpoint, "https://new.services.ai.azure.com")
        XCTAssertEqual(storage.events, ["save-key", "save-endpoint"])
    }

    func testKeychainFailureDoesNotChangeAzureEndpoint() {
        let storage = Storage()
        storage.endpoint = "https://old.services.ai.azure.com"
        storage.keySaveSucceeds = false

        let result = makeService(storage).save(
            provider: .azure,
            rawAPIKey: "new-key",
            rawAzureEndpoint: "https://new.services.ai.azure.com"
        )

        assertFailure(.keySaveFailed, result)
        XCTAssertEqual(storage.endpoint, "https://old.services.ai.azure.com")
        XCTAssertEqual(storage.events, ["save-key"])
    }

    func testStatusDistinguishesAzureEndpointMissing() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.azure.apiKeyAccount] = "key"
        let service = makeService(storage)

        XCTAssertEqual(service.status(for: .azure), .endpointMissing)
        storage.endpoint = "https://resource.services.ai.azure.com"
        XCTAssertEqual(service.status(for: .azure), .configured)
    }

    func testNonAzureStatusUsesKeyPresence() {
        let storage = Storage()
        let service = makeService(storage)

        XCTAssertEqual(service.status(for: .gemini), .notConfigured)
        storage.keys[TranscriptionProvider.gemini.apiKeyAccount] = "key"
        XCTAssertEqual(service.status(for: .gemini), .configured)
    }

    func testRemovingAzureDeletesBothValuesInOrder() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.azure.apiKeyAccount] = "key"
        storage.endpoint = "https://resource.services.ai.azure.com"

        assertSuccess(makeService(storage).remove(provider: .azure))
        XCTAssertNil(storage.keys[TranscriptionProvider.azure.apiKeyAccount])
        XCTAssertNil(storage.endpoint)
        XCTAssertEqual(storage.events, ["delete-key", "remove-endpoint"])
    }

    func testFailedAzureKeyDeletionKeepsEndpoint() {
        let storage = Storage()
        storage.keys[TranscriptionProvider.azure.apiKeyAccount] = "key"
        storage.endpoint = "https://resource.services.ai.azure.com"
        storage.keyDeleteSucceeds = false

        let result = makeService(storage).remove(provider: .azure)

        assertFailure(.keyDeleteFailed, result)
        XCTAssertEqual(storage.endpoint, "https://resource.services.ai.azure.com")
        XCTAssertEqual(storage.events, ["delete-key"])
    }
}
