import Foundation
import WhisttCore

// Live probe for the Azure Voice Live transport with mai-transcribe-2.
//
// usage: azure-voice-live-probe /path/to/pcm16le-24khz-mono.raw
//
// Without arguments it only verifies session setup. With a PCM file it
// streams real speech through AzureVoiceLiveTransport at real-time pace and
// prints the normalized transport events.

guard let apiKey = EnvLoader.value(for: "AZURE_SPEECH_API_KEY") else {
    FileHandle.standardError.write("AZURE_SPEECH_API_KEY is required\n".data(using: .utf8)!)
    exit(2)
}
guard let endpoint = EnvLoader.value(for: "AZURE_SPEECH_ENDPOINT") else {
    FileHandle.standardError.write("AZURE_SPEECH_ENDPOINT is required\n".data(using: .utf8)!)
    exit(2)
}

let pcm: Data?
if CommandLine.arguments.count == 2 {
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    pcm = try? Data(contentsOf: inputURL)
    guard let pcm, !pcm.isEmpty else {
        FileHandle.standardError.write("could not read non-empty PCM input\n".data(using: .utf8)!)
        exit(2)
    }
} else {
    pcm = nil
}

let socket = AzureVoiceLiveTransport(apiKey: apiKey, endpoint: endpoint)
let semaphore = DispatchSemaphore(value: 0)
var succeeded = false

func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

socket.onEvent = { event in
    switch event {
    case .ready:
        emit("ready")
        guard let pcm else { return }
        // Stream at real-time pace so server-side VAD sees a natural signal.
        let bytesPerSecond = Int(AzureVoiceLiveFormat.sampleRate) * 2
        let frameBytes = 4_800 // 100 ms
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
            emit("--- audio stream ended ---")
        }
    case .speechStarted:
        emit("speech started")
    case .turnComplete:
        emit("turn complete")
    case .final(let text):
        emit("final: \(text)")
        succeeded = !text.isEmpty
        semaphore.signal()
    case .partial, .revision:
        break
    case .unknown(let type):
        emit(type)
    }
}
socket.onError = { message in
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    semaphore.signal()
}

socket.connect()
if pcm == nil {
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 20)
} else {
    // Audio duration + 25 s of slack for VAD, commit, and final transcript.
    let seconds = Double(pcm!.count) / Double(AzureVoiceLiveFormat.sampleRate * 2)
    _ = semaphore.wait(timeout: .now() + seconds + 25)
}
socket.close()
exit(succeeded ? 0 : (pcm == nil ? 0 : 1))
