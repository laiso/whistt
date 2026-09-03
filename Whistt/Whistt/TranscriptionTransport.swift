import Foundation

public enum TranscriptionTransportEvent: Equatable {
    case ready
    case speechStarted
    case partial(text: String, replacesPrevious: Bool)
    /// A provider-neutral transcript revision (see `TranscriptRevision`).
    /// Emitted by transports whose providers support revisable interims.
    case revision(TranscriptRevision)
    case final(String)
    case turnComplete
    case unknown(String)
}

public protocol TranscriptionTransport: AnyObject {
    var sampleRate: Double { get }
    var onEvent: ((TranscriptionTransportEvent) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect()
    func sendAudio(_ data: Data)
    func endInput()
    func close()
}

public enum TranscriptionTransportFactory {
    public static func make(
        provider: TranscriptionProvider,
        apiKey: String,
        model: String
    ) -> TranscriptionTransport {
        switch provider {
        case .openAI:
            return OpenAITranscriptionTransport(apiKey: apiKey, model: model)
        case .gemini:
            return GeminiTranscriptionTransport(apiKey: apiKey, model: model)
        case .meta:
            return MetaTranscriptionTransport(apiKey: apiKey, model: model)
        case .xAI:
            return XaiTranscriptionTransport(apiKey: apiKey)
        }
    }
}

public final class OpenAITranscriptionTransport: TranscriptionTransport {
    public let sampleRate = 24_000.0
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let socket: RealtimeWS

    public init(apiKey: String, model: String) {
        socket = RealtimeWS(apiKey: apiKey, model: model)
        socket.onEvent = { [weak self] event in self?.handle(event) }
        socket.onError = { [weak self] message in self?.onError?("OpenAI: \(message)") }
    }

    public func connect() { socket.connect() }
    public func sendAudio(_ data: Data) { socket.sendAudio(data) }
    public func endInput() { socket.sendCommit() }
    public func close() { socket.close() }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .sessionCreated:
            socket.sendSessionUpdate()
        case .sessionUpdated:
            onEvent?(.ready)
        case .speechStarted:
            onEvent?(.speechStarted)
        case .bufferCommitted:
            onEvent?(.turnComplete)
        case .delta(let text):
            onEvent?(.partial(text: text, replacesPrevious: false))
        case .finalTranscript(let text):
            onEvent?(.final(text))
        case .conversationItem(let transcripts):
            transcripts.forEach { onEvent?(.final($0)) }
        case .transcriptionFailed(let code, let message):
            onError?("OpenAI transcription failed [\(code)]: \(message)")
        case .error(let message):
            onError?("OpenAI: \(message)")
        case .unknown(let type):
            onEvent?(.unknown(type))
        }
    }
}

public final class GeminiTranscriptionTransport: TranscriptionTransport {
    public let sampleRate = 16_000.0
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let socket: GeminiLiveWS

    public init(apiKey: String, model: String) {
        socket = GeminiLiveWS(apiKey: apiKey, model: model)
        socket.onEvent = { [weak self] event in self?.handle(event) }
        socket.onError = { [weak self] message in self?.onError?("Gemini: \(message)") }
    }

    public func connect() {
        socket.connect()
        socket.sendActivityStart()
    }

    public func sendAudio(_ data: Data) { socket.sendAudio(data) }
    public func endInput() { socket.sendActivityEnd() }
    public func close() { socket.close() }

    private func handle(_ event: GeminiLiveEvent) {
        switch event {
        case .setupComplete:
            onEvent?(.ready)
        case .interimTranscript(let text):
            onEvent?(.partial(text: text, replacesPrevious: true))
        case .finalTranscript(let text):
            onEvent?(.final(text))
        case .turnComplete:
            onEvent?(.turnComplete)
        case .error(let message):
            onError?("Gemini: \(message)")
        case .unknown:
            onEvent?(.unknown("gemini.unknown"))
        }
    }
}
