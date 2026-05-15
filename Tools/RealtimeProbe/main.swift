import Foundation
import WhisttCore

let model = EnvLoader.value(for: "WHISTT_MODEL") ?? "gpt-realtime-whisper"
guard let apiKey = EnvLoader.value(for: "OPENAI_API_KEY") else {
    FileHandle.standardError.write("OPENAI_API_KEY not found in env or .env\n".data(using: .utf8)!)
    exit(2)
}

let waitSeconds: TimeInterval = TimeInterval(
    ProcessInfo.processInfo.environment["PROBE_WAIT"].flatMap(Double.init) ?? 10
)
let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "ek-bearer-nada"

print("[probe] mode=\(mode) model=\(model)")

// MARK: - Mint
func mint() throws -> (token: String, sid: String) {
    let url = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
        "session": [
            "type": "transcription",
            "audio": ["input": ["transcription": ["model": model]]]
        ]
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0)
    var token = ""; var sid = ""
    var fail: String?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail = err?.localizedDescription ?? "no data"; return
        }
        token = (j["value"] as? String) ?? ""
        sid = ((j["session"] as? [String: Any])?["id"] as? String) ?? ""
        if let e = j["error"] as? [String: Any], let m = e["message"] as? String { fail = m }
    }.resume()
    sem.wait()
    if let f = fail { throw NSError(domain: "mint", code: -1, userInfo: [NSLocalizedDescriptionKey: f]) }
    return (token, sid)
}

let (ek, sid) = (try? mint()) ?? ("", "")
print("[probe] mint: ek=<redacted len=\(ek.count)> sid=\(sid)")

// MARK: - Stdout-safe formatters
//
// Several auth modes embed the OpenAI API key or the freshly-minted ephemeral
// client secret (EK) in the WS URL's query string or the Sec-WebSocket-Protocol
// list. Those are short-lived but are usable while alive, and stdout can persist
// in CI logs / shell scrollback / screen recordings. Redact before printing.
func redactedURL(_ urlStr: String) -> String {
    let secretKeys: Set<String> = ["client_secret", "ek", "api_key", "Authorization"]
    guard var comps = URLComponents(string: urlStr), let items = comps.queryItems else { return urlStr }
    comps.queryItems = items.map { item in
        secretKeys.contains(item.name)
            ? URLQueryItem(name: item.name, value: "<redacted>")
            : item
    }
    return comps.url?.absoluteString ?? urlStr
}

func redactedProtocols(_ protocols: [String]?) -> [String] {
    (protocols ?? []).map { p in
        p.hasPrefix("openai-insecure-api-key.") ? "openai-insecure-api-key.<redacted>" : p
    }
}

// MARK: - Build URL/auth per mode
let (urlStr, headers, protocols): (String, [(String,String)], [String]?) = {
    switch mode {
    case "ek-bearer-nada":
        return ("wss://api.openai.com/v1/realtime", [("Authorization","Bearer \(ek)")], nil)
    case "ek-bearer-intent":
        return ("wss://api.openai.com/v1/realtime?intent=transcription", [("Authorization","Bearer \(ek)")], nil)
    case "ek-bearer-session":
        return ("wss://api.openai.com/v1/realtime?session=\(sid)", [("Authorization","Bearer \(ek)")], nil)
    case "ek-bearer-session_id":
        return ("wss://api.openai.com/v1/realtime?session_id=\(sid)", [("Authorization","Bearer \(ek)")], nil)
    case "ek-subproto":
        return ("wss://api.openai.com/v1/realtime",
                [], ["realtime","openai-insecure-api-key.\(ek)"])
    case "ek-query":
        return ("wss://api.openai.com/v1/realtime?client_secret=\(ek)", [], nil)
    case "api-intent":
        return ("wss://api.openai.com/v1/realtime?intent=transcription",
                [("Authorization","Bearer \(apiKey)")], nil)
    case "api-model":
        return ("wss://api.openai.com/v1/realtime?model=\(model)",
                [("Authorization","Bearer \(apiKey)")], nil)
    case "api-session":
        return ("wss://api.openai.com/v1/realtime?session=\(sid)",
                [("Authorization","Bearer \(apiKey)")], nil)
    case "api-session_id":
        return ("wss://api.openai.com/v1/realtime?session_id=\(sid)",
                [("Authorization","Bearer \(apiKey)")], nil)
    case "api-modelintent":
        return ("wss://api.openai.com/v1/realtime?intent=transcription&model=\(model)",
                [("Authorization","Bearer \(apiKey)")], nil)
    default:
        return ("wss://api.openai.com/v1/realtime",
                [("Authorization","Bearer \(apiKey)")], nil)
    }
}()

print("[probe] url=\(redactedURL(urlStr)) headers=\(headers.map{$0.0}) protocols=\(redactedProtocols(protocols))")

// MARK: - Connect
final class Probe: NSObject, URLSessionWebSocketDelegate {
    var task: URLSessionWebSocketTask!
    var done = false
    var sentUpdate = false
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        print("[probe] OPEN proto=\(p ?? "nil")"); fflush(stdout)
    }

    func sendJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        sendString(s, label: (obj["type"] as? String) ?? "?")
    }

    func sendString(_ s: String, label: String) {
        print("[probe] -> \(label)"); fflush(stdout)
        task.send(.string(s)) { err in
            if let err = err { print("[probe] send err: \(err.localizedDescription)") }
        }
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith c: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("[probe] CLOSE code=\(c.rawValue) reason=\(r)"); fflush(stdout)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        if let http = task.response as? HTTPURLResponse { print("[probe] HTTP \(http.statusCode)") }
        if let err = err { print("[probe] TASK ERR \(err.localizedDescription)") }
        fflush(stdout)
    }
    var sentAudio = false
    func listen() {
        task.receive { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let m):
                if case .string(let s) = m {
                    print("[probe] <- \(s)"); fflush(stdout)
                    if !self.sentUpdate, s.contains("\"session.created\"") {
                        self.sentUpdate = true
                        self.onSessionCreated()
                    } else if !self.sentAudio, s.contains("\"session.updated\"") {
                        self.sentAudio = true
                        self.sendTestAudio()
                    }
                }
                if !self.done { self.listen() }
            case .failure(let e):
                if !self.done { print("[probe] RECV FAIL \(e.localizedDescription)") }
                self.done = true
            }
        }
    }

    func sendTestAudio() {
        // 2s of 440 Hz sine, pcm16 mono @ 24kHz, sent in 100ms chunks
        let chunkFrames = 2_400  // 100ms at 24kHz
        let totalFrames = 48_000
        var time = 0
        for _ in 0..<(totalFrames / chunkFrames) {
            var pcm = [Int16](repeating: 0, count: chunkFrames)
            for i in 0..<chunkFrames {
                let t = Double(time + i) / 24000.0
                pcm[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 0.3 * Double(Int16.max))
            }
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            sendString(RealtimeMessage.audioAppend(data), label: RealtimeOutgoingType.audioAppend.rawValue)
            time += chunkFrames
        }
        // Give the server a beat before commit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.sendString(RealtimeMessage.audioCommit, label: RealtimeOutgoingType.audioCommit.rawValue)
        }
    }

    func onSessionCreated() {
        let action = ProcessInfo.processInfo.environment["PROBE_ACTION"] ?? ""
        switch action {
        case "realtime-text-only":
            do {
                let json = try RealtimeMessage.sessionUpdate(model: "gpt-realtime-whisper")
                sendString(json, label: RealtimeOutgoingType.sessionUpdate.rawValue)
            } catch {
                print("[probe] session.update encode failed: \(error.localizedDescription)")
            }
        case "realtime-no-output":
            sendJSON([
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "output_modalities": [],
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                            "transcription": ["model": "gpt-realtime-whisper"]
                        ]
                    ]
                ]
            ])
        case "transcription-min":
            sendJSON([
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": [
                        "input": [
                            "transcription": ["model": "gpt-realtime-whisper"]
                        ]
                    ]
                ]
            ])
        default: break
        }
    }
}

let p = Probe()
let cfg = URLSessionConfiguration.default
let sess = URLSession(configuration: cfg, delegate: p, delegateQueue: nil)
let u = URL(string: urlStr)!
if let protocols = protocols {
    p.task = sess.webSocketTask(with: u, protocols: protocols)
} else {
    var req = URLRequest(url: u)
    for (k, v) in headers { req.addValue(v, forHTTPHeaderField: k) }
    p.task = sess.webSocketTask(with: req)
}
p.task.resume()
p.listen()
RunLoop.main.run(until: Date(timeIntervalSinceNow: waitSeconds))
p.done = true
p.task.cancel()
print("[probe] done")
