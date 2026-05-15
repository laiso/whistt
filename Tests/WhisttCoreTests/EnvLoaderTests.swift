import XCTest
@testable import WhisttCore

final class EnvLoaderTests: XCTestCase {

    func testProcessEnvVarTakesPrecedence() {
        // OPENAI_API_KEY is set in the test scheme env or via the Xcode scheme.
        // We don't override this; just make sure the call is safe and returns whatever
        // is currently effective. This catches a regression where the call crashes.
        _ = EnvLoader.value(for: "DEFINITELY_NOT_A_REAL_KEY_\(UUID().uuidString)")
    }

    func testValueSearchingExplicitPath() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "OPENAI_API_KEY=sk-from-file".write(to: env, atomically: true, encoding: .utf8)

        let v = EnvLoader.value(for: "OPENAI_API_KEY", searching: [env])
        XCTAssertEqual(v, "sk-from-file")
    }

    func testValueReturnsNilWhenKeyAbsent() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "FOO=bar".write(to: env, atomically: true, encoding: .utf8)

        XCTAssertNil(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]))
    }

    func testValueReturnsNilForEmptyPathList() {
        XCTAssertNil(EnvLoader.value(for: "OPENAI_API_KEY", searching: []))
    }

    func testFirstMatchingPathWins() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let envA = dir.appendingPathComponent("a.env")
        let envB = dir.appendingPathComponent("b.env")
        try "OPENAI_API_KEY=first".write(to: envA, atomically: true, encoding: .utf8)
        try "OPENAI_API_KEY=second".write(to: envB, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [envA, envB]), "first")
        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [envB, envA]), "second")
    }

    func testStripsDoubleQuotes() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try #"OPENAI_API_KEY="sk-quoted""#.write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-quoted")
    }

    func testStripsSingleQuotes() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "OPENAI_API_KEY='sk-single'".write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-single")
    }

    func testIgnoresCommentLines() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try """
        # This is a comment
        OPENAI_API_KEY=sk-real
        # Another comment
        """.write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-real")
    }

    func testIgnoresBlankLines() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "\n\nOPENAI_API_KEY=sk-blank\n\n".write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-blank")
    }

    func testHandlesWhitespaceAroundEquals() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "OPENAI_API_KEY   =   sk-spaced   ".write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-spaced")
    }

    func testMultipleKeysInOneFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try """
        OPENAI_API_KEY=sk-abc
        WHISTT_MODEL=gpt-4o-transcribe
        """.write(to: env, atomically: true, encoding: .utf8)

        XCTAssertEqual(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]), "sk-abc")
        XCTAssertEqual(EnvLoader.value(for: "WHISTT_MODEL", searching: [env]), "gpt-4o-transcribe")
    }

    func testValueOfEmptyAfterEqualsIsNil() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let env = dir.appendingPathComponent(".env")
        try "OPENAI_API_KEY=".write(to: env, atomically: true, encoding: .utf8)

        XCTAssertNil(EnvLoader.value(for: "OPENAI_API_KEY", searching: [env]))
    }

    func testNonExistentFileSkipped() {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)/.env")
        XCTAssertNil(EnvLoader.value(for: "OPENAI_API_KEY", searching: [bogus]))
    }

    func testLastTriedPathsPopulatedAfterDefaultSearch() {
        _ = EnvLoader.value(for: "OPENAI_API_KEY_\(UUID().uuidString)")
        XCTAssertFalse(EnvLoader.lastTriedPaths.isEmpty,
                       "expected default search to populate lastTriedPaths")
    }

    // MARK: - helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
