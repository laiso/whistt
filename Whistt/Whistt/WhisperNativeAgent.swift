import Foundation
import AVFoundation

final class WhisperNativeAgent: NSObject {
    private let audioEngine = AVAudioEngine()
    private var ws: RealtimeWS?
    private var geminiWS: GeminiLiveWS?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let apiKey: String
    private let model: String
    private let provider: TranscriptionProvider
    private var isRunning = false
    private let bytesLock = NSLock()
    private var _bytesSent = 0
    private var lastDeliveredTranscript: String?
    private static let finalGraceSeconds: TimeInterval = 5.0

    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptComplete: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(apiKey: String, model: String = "gpt-realtime-whisper", provider: TranscriptionProvider = .openAI) {
        self.apiKey = apiKey
        self.model = model
        self.provider = provider
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: provider == .gemini ? 16_000 : 24_000,
            channels: 1,
            interleaved: true
        )!
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resetBytes()
        lastDeliveredTranscript = nil
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.isRunning = false
                    self.onError?("microphone permission denied — enable in System Settings → Privacy & Security → Microphone")
                    return
                }
                // User may have released the hotkey before the (async) permission prompt resolved —
                // don't open a socket for a session that's already been cancelled.
                guard self.isRunning else { return }
                self.connect()
                self.startAudio()
            }
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        converter = nil

        let bytes = bytesSent()
        let minBytes = Int(targetFormat.sampleRate * 0.1) * MemoryLayout<Int16>.size
        let awaitsFinalTranscript = bytes >= minBytes
        if awaitsFinalTranscript {
            if provider == .gemini {
                geminiWS?.sendActivityEnd()
            } else {
                ws?.sendCommit()
            }
        } else {
            WhisttLog.event("skipped finish: only \(bytes) bytes (need ≥\(minBytes))")
        }

        // Capture the WS locally so a subsequent start() can't have its fresh socket
        // closed by this deferred teardown.
        let closing = ws
        let closingGemini = geminiWS
        ws = nil
        geminiWS = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalGraceSeconds) {
            closing?.close()
            closingGemini?.close()
        }
        return awaitsFinalTranscript
    }

    private func connect() {
        WhisttLog.event("connecting (provider=\(provider.rawValue), model=\(model))")
        if provider == .gemini {
            connectGemini()
            return
        }
        // The URL is ?intent=transcription and session.type is "transcription" — passing
        // ?model=<transcription-model> is rejected because the URL's model param is the
        // *realtime conversational* model. Our transcription model goes only in
        // audio.input.transcription.model. turn_detection: null gives us manual commit.
        let ws = RealtimeWS(apiKey: apiKey, model: model)
        ws.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        ws.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.onError?(msg) }
        }
        self.ws = ws
        ws.connect()
    }

    private func connectGemini() {
        let socket = GeminiLiveWS(apiKey: apiKey, model: model)
        socket.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleGemini(event) }
        }
        socket.onError = { [weak self] message in
            DispatchQueue.main.async { self?.onError?(message) }
        }
        geminiWS = socket
        socket.connect()
        // GeminiLiveWS queues this and all early audio until setupComplete, keeping
        // each push-to-talk turn's pre-roll isolated inside its own socket.
        socket.sendActivityStart()
    }

    private func handleGemini(_ event: GeminiLiveEvent) {
        switch event {
        case .setupComplete:
            WhisttLog.event("Gemini setup complete")
        case .interimTranscript(let text):
            // Gemini interim results are replacement hypotheses, not append-only deltas.
            WhisttLog.debugEvent("gemini.interim chars=\(text.count)")
        case .finalTranscript(let text):
            WhisttLog.final(text)
            deliverComplete(text)
        case .turnComplete:
            WhisttLog.event("Gemini turn complete")
        case .error(let message):
            onError?("Gemini: \(message)")
        case .unknown:
            WhisttLog.debugEvent("gemini.unknown")
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .sessionCreated:
            WhisttLog.event("session.created")
            ws?.sendSessionUpdate()
        case .sessionUpdated:
            WhisttLog.event("session.updated (ready)")
        case .speechStarted:
            WhisttLog.event("speech_started")
        case .bufferCommitted:
            WhisttLog.event("committed")
        case .delta(let text):
            WhisttLog.delta(text)
            onTranscriptDelta?(text)
        case .finalTranscript(let text):
            WhisttLog.final(text)
            deliverComplete(text)
        case .conversationItem(let transcripts):
            // The same final transcript can arrive both as `*.completed` and embedded
            // in a `conversation.item.added/done` payload — dedupe so output isn't doubled.
            for t in transcripts { deliverComplete(t) }
        case .transcriptionFailed(let code, let message):
            onError?("transcription failed [\(code)]: \(message)")
        case .error(let message):
            onError?(message)
        case .unknown(let type):
            WhisttLog.debugEvent(type)
        }
    }

    private func deliverComplete(_ transcript: String) {
        guard transcript != lastDeliveredTranscript else { return }
        lastDeliveredTranscript = transcript
        onTranscriptComplete?(transcript)
    }

    private func startAudio() {
        let input = audioEngine.inputNode

        // Defensive cleanup: any prior tap (e.g. from a failed previous start) must go.
        input.removeTap(onBus: 0)

        let nativeFormat = input.outputFormat(forBus: 0)
        // If the input device is missing (no mic permission / no device), format is 0ch/0Hz.
        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            isRunning = false
            onError?("no audio input device available — check System Settings → Privacy & Security → Microphone")
            return
        }

        // Pass nil so AVAudioEngine uses the bus's actual native format.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            WhisttLog.event("audio started (\(nativeFormat.channelCount)ch \(Int(nativeFormat.sampleRate))Hz)")
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
            onError?("audio start: \(error.localizedDescription)")
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("convert: \(error.localizedDescription)")
            }
            return
        }
        guard outBuffer.frameLength > 0,
              let int16Ptr = outBuffer.int16ChannelData?[0] else { return }
        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Ptr, count: byteCount)
        sendAudio(data)
    }

    private func sendAudio(_ data: Data) {
        addBytes(data.count)
        if provider == .gemini {
            geminiWS?.sendAudio(data)
        } else {
            ws?.sendAudio(data)
        }
    }

    private func addBytes(_ n: Int) {
        bytesLock.lock(); defer { bytesLock.unlock() }
        _bytesSent += n
    }

    private func bytesSent() -> Int {
        bytesLock.lock(); defer { bytesLock.unlock() }
        return _bytesSent
    }

    private func resetBytes() {
        bytesLock.lock(); defer { bytesLock.unlock() }
        _bytesSent = 0
    }
}
