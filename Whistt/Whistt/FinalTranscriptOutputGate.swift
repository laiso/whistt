import Foundation

/// Converts provider events into Whistt's final-only output contract.
public struct FinalTranscriptOutputGate {
    private var lastDeliveredTranscript: String?

    public init() {}

    public mutating func reset() {
        lastDeliveredTranscript = nil
    }

    public mutating func consume(_ event: TranscriptionTransportEvent) -> String? {
        guard case .final(let transcript) = event else { return nil }
        guard transcript != lastDeliveredTranscript else { return nil }
        lastDeliveredTranscript = transcript
        return transcript
    }
}
