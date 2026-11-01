import Foundation

/// Corrects names and terms the speech model misheard, using the person's own list:
/// "chat gbt" becomes "ChatGPT", "Charge B" becomes "ChargeBee". Each run of one to
/// four words is compared with every term by spelling (edit distance) and sound
/// (Soundex), and the closest term close enough replaces it.
struct CustomWords {
    let terms: [String]
    /// How different a run of words may be from a term, as a share of the longer one's
    /// letters (a matching sound counts for 30% of the spelling difference).
    static let threshold = 0.18
    private let keys: [(term: Int, key: String)]

    init(_ terms: [String]) {
        self.terms = terms
        var keys: [(Int, String)] = []
        for (index, term) in terms.enumerated() {
            let key = Self.matchKey(term)
            if Self.isMatchable(key) { keys.append((index, key)) }
            // "R&D" is also said "R and D".
            if term.contains("&") {
                let spoken = Self.matchKey(term.replacingOccurrences(of: "&", with: " and "))
                if Self.isMatchable(spoken), spoken != key { keys.append((index, spoken)) }
            }
        }
        self.keys = keys
    }

    var isEmpty: Bool { keys.isEmpty }

    /// The terms in what the person typed: one per line or separated by commas, trimmed,
    /// without blanks or repeats.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `text` with misheard terms replaced. Punctuation around a run is kept, a run never
    /// spans punctuation inside it, and the replacement follows the run's capitalisation.
    func correct(_ text: String) -> String {
        guard !keys.isEmpty else { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return text }
        var result: [String] = []
        var i = 0
        while i < words.count {
            var best: (length: Int, term: String, score: Double)?
            // Shortest first, so on a tie the run that takes fewer words wins and an
            // ordinary word after a term isn't swallowed ("CHARGE B is" keeps "is").
            for length in 1...Self.maxRun where i + length <= words.count {
                let run = words[i..<i + length]
                // Don't join across a comma or full stop: in "Charge B, che" the run ends at "B,".
                if run.dropLast().contains(where: { !Self.punctuation($0).suffix.isEmpty }) { continue }
                let candidate = run.map(Self.matchKey).joined()
                if let match = bestMatch(for: candidate), match.score < (best?.score ?? .infinity) {
                    best = (length, match.term, match.score)
                }
            }
            if let best {
                let first = words[i], last = words[i + best.length - 1]
                result.append(Self.punctuation(first).prefix + Self.casing(of: first, applied: best.term)
                              + Self.punctuation(last).suffix)
                i += best.length
            } else {
                result.append(words[i])
                i += 1
            }
        }
        return result.joined(separator: " ")
    }

    /// Up to four words, so a spelled-out acronym ("Chat G P T") is one run.
    private static let maxRun = 4

    private func bestMatch(for candidate: String) -> (term: String, score: Double)? {
        guard Self.isMatchable(candidate), candidate.count <= 50 else { return nil }
        var best: (term: String, score: Double)?
        for (index, key) in keys {
            // Lengths more than a quarter apart (at least 2 letters) never match, so a
            // three-word run can't swallow a much shorter term.
            let longer = max(candidate.count, key.count)
            guard Double(abs(candidate.count - key.count)) <= max(Double(longer) * 0.25, 2) else { continue }
            let spelling = Double(Self.editDistance(candidate, key)) / Double(longer)
            let soundsAlike = Self.isLetters(candidate) && Self.isLetters(key)
                && Self.soundex(candidate) == Self.soundex(key)
            let score = soundsAlike ? spelling * 0.3 : spelling
            if score < Self.threshold, score < (best?.score ?? .infinity) { best = (terms[index], score) }
        }
        return best
    }

    // MARK: Helpers

    /// Lowercased letters and digits only.
    static func matchKey(_ word: some StringProtocol) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Only ASCII terms are matched: the spelling and sound rules are made for them.
    private static func isMatchable(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isLetters(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// The punctuation before the first letter or digit of `word` and after its last.
    static func punctuation(_ word: String) -> (prefix: String, suffix: String) {
        guard let first = word.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = word.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return (word, "") }
        return (String(word[..<first]), String(word[word.index(after: last)...]))
    }

    /// `term` in capitals when `original` was, with a capital first letter when `original`
    /// had one (a sentence start) and the term is all lowercase, and otherwise as written in
    /// the list, so "iPhone" stays "iPhone".
    static func casing(of original: String, applied term: String) -> String {
        let letters = original.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return term.uppercased() }
        if let first = original.first(where: \.isLetter), first.isUppercase, term == term.lowercased(),
           let head = term.first {
            return head.uppercased() + term.dropFirst()
        }
        return term
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// American Soundex: the first letter and three digits for the consonant sounds after it.
    static func soundex(_ word: String) -> String {
        let letters = Array(word.uppercased().filter { $0.isASCII && $0.isLetter })
        guard let first = letters.first else { return "" }
        func code(_ c: Character) -> Character? {
            switch c {
            case "B", "F", "P", "V": "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
            case "D", "T": "3"
            case "L": "4"
            case "M", "N": "5"
            case "R": "6"
            default: nil
            }
        }
        var result = String(first)
        var last = code(first)
        for c in letters.dropFirst() {
            let digit = code(c)
            if let digit, digit != last { result.append(digit) }
            // H and W don't separate equal codes; vowels do.
            if c != "H", c != "W" { last = digit }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
