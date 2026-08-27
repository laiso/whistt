import Foundation
import WhisttCore

guard let apiKey = EnvLoader.value(for: "GEMINI_API_KEY") else {
    fputs("GEMINI_API_KEY is required\n", stderr)
    exit(2)
}
guard CommandLine.arguments.count == 2,
      let pcm = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      !pcm.isEmpty else {
    fputs("usage: gemini-live-probe <pcm16le-16khz-mono.raw>\n", stderr)
    exit(2)
}

let done = DispatchSemaphore(value: 0)
let resultLock = NSLock()
var completed = false
let socket = GeminiLiveWS(apiKey: apiKey, model: "gemini-3.5-transcribe-live")

socket.onEvent = { event in
    switch event {
    case .setupComplete:
        print("[probe] setup complete")
    case .interimTranscript(let text):
        print("[probe] interim chars=\(text.count)")
    case .finalTranscript(let text):
        print("[probe] final=\(text)")
        resultLock.lock()
        completed = true
        resultLock.unlock()
        done.signal()
    case .error(let message):
        fputs("Gemini error: \(message)\n", stderr)
        done.signal()
    default:
        break
    }
}
socket.onError = { message in
    fputs("Gemini transport error: \(message)\n", stderr)
    done.signal()
}

// Deliberately enqueue activityStart before setupComplete, exactly as the app does.
// GeminiLiveWS retains this and early audio until the setup handshake finishes.
socket.connect()
socket.sendActivityStart()

let chunkBytes = 3_200 // 100 ms, PCM16 mono at 16 kHz
let audioQueue = DispatchQueue(label: "gemini.probe.audio")
audioQueue.async {
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkBytes, pcm.count)
        socket.sendAudio(pcm.subdata(in: offset..<end))
        offset = end
        Thread.sleep(forTimeInterval: 0.1)
    }
    socket.sendActivityEnd()
}

_ = done.wait(timeout: .now() + 25)
socket.close()
resultLock.lock()
let succeeded = completed
resultLock.unlock()
exit(succeeded ? 0 : 1)
