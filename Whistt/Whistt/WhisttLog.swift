import Foundation

/// Console-friendly logger.
/// Lifecycle events go to NSLog (timestamped).
/// Transcript deltas accumulate on a single buffered line; a final transcript
/// flushes the buffered line and prints the canonical version.
enum WhisttLog {
    private static let queue = DispatchQueue(label: "whistt.log")
    private static var inflight = ""
    private static let verbose = ProcessInfo.processInfo.environment["WHISTT_VERBOSE"] != nil
    private static let deltaPrefix = Data("[Whistt] tx: ".utf8)
    private static let newline = Data("\n".utf8)

    /// Lifecycle event (session.*, speech_started, committed, etc.).
    static func event(_ msg: String) {
        queue.async {
            flushDeltaLine()
            NSLog("[Whistt] %@", msg)
        }
    }

    /// Debug-level event — only logged if WHISTT_VERBOSE env var is set.
    static func debugEvent(_ type: String) {
        guard verbose else { return }
        queue.async {
            flushDeltaLine()
            NSLog("[Whistt] · %@", type)
        }
    }

    /// Streaming transcript chunk. Accumulates without newlines.
    static func delta(_ text: String) {
        queue.async {
            if inflight.isEmpty {
                writeStdout(deltaPrefix)
            }
            inflight += text
            writeStdout(Data(text.utf8))
        }
    }

    /// Final committed transcript. Flushes inflight buffer then prints canonical line.
    static func final(_ text: String) {
        queue.async {
            flushDeltaLine()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                NSLog("[Whistt] = %@", trimmed)
            }
        }
    }

    static func error(_ msg: String) {
        queue.async {
            flushDeltaLine()
            NSLog("[Whistt] ⚠ %@", msg)
        }
    }

    private static func flushDeltaLine() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !inflight.isEmpty else { return }
        writeStdout(newline)
        inflight = ""
    }

    private static func writeStdout(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }
}
