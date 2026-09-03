import Foundation

/// Provider-neutral description of one transcript revision.
///
/// - `confirmedText`: transcript text the provider has locked in. Across
///   successive revisions this text only ever grows (append-only).
/// - `interimText`: the provider's current hypothesis for the unfinished part,
///   as a full replacement snapshot — it may revise text it previously sent.
/// - `appendSafeSuffix`: when the provider guarantees its interim delivery is
///   append-only, the suffix that may be typed at the cursor immediately.
///   Absent when the interim is a revisable snapshot.
public struct TranscriptRevision: Equatable {
    public var confirmedText: String
    public var interimText: String
    public var appendSafeSuffix: String?

    public init(confirmedText: String, interimText: String, appendSafeSuffix: String? = nil) {
        self.confirmedText = confirmedText
        self.interimText = interimText
        self.appendSafeSuffix = appendSafeSuffix
    }
}

/// Output operations a cursor-facing consumer must perform, in order, to make
/// the typed text match a transcript state. Output layers never see provider
/// protocol details — only these operations.
public enum TranscriptOutputOp: Equatable {
    /// Delete `count` characters before the cursor (backspace semantics).
    case erase(count: Int)
    /// Append text at the cursor.
    case type(String)
}

/// Applies transcript revisions and computes the cursor output operations that
/// keep typed text consistent with revisable interim hypotheses.
///
/// The buffer tracks what has already been typed (confirmed text plus the
/// current interim), so each revision translates into the minimal
/// erase/type sequence. Protocol details stay in the transports; duplicates of
/// confirmed text are never typed twice.
public final class TranscriptRevisionBuffer {
    private var _typedConfirmedCount = 0
    private var _typedInterim: String = ""
    private var _typedText = ""

    /// Characters of confirmed transcript text typed so far.
    public var typedConfirmedCount: Int { _typedConfirmedCount }
    /// The interim hypothesis currently sitting at the cursor.
    public var typedInterim: String { _typedInterim }

    public init() {}

    /// Apply a provider revision and return the operations needed to make the
    /// cursor output match it.
    public func apply(_ revision: TranscriptRevision) -> [TranscriptOutputOp] {
        let desiredText = revision.confirmedText + revision.interimText
        let ops = reconcileTypedText(with: desiredText)
        _typedConfirmedCount = revision.confirmedText.count
        _typedInterim = revision.interimText
        return ops
    }

    /// Apply the session's final transcript: drop any typed interim and type
    /// whatever part of the final text has not been typed yet.
    public func applyFinal(_ text: String) -> [TranscriptOutputOp] {
        let ops = reconcileTypedText(with: text)
        _typedConfirmedCount = text.count
        _typedInterim = ""
        return ops
    }

    /// Keep the common visible prefix and replace only the changed tail. This
    /// avoids a full erase/retype flash when an interim becomes final.
    private func reconcileTypedText(with desiredText: String) -> [TranscriptOutputOp] {
        let keep = commonPrefixCount(_typedText, desiredText)
        var ops: [TranscriptOutputOp] = []
        if keep < _typedText.count {
            ops.append(.erase(count: _typedText.count - keep))
        }
        if keep < desiredText.count {
            let start = desiredText.index(desiredText.startIndex, offsetBy: keep)
            ops.append(.type(String(desiredText[start...])))
        }
        _typedText = desiredText
        return ops
    }

    private func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }

    /// Drop tracking state (e.g. the typed output was discarded and must not
    /// be corrected later).
    public func reset() {
        _typedConfirmedCount = 0
        _typedInterim = ""
        _typedText = ""
    }
}
