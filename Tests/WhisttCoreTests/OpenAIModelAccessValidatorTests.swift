import XCTest
@testable import WhisttCore

final class OpenAIModelAccessValidatorTests: XCTestCase {
    private actor Calls {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    func testBlankKeyReturnsEmptyWithoutPauseOrRequest() async {
        let results = await OpenAIModelAccessValidator.validate(
            rawAPIKey: " \n\t ",
            models: ["gpt-transcribe"],
            pause: {
                XCTFail("Blank keys must not start the debounce pause")
            },
            check: { _, _ in
                XCTFail("Blank keys must not be checked")
                return []
            }
        )

        XCTAssertEqual(results, [])
    }

    func testTrimsKeyAndChecksAfterPause() async {
        let calls = Calls()
        let expected = [OpenAIModelAccess(model: "gpt-transcribe", status: .available)]

        let results = await OpenAIModelAccessValidator.validate(
            rawAPIKey: "  secret  \n",
            models: ["gpt-transcribe"],
            pause: {
                await calls.append("pause")
            },
            check: { key, models in
                await calls.append("check")
                XCTAssertEqual(key, "secret")
                XCTAssertEqual(models, ["gpt-transcribe"])
                return expected
            }
        )

        XCTAssertEqual(results, expected)
        let events = await calls.events
        XCTAssertEqual(events, ["pause", "check"])
    }

    func testCancelledPauseProducesNoResultOrRequest() async {
        let results = await OpenAIModelAccessValidator.validate(
            rawAPIKey: "key",
            models: ["gpt-transcribe"],
            pause: { throw CancellationError() },
            check: { _, _ in
                XCTFail("A cancelled validation must not issue a request")
                return []
            }
        )

        XCTAssertNil(results)
    }

    func testCancellationAfterRequestDiscardsResult() async {
        let task = Task {
            await OpenAIModelAccessValidator.validate(
                rawAPIKey: "key",
                models: ["gpt-transcribe"],
                pause: {},
                check: { _, _ in
                    try? await Task.sleep(for: .seconds(5))
                    return [OpenAIModelAccess(model: "gpt-transcribe", status: .available)]
                }
            )
        }
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
    }
}
