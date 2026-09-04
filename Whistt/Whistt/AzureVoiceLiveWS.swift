import Foundation

public final class AzureVoiceLiveTransport: NSObject, TranscriptionTransport, URLSessionWebSocketDelegate {
    public let sampleRate = AzureVoiceLiveFormat.sampleRate
    public var onEvent: ((TranscriptionTransportEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    /// When set, bypasses `AzureVoiceLiveSettings` resolution (used by the CLI
    /// probe, which reads credentials from `.env` instead of app defaults).
    private let endpointOverride: String?
    private let queue = DispatchQueue(label: "azure.voicelive.ws.q")
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var configured = false
    private var closing = false
    private var sender: AudioStreamSender?

    public init(apiKey: String, model: String = "mai-transcribe-2", endpoint: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.endpointOverride = endpoint
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
        let endpoint = endpointOverride ?? AzureVoiceLiveSettings.resolveEndpoint()
        guard let endpoint else {
            onError?("Azure: no endpoint configured (set it in Provider Settings…)")
            return
        }
        guard let url = AzureVoiceLiveFormat.streamURL(endpoint: endpoint) else {
            onError?("Azure: AZURE_SPEECH_ENDPOINT is not a valid endpoint URL")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        configured = false
        closing = false
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
                task.send(.string(AzureVoiceLiveMessage.audioAppend(data))) { [weak self] error in
                    self?.handleSendError(error)
                    completion()
                }
            },
            onEndOfAudio: { [weak self] in
                self?.sendText(AzureVoiceLiveMessage.audioCommit)
            },
            onDiagnostic: nil
        )
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        do {
            sendText(try AzureVoiceLiveMessage.sessionUpdate(model: model))
        } catch {
            onError?("Azure session.update encode: \(error.localizedDescription)")
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
        task?.send(.string(string)) { [weak self] error in
            self?.handleSendError(error)
        }
    }

    private func handleSendError(_ error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.abortSender()
            self.onError?("Azure send: \(error.localizedDescription)")
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
                if let string, let event = AzureVoiceLiveEvent.decode(from: string) {
                    self.handle(event)
                    // A protocol-level error is terminal for this socket; stop
                    // before another receive fans out into send failures.
                    if case .error = event {
                        if !self.closing { self._close() }
                        return
                    }
                }
                if self.task != nil { self.receiveLoop() }
            case .failure(let error):
                if !self.closing {
                    self.abortSender()
                    self.onError?("Azure ws receive: \(error.localizedDescription)")
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
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
            self.onError?("Azure ws closed: code=\(closeCode.rawValue), reason=\(reasonText)")
        }
    }

    private func handle(_ event: AzureVoiceLiveEvent) {
        switch event {
        case .sessionUpdated:
            markConfigured()
        case .speechStarted:
            onEvent?(.speechStarted)
        case .speechStopped:
            break
        case .bufferCommitted:
            onEvent?(.turnComplete)
        case .transcriptCompleted(let text):
            onEvent?(.final(text))
        case .error(let code, let message):
            let suffix = code.map { " [\($0)]" } ?? ""
            onError?("Azure\(suffix): \(message)")
        case .unknown(let type):
            onEvent?(.unknown("azure.\(type)"))
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
