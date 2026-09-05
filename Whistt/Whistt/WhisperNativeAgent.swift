import Foundation
import AVFoundation

final class WhisperNativeAgent: NSObject {
    private let audioEngine = AVAudioEngine()
    private var transport: TranscriptionTransport?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let apiKey: String
    private let model: String
    private let provider: TranscriptionProvider
    private var isRunning = false
    private let bytesLock = NSLock()
    private var _bytesSent = 0
    private var outputGate = FinalTranscriptOutputGate()
    private var sessionStartedAt: TimeInterval?
    private var connectStartedAt: TimeInterval?
    private var inputEndedAt: TimeInterval?
    private var firstTranscriptLogged = false
    // Results from a transport may arrive during its deferred close. Associate
    // every transport callback with the start that created it so an older
    // capture can never be delivered into a newer one.
    private var sessionGeneration = 0
    private static let finalGraceSeconds: TimeInterval = 5.0

    var onTranscriptComplete: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(apiKey: String, model: String = "gpt-transcribe", provider: TranscriptionProvider = .openAI) {
        self.apiKey = apiKey
        self.model = model
        self.provider = provider
        let transport = TranscriptionTransportFactory.make(provider: provider, apiKey: apiKey, model: model)
        self.transport = transport
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: transport.sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionGeneration += 1
        let generation = sessionGeneration
        resetBytes()
        outputGate.reset()
        sessionStartedAt = ProcessInfo.processInfo.systemUptime
        connectStartedAt = nil
        inputEndedAt = nil
        firstTranscriptLogged = false
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard generation == self.sessionGeneration else { return }
                guard granted else {
                    self.isRunning = false
                    self.onError?("microphone permission denied — enable in System Settings → Privacy & Security → Microphone")
                    return
                }
                // User may have released the hotkey before the (async) permission prompt resolved —
                // don't open a socket for a session that's already been cancelled.
                guard self.isRunning else { return }
                self.connect(generation: generation)
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
        inputEndedAt = ProcessInfo.processInfo.systemUptime
        WhisttLog.event(
            "timing provider=\(provider.rawValue) milestone=input_end "
                + "sinceStartMs=\(elapsedMilliseconds(since: sessionStartedAt)) audioBytes=\(bytes)"
        )
        let minBytes = Int(targetFormat.sampleRate * 0.1) * MemoryLayout<Int16>.size
        let awaitsFinalTranscript = bytes >= minBytes
        if awaitsFinalTranscript {
            transport?.endInput()
        } else {
            WhisttLog.event("skipped finish: only \(bytes) bytes (need ≥\(minBytes))")
        }

        // Capture the WS locally so a subsequent start() can't have its fresh socket
        // closed by this deferred teardown.
        let closing = transport
        transport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalGraceSeconds) {
            closing?.close()
        }
        return awaitsFinalTranscript
    }

    private func connect(generation: Int) {
        connectStartedAt = ProcessInfo.processInfo.systemUptime
        WhisttLog.event("connecting (provider=\(provider.rawValue), model=\(model))")
        // stop() releases the previous transport. A fresh start creates the selected
        // provider's transport so delayed teardown can never close a new session.
        if transport == nil {
            transport = TranscriptionTransportFactory.make(provider: provider, apiKey: apiKey, model: model)
        }
        transport?.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, generation == self.sessionGeneration else { return }
                self.handle(event)
            }
        }
        transport?.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, generation == self.sessionGeneration else { return }
                self.onError?(message)
            }
        }
        transport?.connect()
    }

    private func handle(_ event: TranscriptionTransportEvent) {
        switch event {
        case .ready:
            WhisttLog.event(
                "transport ready (provider=\(provider.rawValue), connectMs=\(elapsedMilliseconds(since: connectStartedAt)))"
            )
        case .speechStarted:
            WhisttLog.event("speech_started")
        case .partial(let text, let replacesPrevious):
            logFirstTranscriptIfNeeded(kind: "partial")
            if replacesPrevious {
                WhisttLog.debugEvent("replacement partial chars=\(text.count)")
            } else {
                WhisttLog.delta(text)
            }
        case .revision(let revision):
            logFirstTranscriptIfNeeded(kind: "partial")
            WhisttLog.debugEvent(
                "revision kept internal confirmedChars=\(revision.confirmedText.count) interimChars=\(revision.interimText.count)"
            )
        case .final(let text):
            logFirstTranscriptIfNeeded(kind: "final")
            WhisttLog.event(
                "timing provider=\(provider.rawValue) milestone=final "
                    + "sinceStartMs=\(elapsedMilliseconds(since: sessionStartedAt)) "
                    + "afterInputEndMs=\(elapsedMilliseconds(since: inputEndedAt)) chars=\(text.count)"
            )
            WhisttLog.final(text)
            if let completed = outputGate.consume(event) {
                onTranscriptComplete?(completed)
            }
        case .turnComplete:
            WhisttLog.event("turn complete")
        case .unknown(let type):
            if type.hasPrefix("diagnostic.") { WhisttLog.event(type) }
            else { WhisttLog.debugEvent(type) }
        }
    }

    private func logFirstTranscriptIfNeeded(kind: String) {
        guard !firstTranscriptLogged else { return }
        firstTranscriptLogged = true
        WhisttLog.event(
            "timing provider=\(provider.rawValue) milestone=first_\(kind) "
                + "sinceStartMs=\(elapsedMilliseconds(since: sessionStartedAt)) "
                + "afterInputEndMs=\(elapsedMilliseconds(since: inputEndedAt))"
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval?) -> Int {
        guard let start else { return -1 }
        return max(0, Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()))
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
        transport?.sendAudio(data)
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
