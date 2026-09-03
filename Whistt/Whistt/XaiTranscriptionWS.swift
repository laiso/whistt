import Foundation

public final class XaiTranscriptionTransport: NSObject, TranscriptionTransport, URLSessionWebSocketDelegate {
    public let sampleRate = XaiTranscriptionFormat.sampleRate
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let apiKey: String
    private let interimResults: Bool
    private let queue = DispatchQueue(label: "xai.transcription.ws.q")
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var configured = false
    private var closing = false
    private var sender: AudioStreamSender?
    private var endInputSent = false
    private let eventReducer = XaiTranscriptEventReducer()

    public init(apiKey: String, interimResults: Bool = true) {
        self.apiKey = apiKey
        self.interimResults = interimResults
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
        var request = URLRequest(url: XaiTranscriptionFormat.streamURL(interimResults: interimResults))
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        configured = false
        closing = false
        endInputSent = false
        eventReducer.reset()
        sender = makeSender()
        task.resume()
        receiveLoop()
    }

    private func makeSender() -> AudioStreamSender {
        AudioStreamSender(
            queue: queue,
            format: AudioStreamFormat(sampleRate: sampleRate, channelCount: 1, bytesPerSample: 2),
            policy: .fixedFrame(frameDuration: 0.1),
            send: { [weak self] data, completion in
                guard let task = self?.task else {
                    completion()
                    return
                }
                task.send(.data(data)) { [weak self] error in
                    self?.handleSendError(error)
                    completion()
                }
            },
            onEndOfAudio: { [weak self] in
                guard let self, !self.endInputSent else { return }
                endInputSent = true
                self.sendText(XaiTranscriptionMessage.audioDone)
            },
            onDiagnostic: nil
        )
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Nothing to send: xAI configures the session via query parameters and
        // answers with transcript.created, which is what unblocks audio.
    }

    private func _sendAudio(_ data: Data) {
        sender?.enqueue(data)
    }

    private func _endInput() {
        sender?.endInput()
    }

    private func markConfigured() {
        guard !configured else { return }
        configured = true
        sender?.markReady()
        onEvent?(.ready)
    }

    private func sendText(_ string: String) {
        task?.send(.string(string)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { [weak self] in
                guard let self, !self.closing else { return }
                self.onError?("xAI send: \(error.localizedDescription)")
            }
        }
    }

    private func handleSendError(_ error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.onError?("xAI send: \(error.localizedDescription)")
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
                if let string, let event = XaiTranscriptionEvent.decode(from: string) {
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        self.handle(event)
                        if self.task != nil { self.receiveLoop() }
                    }
                } else if self.task != nil {
                    self.receiveLoop()
                }
            case .failure(let error):
                if !self.closing {
                    if !self.isExpectedPostTranscriptClosure(error) {
                        self.onError?("xAI ws receive: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.abortSender()
            // xAI closes the connection itself after transcript.done; that is
            // the expected teardown for an explicitly ended stream, not a
            // failure. Anything else is reported so the app can recover.
            guard !(self.endInputSent && self.eventReducer.receivedDone) else { return }
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
            self.onError?("xAI ws closed: code=\(closeCode.rawValue), reason=\(reasonText)")
        }
    }

    /// URLSession usually reports a receive error right before the close
    /// callback after the server ends the session; treat it as teardown when
    /// the stream was finished deliberately.
    private func isExpectedPostTranscriptClosure(_ error: Error) -> Bool {
        guard endInputSent, eventReducer.receivedDone else { return false }
        let nsError = error as NSError
        return (nsError.domain == NSPOSIXErrorDomain && nsError.code == 57)
            || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -9805)
    }

    private func abortSender() {
        sender?.reset()
        sender = nil
    }

    private func handle(_ event: XaiTranscriptionEvent) {
        if case .created = event {
            markConfigured()
            return
        }
        if case .error(let code, let message) = event {
            let suffix = code.map { " [\($0)]" } ?? ""
            onError?("xAI\(suffix): \(message)")
            return
        }
        for outputEvent in eventReducer.reduce(event) {
            onEvent?(outputEvent)
        }
    }

    private func _close() {
        closing = true
        abortSender()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
