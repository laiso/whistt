import Foundation

public final class ElevenLabsScribeTransport: NSObject, TranscriptionTransport, URLSessionWebSocketDelegate {
    public let sampleRate = ElevenLabsScribeFormat.sampleRate
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "elevenlabs.scribe.ws.q")
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var configured = false
    private var closing = false
    private var sender: AudioStreamSender?
    /// Stable segments already committed by the API during this push-to-talk turn.
    private var committedSegments: [String] = []
    /// True after local endInput; the next committed_transcript finalizes the turn.
    private var awaitingFinalCommit = false
    private var deliveredFinal = false

    public init(apiKey: String, model: String = ElevenLabsScribeMessage.defaultModel) {
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
        var request = URLRequest(url: ElevenLabsScribeMessage.streamURL(model: model))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        configured = false
        closing = false
        committedSegments = []
        awaitingFinalCommit = false
        deliveredFinal = false
        sender = makeSender()
        task.resume()
        receiveLoop()
    }

    private func makeSender() -> AudioStreamSender {
        AudioStreamSender(
            queue: queue,
            format: AudioStreamFormat(sampleRate: sampleRate, channelCount: 1, bytesPerSample: 2),
            // Docs recommend 0.1–1.0 s chunks; 100 ms matches Azure's framing.
            policy: .fixedFrame(frameDuration: 0.1),
            send: { [weak self] data, completion in
                guard let task = self?.task else {
                    completion()
                    return
                }
                task.send(.string(ElevenLabsScribeMessage.audioChunk(data))) { [weak self] error in
                    self?.handleSendError(error)
                    completion()
                }
            },
            onEndOfAudio: { [weak self] in
                self?.sendFinalCommit()
            },
            onDiagnostic: nil
        )
    }

    private func _sendAudio(_ data: Data) {
        sender?.enqueue(data)
    }

    private func _endInput() {
        awaitingFinalCommit = true
        sender?.endInput()
    }

    private func sendFinalCommit() {
        sendText(ElevenLabsScribeMessage.commit())
    }

    private func markConfigured() {
        guard !configured else { return }
        configured = true
        sender?.markReady()
        onEvent?(.ready)
    }

    private func sendText(_ string: String) {
        task?.send(.string(string)) { [weak self] error in
            self?.handleSendError(error)
        }
    }

    private func handleSendError(_ error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.abortSender()
            self.onError?("ElevenLabs send: \(error.localizedDescription)")
        }
    }

    private func abortSender() {
        sender?.reset()
        sender = nil
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
                if let string, let event = ElevenLabsScribeEvent.decode(from: string) {
                    self.handle(event)
                    if case .error = event {
                        if !self.closing { self._close() }
                        return
                    }
                }
                if self.task != nil { self.receiveLoop() }
            case .failure(let error):
                if !self.closing {
                    self.abortSender()
                    if !self.isExpectedPostFinalClosure(error) {
                        self.onError?("ElevenLabs ws receive: \(error.localizedDescription)")
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
            if closeCode == .normalClosure, self.deliveredFinal {
                return
            }
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
            self.onError?("ElevenLabs ws closed: code=\(closeCode.rawValue), reason=\(reasonText)")
        }
    }

    private func isExpectedPostFinalClosure(_ error: Error) -> Bool {
        guard deliveredFinal else { return false }
        let nsError = error as NSError
        return (nsError.domain == NSPOSIXErrorDomain && nsError.code == 57)
            || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -9805)
    }

    private func joinedCommittedText() -> String {
        committedSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func combinedDisplayText(partial: String) -> String {
        let committed = joinedCommittedText()
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return trimmedPartial }
        if trimmedPartial.isEmpty { return committed }
        return committed + " " + trimmedPartial
    }

    private func handle(_ event: ElevenLabsScribeEvent) {
        switch event {
        case .sessionStarted:
            markConfigured()
        case .partialTranscript(let text):
            // Cumulative for the turn: prior committed segments + live partial.
            onEvent?(.partial(text: combinedDisplayText(partial: text), replacesPrevious: true))
        case .committedTranscript(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                committedSegments.append(trimmed)
            }
            if awaitingFinalCommit {
                deliverFinalIfNeeded()
            } else {
                // Mid-session auto-commit (~36 s): keep text internal via partial.
                onEvent?(.partial(text: joinedCommittedText(), replacesPrevious: true))
            }
        case .error(let code, let message):
            let suffix = code.map { " [\($0)]" } ?? ""
            onError?("ElevenLabs\(suffix): \(message)")
        case .unknown(let type):
            onEvent?(.unknown("elevenlabs.\(type)"))
        }
    }

    private func deliverFinalIfNeeded() {
        guard !deliveredFinal else { return }
        deliveredFinal = true
        let text = joinedCommittedText()
        onEvent?(.final(text))
        onEvent?(.turnComplete)
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
