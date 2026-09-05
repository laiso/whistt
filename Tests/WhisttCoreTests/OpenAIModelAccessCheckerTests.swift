import Foundation
import XCTest
@testable import WhisttCore

final class OpenAIModelAccessCheckerTests: XCTestCase {
    private enum TestError: Error { case offline }

    private func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    func testAvailableModelUsesExpectedEndpointAndAuthorization() async {
        let results = await OpenAIModelAccessChecker.check(
            apiKey: "secret-key",
            models: ["gpt-transcribe"]
        ) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models/gpt-transcribe")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
            return (Data(), self.response(for: request, statusCode: 200))
        }

        XCTAssertEqual(results, [OpenAIModelAccess(model: "gpt-transcribe", status: .available)])
    }

    func testUnavailableModelUsesOpenAIErrorMessage() async {
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: ["denied"]) { request in
            let data = Data(#"{"error":{"message":"Project does not have access."}}"#.utf8)
            return (data, self.response(for: request, statusCode: 403))
        }

        XCTAssertEqual(results, [
            OpenAIModelAccess(model: "denied", status: .unavailable("Project does not have access."))
        ])
    }

    func testHTTPFailureWithoutAPIMessageUsesStatusCode() async {
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: ["missing"]) { request in
            (Data("not-json".utf8), self.response(for: request, statusCode: 404))
        }

        XCTAssertEqual(results, [
            OpenAIModelAccess(model: "missing", status: .unavailable("OpenAI returned HTTP 404."))
        ])
    }

    func testNonHTTPResponseCannotBeVerified() async {
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: ["model"]) { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        XCTAssertEqual(results, [
            OpenAIModelAccess(model: "model", status: .unavailable("Could not verify access."))
        ])
    }

    func testTransportErrorBecomesUnavailableResult() async {
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: ["model"]) { _ in
            throw TestError.offline
        }

        guard case .unavailable(let message) = results.first?.status else {
            return XCTFail("Expected an unavailable result")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testConcurrentResultsPreserveRequestedModelOrder() async {
        let models = ["slow", "fast"]
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: models) { request in
            if request.url?.lastPathComponent == "slow" {
                try await Task.sleep(for: .milliseconds(30))
            }
            return (Data(), self.response(for: request, statusCode: 200))
        }

        XCTAssertEqual(results.map(\.model), models)
        XCTAssertTrue(results.allSatisfy { $0.status == .available })
    }

    func testEmptyModelListPerformsNoRequests() async {
        let results = await OpenAIModelAccessChecker.check(apiKey: "key", models: []) { _ in
            XCTFail("Request should not be performed")
            throw TestError.offline
        }

        XCTAssertTrue(results.isEmpty)
    }
}
