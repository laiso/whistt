import Foundation

public final class GeminiLiveWS: NSObject, URLSessionWebSocketDelegate {
    public var onEvent: ((GeminiLiveEvent) -> Void)?
    public var onError: ((String) -> Void)?

    private let apiKey: String
    private let model: String
    private let queue = DispatchQueue(label: "gemini.live.ws.q")
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closing = false
    private var configured = false
    private var pendingRealtimeMessages: [String] = []
    private var sender: AudioStreamSender?

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        self.delegateQueue = operationQueue
        super.init()
    }

    public func connect() { queue.async { [weak self] in self?._connect() } }
    public func sendActivityStart() { queue.async { [weak self] in self?.sendWhenConfigured(GeminiLiveMessage.activityStart) } }
    public func sendAudio(_ data: Data) { queue.async { [weak self] in self?.sender?.enqueue(data) } }
    public func sendActivityEnd() { queue.async { [weak self] in self?._endAudio() } }
    public func close() { queue.async { [weak self] in self?._close() } }

    private func _connect() {
        var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: components.url!)
        self.session = session
        self.task = task
        closing = false
        configured = false
        pendingRealtimeMessages.removeAll(keepingCapacity: true)
        sender = makeSender()
        task.resume()
        receiveLoop()
    }

    /// Passthrough policy: raw PCM flows to the socket as it arrives, but
    /// only after `setupComplete`; pre-ready audio is buffered by the sender.
    private func makeSender() -> AudioStreamSender {
        AudioStreamSender(
            queue: queue,
            format: AudioStreamFormat(sampleRate: 16_000, channelCount: 1, bytesPerSample: 2),
            policy: .passthrough(),
            send: { [weak self] data, completion in
                self?.send(string: GeminiLiveMessage.audio(data), completion: completion)
            },
            onEndOfAudio: { [weak self] in
                self?.send(string: GeminiLiveMessage.activityEnd, completion: {})
            }
        )
    }

    private func _endAudio() {
        sender?.endInput()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        do {
            send(try GeminiLiveMessage.setup(model: model))
        } catch {
            onError?("Gemini setup encode: \(error.localizedDescription)")
        }
    }

    private func send(_ string: String) {
        send(string: string, completion: {})
    }

    private func send(string: String, completion: @escaping () -> Void) {
        guard let task else {
            completion()
            return
        }
        task.send(.string(string)) { [weak self] error in
            guard let self else {
                completion()
                return
            }
            guard let error else {
                completion()
                return
            }
            self.queue.async {
                if !self.closing {
                    self.sender?.reset()
                    self.sender = nil
                    self.onError?("Gemini send: \(error.localizedDescription)")
                }
                completion()
            }
        }
    }

    private func sendWhenConfigured(_ string: String) {
        if configured {
            send(string)
        } else {
            pendingRealtimeMessages.append(string)
        }
    }

    private func markConfigured() {
        guard !configured else { return }
        configured = true
        for message in pendingRealtimeMessages { send(message) }
        pendingRealtimeMessages.removeAll(keepingCapacity: true)
        sender?.markReady()
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
                if let string, let event = GeminiLiveEvent.decode(from: string) {
                    if event == .setupComplete { self.markConfigured() }
                    self.onEvent?(event)
                }
                if self.task != nil { self.receiveLoop() }
            case .failure(let error):
                if !self.closing {
                    self.sender?.reset()
                    self.sender = nil
                    self.onError?("Gemini ws: \(error.localizedDescription)")
                }
            }
        }
    }

    private func _close() {
        closing = true
        sender?.reset()
        sender = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pendingRealtimeMessages.removeAll()
    }
}
