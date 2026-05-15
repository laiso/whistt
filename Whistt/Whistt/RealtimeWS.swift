import Foundation

/// Minimal client for the OpenAI Realtime WebSocket endpoint.
///
/// All state and callbacks are serialized on a dedicated queue, so callers can
/// invoke `send*`/`close()` from any thread without locking. Events are delivered
/// on the same queue — the caller is responsible for hopping to wherever it
/// needs to apply them (main queue for UI, etc.).
public final class RealtimeWS {
    public typealias EventHandler = (RealtimeEvent) -> Void
    public typealias ErrorHandler = (String) -> Void

    public var onEvent: EventHandler?
    public var onError: ErrorHandler?

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        let q = DispatchQueue(label: "realtime.ws.q")
        self.queue = q
        let opQ = OperationQueue()
        opQ.maxConcurrentOperationCount = 1
        opQ.underlyingQueue = q
        self.delegateQueue = opQ
    }

    public func connect() {
        queue.async { [weak self] in self?._connect() }
    }

    public func sendSessionUpdate() {
        queue.async { [weak self] in self?._sendSessionUpdate() }
    }

    public func sendAudio(_ data: Data) {
        queue.async { [weak self] in self?._sendAudio(data) }
    }

    public func sendCommit() {
        queue.async { [weak self] in
            self?.send(string: RealtimeMessage.audioCommit)
        }
    }

    public func close() {
        queue.async { [weak self] in self?._close() }
    }

    // MARK: - Private state (all on `queue`)

    private let apiKey: String
    private let model: String
    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closing = false

    private func _connect() {
        // Use the transcription-intent endpoint. Passing `?model=<transcription-model>` is
        // rejected: the URL's `model` query is the *realtime conversational* model. Our
        // transcription model goes only in `session.audio.input.transcription.model`.
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        var request = URLRequest(url: components.url!)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        closing = false
        task.resume()
        receiveLoop()
    }

    private func _sendSessionUpdate() {
        do {
            send(string: try RealtimeMessage.sessionUpdate(model: model))
        } catch {
            onError?("session.update encode: \(error.localizedDescription)")
        }
    }

    private func _sendAudio(_ data: Data) {
        send(string: RealtimeMessage.audioAppend(data))
    }

    private func send(string: String) {
        guard let task = task else { return }
        task.send(.string(string)) { [weak self] err in
            guard let self = self, let err = err else { return }
            self.queue.async {
                guard !self.closing else { return }
                self.onError?("send: \(err.localizedDescription)")
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            // delegateQueue.underlyingQueue == self.queue, so we're already serialized.
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let str) = message,
                   let event = RealtimeEvent.decode(from: str) {
                    self.onEvent?(event)
                }
                if self.task != nil {
                    self.receiveLoop()
                }
            case .failure(let err):
                if !self.closing {
                    self.onError?("ws: \(err.localizedDescription)")
                }
            }
        }
    }

    private func _close() {
        closing = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
