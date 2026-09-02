import Foundation
import WhisttCore

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: meta-live-probe /path/to/pcm16le-24khz-mono.raw\n".data(using: .utf8)!)
    exit(2)
}

guard let apiKey = EnvLoader.value(for: "META_API_KEY") else {
    FileHandle.standardError.write("META_API_KEY is required\n".data(using: .utf8)!)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let pcm = try? Data(contentsOf: inputURL), !pcm.isEmpty else {
    FileHandle.standardError.write("could not read non-empty PCM input\n".data(using: .utf8)!)
    exit(2)
}

let socket = MetaTranscriptionTransport(
    apiKey: apiKey,
    model: "muse-voice-transcribe-1.0"
)
let semaphore = DispatchSemaphore(value: 0)
var succeeded = false

socket.onEvent = { event in
    switch event {
    case .ready:
        let bytesPerSecond = 48_000
        let frameBytes = 3_840 // 80 ms at PCM16/24 kHz/mono
        DispatchQueue.global().async {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + frameBytes, pcm.count)
                let chunkBytes = end - offset
                socket.sendAudio(pcm.subdata(in: offset..<end))
                offset = end
                Thread.sleep(forTimeInterval: Double(chunkBytes) / Double(bytesPerSecond))
            }
            socket.endInput()
        }
    case .partial(let text, _):
        FileHandle.standardError.write("partial chars=\(text.count)\n".data(using: .utf8)!)
    case .final(let text):
        print(text)
        succeeded = !text.isEmpty
        semaphore.signal()
    case .turnComplete, .speechStarted, .unknown:
        break
    }
}
socket.onError = { message in
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    semaphore.signal()
}

socket.connect()
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { semaphore.signal() }
_ = semaphore.wait(timeout: .now() + 35)
socket.close()
exit(succeeded ? 0 : 1)
