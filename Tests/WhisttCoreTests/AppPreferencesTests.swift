import XCTest
@testable import WhisttCore

final class AppPreferencesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testOutputModeDefaultsToTypingAndPersistsSelection() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.outputMode(defaults: defaults), .typing)

        AppPreferences.setOutputMode(.clipboard, defaults: defaults)

        XCTAssertEqual(AppPreferences.outputMode(defaults: defaults), .clipboard)
    }

    func testInvalidOutputModeFallsBackToTyping() {
        let defaults = makeDefaults()
        defaults.set("invalid", forKey: AppPreferences.outputModeDefaultsKey)

        XCTAssertEqual(AppPreferences.outputMode(defaults: defaults), .typing)
    }

    func testRecordingStartSoundDefaultsOnAndPersistsSelection() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppPreferences.playsRecordingStartSound(defaults: defaults))

        AppPreferences.setPlaysRecordingStartSound(false, defaults: defaults)

        XCTAssertFalse(AppPreferences.playsRecordingStartSound(defaults: defaults))
    }
}
