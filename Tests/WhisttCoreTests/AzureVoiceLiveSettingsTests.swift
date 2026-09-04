import XCTest
@testable import WhisttCore

final class AzureVoiceLiveSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AzureVoiceLiveSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testNormalizedEndpointTrimsAndStripsTrailingSlashes() {
        XCTAssertEqual(
            AzureVoiceLiveSettings.normalizedEndpoint("  https://res.services.ai.azure.com// "),
            "https://res.services.ai.azure.com"
        )
    }

    func testNormalizedEndpointRejectsNonHTTPSOrHostlessValues() {
        XCTAssertNil(AzureVoiceLiveSettings.normalizedEndpoint("http://res.services.ai.azure.com"))
        XCTAssertNil(AzureVoiceLiveSettings.normalizedEndpoint("https://"))
        XCTAssertNil(AzureVoiceLiveSettings.normalizedEndpoint("res.services.ai.azure.com"))
        XCTAssertNil(AzureVoiceLiveSettings.normalizedEndpoint(""))
    }

    func testSaveRequiresValidEndpoint() {
        let defaults = makeDefaults()
        XCTAssertFalse(AzureVoiceLiveSettings.saveEndpoint("not-a-url", defaults: defaults))
        XCTAssertNil(AzureVoiceLiveSettings.storedEndpoint(defaults: defaults))
        XCTAssertTrue(AzureVoiceLiveSettings.saveEndpoint("https://res.services.ai.azure.com/", defaults: defaults))
        XCTAssertEqual(
            AzureVoiceLiveSettings.storedEndpoint(defaults: defaults),
            "https://res.services.ai.azure.com"
        )
    }

    func testRemoveEndpointClearsStoredValue() {
        let defaults = makeDefaults()
        AzureVoiceLiveSettings.saveEndpoint("https://res.services.ai.azure.com", defaults: defaults)
        AzureVoiceLiveSettings.removeEndpoint(defaults: defaults)
        XCTAssertNil(AzureVoiceLiveSettings.storedEndpoint(defaults: defaults))
    }

    func testEnvironmentTakesPrecedenceOverStoredEndpoint() {
        let defaults = makeDefaults()
        AzureVoiceLiveSettings.saveEndpoint("https://stored.services.ai.azure.com", defaults: defaults)
        XCTAssertEqual(
            AzureVoiceLiveSettings.resolveEndpoint(
                environment: ["AZURE_SPEECH_ENDPOINT": "https://env.services.ai.azure.com"],
                defaults: defaults
            ),
            "https://env.services.ai.azure.com"
        )
    }

    func testResolveFallsBackToStoredThenNil() {
        let defaults = makeDefaults()
        XCTAssertNil(AzureVoiceLiveSettings.resolveEndpoint(environment: [:], defaults: defaults))
        AzureVoiceLiveSettings.saveEndpoint("https://res.services.ai.azure.com", defaults: defaults)
        XCTAssertEqual(
            AzureVoiceLiveSettings.resolveEndpoint(environment: [:], defaults: defaults),
            "https://res.services.ai.azure.com"
        )
    }

    func testBlankEnvironmentValueDoesNotShadowStoredEndpoint() {
        let defaults = makeDefaults()
        AzureVoiceLiveSettings.saveEndpoint("https://res.services.ai.azure.com", defaults: defaults)
        XCTAssertEqual(
            AzureVoiceLiveSettings.resolveEndpoint(
                environment: ["AZURE_SPEECH_ENDPOINT": "   "],
                defaults: defaults
            ),
            "https://res.services.ai.azure.com"
        )
    }
}
