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
    private var sender: AudioStreamSender?
    private var lastSenderDiagnostic: String?
    private var audioChunksSent = 0
    private var audioBytesSent = 0
    private var endInputSent = false
    private var receivedFinalTranscript = false
    private var sendFailureReported = false
    private var firstAudioSendAt: TimeInterval?
    private var previousAudioSendAt: TimeInterval?
    private var minimumSendGapMs: Double?
    private var maximumSendGapMs: Double?
    private var audioTimingReported = false

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
        audioChunksSent = 0
        audioBytesSent = 0
        endInputSent = false
        receivedFinalTranscript = false
        sendFailureReported = false
        firstAudioSendAt = nil
        previousAudioSendAt = nil
        minimumSendGapMs = nil
        maximumSendGapMs = nil
        audioTimingReported = false
        lastSenderDiagnostic = nil
        sender = makeSender()
        task.resume()
        receiveLoop()
    }

    private func makeSender() -> AudioStreamSender {
        AudioStreamSender(
            queue: queue,
            format: AudioStreamFormat(sampleRate: sampleRate, channelCount: 1, bytesPerSample: 2),
            policy: .fixedFrame(frameDuration: 0.08),
            send: { [weak self] data, completion in
                self?.sendBinary(data, completion: completion)
            },
            onEndOfAudio: { [weak self] in
                guard let self, !self.endInputSent else { return }
                endInputSent = true
                sendText(MetaTranscriptionMessage.endStream)
            },
            onDiagnostic: { [weak self] message in
                self?.lastSenderDiagnostic = message
            }
        )
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
        task?.send(.string(string)) { [weak self] error in self?.handleSendError(error) }
    }

    private func sendBinary(_ data: Data, completion: @escaping () -> Void) {
        recordAudioSendTime()
        audioChunksSent += 1
        audioBytesSent += data.count
        guard let task else {
            completion()
            return
        }
        task.send(.data(data)) { [weak self] error in
            self?.handleSendError(error)
            completion()
        }
    }

    private func handleSendError(_ error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, !self.closing, !self.sendFailureReported else { return }
            self.sendFailureReported = true
            self.abortSender()
            self.onError?("Meta send: \(self.describe(error)); \(self.sessionContext)")
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
                if let string, let event = MetaTranscriptionEvent.decode(from: string) {
                    self.handle(event)
                }
                if self.task != nil { self.receiveLoop() }
            case .failure(let error):
                if !self.closing {
                    self.abortSender()
                    if !self.isExpectedPostTranscriptClosure(error) {
                        self.onError?("Meta ws receive: \(self.describe(error)); \(self.sessionContext)")
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
            if closeCode == .normalClosure,
               self.endInputSent,
               self.receivedFinalTranscript {
                return
            }
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
            self.onError?(
                "Meta ws closed: code=\(closeCode.rawValue), reason=\(reasonText); \(self.sessionContext)"
            )
        }
    }

    private var sessionContext: String {
        var context =
            "configured=\(configured), endInputSent=\(endInputSent), audioChunks=\(audioChunksSent), audioBytes=\(audioBytesSent)"
        context += ", \(audioTimingSummary)"
        if let lastSenderDiagnostic {
            context += ", sender: \(lastSenderDiagnostic)"
        }
        return context
    }

    private var audioTimingSummary: String {
        let elapsedMs = firstAudioSendAt.map {
            Int(((ProcessInfo.processInfo.systemUptime - $0) * 1_000).rounded())
        } ?? 0
        let minimum = minimumSendGapMs.map { String(format: "%.1f", $0) } ?? "n/a"
        let maximum = maximumSendGapMs.map { String(format: "%.1f", $0) } ?? "n/a"
        return "sendElapsedMs=\(elapsedMs), sendGapMinMs=\(minimum), sendGapMaxMs=\(maximum)"
    }

    private func recordAudioSendTime() {
        let current = ProcessInfo.processInfo.systemUptime
        if firstAudioSendAt == nil { firstAudioSendAt = current }
        if let previousAudioSendAt {
            let gap = (current - previousAudioSendAt) * 1_000
            minimumSendGapMs = min(minimumSendGapMs ?? gap, gap)
            maximumSendGapMs = max(maximumSendGapMs ?? gap, gap)
        }
        previousAudioSendAt = current
    }

    private func reportAudioTiming() {
        guard !audioTimingReported else { return }
        audioTimingReported = true
        onEvent?(.unknown("diagnostic.meta.audio \(audioTimingSummary), audioChunks=\(audioChunksSent), audioBytes=\(audioBytesSent)"))
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var result = "domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += ", underlyingDomain=\(underlying.domain), underlyingCode=\(underlying.code)"
        }
        return result
    }

    /// URLSession commonly reports a receive error immediately before the
    /// normal WebSocket close callback. Once Meta has returned the final
    /// transcript for an explicitly ended stream, these codes describe the
    /// expected teardown rather than a failed transcription.
    private func isExpectedPostTranscriptClosure(_ error: Error) -> Bool {
        guard endInputSent, receivedFinalTranscript else { return false }
        let nsError = error as NSError
        return (nsError.domain == NSPOSIXErrorDomain && nsError.code == 57)
            || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -9805)
    }

    private func handle(_ event: MetaTranscriptionEvent) {
        switch event {
        case .handshakeAcknowledged:
            markConfigured()
        case .transcript(let text, let final):
            if final {
                receivedFinalTranscript = true
                reportAudioTiming()
                onEvent?(.final(text))
            }
            else { onEvent?(.partial(text: text, replacesPrevious: true)) }
        case .speechStart:
            onEvent?(.speechStarted)
        case .speechEnd:
            onEvent?(.turnComplete)
        case .speechComplete(let text, _):
            receivedFinalTranscript = true
            reportAudioTiming()
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
        abortSender()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
