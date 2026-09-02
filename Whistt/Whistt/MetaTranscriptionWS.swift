import Foundation

public final class MetaTranscriptionTransport: NSObject, TranscriptionTransport, URLSessionWebSocketDelegate {
    public let sampleRate = 24_000.0
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "meta.transcription.ws.q")
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var configured = false
    private var closing = false
    private var pendingAudio: [Data] = []
    private var pendingEndInput = false

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        delegateQueue = operationQueue
        super.init()
    }

    public func connect() { queue.async { [weak self] in self?._connect() } }
    public func sendAudio(_ data: Data) { queue.async { [weak self] in self?._sendAudio(data) } }
    public func endInput() { queue.async { [weak self] in self?._endInput() } }
    public func close() { queue.async { [weak self] in self?._close() } }

    private func _connect() {
        let url = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        configured = false
        closing = false
        pendingAudio.removeAll(keepingCapacity: true)
        pendingEndInput = false
        task.resume()
        receiveLoop()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        do {
            sendText(try MetaTranscriptionMessage.handshake(apiKey: apiKey, model: model))
        } catch {
            onError?("Meta handshake encode: \(error.localizedDescription)")
        }
    }

    private func _sendAudio(_ data: Data) {
        if configured {
            sendBinary(data)
        } else {
            pendingAudio.append(data)
        }
    }

    private func _endInput() {
        if configured {
            sendText(MetaTranscriptionMessage.endStream)
        } else {
            pendingEndInput = true
        }
    }

    private func markConfigured() {
        guard !configured else { return }
        configured = true
        pendingAudio.forEach(sendBinary)
        pendingAudio.removeAll(keepingCapacity: true)
        if pendingEndInput {
            pendingEndInput = false
            sendText(MetaTranscriptionMessage.endStream)
        }
        onEvent?(.ready)
    }

    private func sendText(_ string: String) {
        task?.send(.string(string)) { [weak self] error in self?.handleSendError(error) }
    }

    private func sendBinary(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in self?.handleSendError(error) }
    }

    private func handleSendError(_ error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.onError?("Meta send: \(error.localizedDescription)")
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let string: String?
                switch message {
                case .string(let value): string = value
                case .data(let data): string = String(data: data, encoding: .utf8)
                @unknown default: string = nil
                }
                if let string, let event = MetaTranscriptionEvent.decode(from: string) {
                    self.handle(event)
                }
                if self.task != nil { self.receiveLoop() }
            case .failure(let error):
                if !self.closing { self.onError?("Meta ws: \(error.localizedDescription)") }
            }
        }
    }

    private func handle(_ event: MetaTranscriptionEvent) {
        switch event {
        case .handshakeAcknowledged:
            markConfigured()
        case .transcript(let text, let final):
            if final { onEvent?(.final(text)) }
            else { onEvent?(.partial(text: text, replacesPrevious: true)) }
        case .speechStart:
            onEvent?(.speechStarted)
        case .speechEnd:
            onEvent?(.turnComplete)
        case .speechComplete(let text, _):
            onEvent?(.final(text))
        case .audioProgress(let milliseconds):
            onEvent?(.unknown("meta.audioProgress.\(milliseconds ?? 0)"))
        case .error(let code, let message):
            let suffix = code.map { " [\($0)]" } ?? ""
            onError?("Meta\(suffix): \(message)")
        case .unknown(let type):
            onEvent?(.unknown(type))
        }
    }

    private func _close() {
        closing = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pendingAudio.removeAll()
        pendingEndInput = false
    }
}
