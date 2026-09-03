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
    private var _confirmedText = ""

    /// Characters of confirmed transcript text typed so far.
    public var typedConfirmedCount: Int { _typedConfirmedCount }
    /// The interim hypothesis currently sitting at the cursor.
    public var typedInterim: String { _typedInterim }

    public init() {}

    /// Apply a provider revision and return the operations needed to make the
    /// cursor output match it.
    public func apply(_ revision: TranscriptRevision) -> [TranscriptOutputOp] {
        var ops: [TranscriptOutputOp] = []

        if let suffix = revision.appendSafeSuffix {
            // Append-only provider: everything received is safe to type in
            // order. Any typed interim must go first so the suffix lands
            // directly after the confirmed text.
            guard !suffix.isEmpty else { return [] }
            if !_typedInterim.isEmpty {
                ops.append(.erase(count: _typedInterim.count))
                _typedInterim = ""
            }
            _confirmedText += suffix
            _typedConfirmedCount += suffix.count
            ops.append(.type(suffix))
            return ops
        }

        var opsPrepared: [TranscriptOutputOp] = []
        if !_typedInterim.isEmpty {
            opsPrepared.append(.erase(count: _typedInterim.count))
            _typedInterim = ""
        }
        let confirmed = revision.confirmedText
        // Align the typed confirmed text with the provider's view. Only the
        // characters that still match may be kept; a snapshot that differs
        // mid-stream (e.g. a cumulative chunk that replaces earlier text) is
        // corrected by erasing back to the shared prefix and retyping.
        let keep = min(_typedConfirmedCount, commonPrefixCount(_confirmedText, confirmed))
        if keep < _typedConfirmedCount {
            opsPrepared.append(.erase(count: _typedConfirmedCount - keep))
        }
        if confirmed.count > keep {
            let start = confirmed.index(confirmed.startIndex, offsetBy: keep)
            let suffix = String(confirmed[start...])
            opsPrepared.append(.type(suffix))
        }
        _typedConfirmedCount = confirmed.count
        if !revision.interimText.isEmpty {
            opsPrepared.append(.type(revision.interimText))
            _typedInterim = revision.interimText
        }
        _confirmedText = confirmed
        ops = opsPrepared
        return ops
    }

    /// Apply the session's final transcript: drop any typed interim and type
    /// whatever part of the final text has not been typed yet.
    public func applyFinal(_ text: String) -> [TranscriptOutputOp] {
        var ops: [TranscriptOutputOp] = []
        if !_typedInterim.isEmpty {
            ops.append(.erase(count: _typedInterim.count))
            _typedInterim = ""
        }
        // Same prefix-diff alignment as revisions: keep only the typed
        // characters that survive in the final text.
        let keep = min(_typedConfirmedCount, commonPrefixCount(_confirmedText, text))
        if keep < _typedConfirmedCount {
            ops.append(.erase(count: _typedConfirmedCount - keep))
        }
        if text.count > keep {
            let start = text.index(text.startIndex, offsetBy: keep)
            let suffix = String(text[start...])
            ops.append(.type(suffix))
        }
        _typedConfirmedCount = text.count
        _confirmedText = text
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
        _confirmedText = ""
    }
}
