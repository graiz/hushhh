import Foundation

/// Decides which words of a changing live transcript are settled enough to
/// type into the document. A word is committed once it (and every word before
/// it) has stayed the same for `delay` seconds; the rest stays as ghost text.
///
/// Committed words can't be changed, so later hypotheses are aligned to them
/// by word position.
struct CommitTracker {
    let delay: TimeInterval

    private(set) var committedCount = 0
    private var words: [String] = []
    private var stableSince: [Date] = []

    init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Feeds a new hypothesis. Returns words that became committed, and the
    /// words still pending after everything committed so far.
    mutating func update(_ hypothesis: String, now: Date = Date()) -> (newlyCommitted: [String], pending: [String]) {
        let next = Self.words(hypothesis)
        var since: [Date] = []
        since.reserveCapacity(next.count)
        var prefixIntact = true
        for (i, word) in next.enumerated() {
            if i < committedCount {
                // Already typed; keep its time so later words aren't reset by a revision here.
                since.append(i < stableSince.count ? stableSince[i] : now)
            } else if prefixIntact, i < words.count, words[i] == word {
                since.append(stableSince[i])
            } else {
                prefixIntact = false
                since.append(now)
            }
        }
        words = next
        stableSince = since

        var newlyCommitted: [String] = []
        var i = committedCount
        while i < words.count {
            // The last word may still be mid-utterance, so it needs extra time.
            let required = i == words.count - 1 ? delay + 1 : delay
            guard now.timeIntervalSince(stableSince[i]) >= required else { break }
            newlyCommitted.append(words[i])
            i += 1
        }
        committedCount = i
        return (newlyCommitted, pending)
    }

    /// Words of the latest hypothesis that haven't been committed.
    var pending: [String] {
        committedCount < words.count ? Array(words[committedCount...]) : []
    }

    /// The part of a final transcript that hasn't been typed yet.
    func remainder(of final: String) -> [String] {
        let all = Self.words(final)
        return committedCount < all.count ? Array(all[committedCount...]) : []
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
