import Foundation

/// What Hushhh does once the first paste of a two-step insert has returned.
enum TwoStepFinish: Equatable {
    /// Paste this right after the first part.
    case pasteRest(String)
    /// Nothing is left to insert; put the person's clipboard back.
    case restoreClipboard
    /// Leave this on the clipboard for the person to paste, and keep theirs replaced.
    case copy(String)

    /// The app hasn't read an unread first paste, so a second paste could land before it:
    /// the whole dictation (or the first part alone, with nothing after it) goes on the
    /// clipboard instead, so a late read or the person's Cmd-V inserts all of it.
    static func decide(firstPaste: String, rest: String, firstWasRead: Bool) -> TwoStepFinish {
        let rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuation = rest.isEmpty ? "" : SpeechSegmenter.continuation(rest, after: firstPaste)
        guard firstWasRead else { return .copy(firstPaste + continuation) }
        return rest.isEmpty ? .restoreClipboard : .pasteRest(continuation)
    }
}
