import XCTest

final class CustomWordsTests: XCTestCase {
    private func correct(_ text: String, _ terms: [String]) -> String {
        CustomWords(terms).correct(text)
    }

    func testExactAndMisspelledWords() {
        XCTAssertEqual(correct("hello world", ["Hello", "World"]), "Hello World")
        XCTAssertEqual(correct("helo wrold", ["hello", "world"]), "hello world")
    }

    func testRunsOfWordsJoinIntoOneTerm() {
        XCTAssertEqual(correct("use Chat G P T for this", ["ChatGPT"]), "use ChatGPT for this")
        XCTAssertEqual(correct("using Mac Book Pro", ["MacBook Pro"]), "using MacBook Pro")
        XCTAssertEqual(correct("Open AI GPT model", ["OpenAI", "GPT"]), "OpenAI GPT model")
    }

    func testRunStopsAtPunctuationAndKeepsIt() {
        XCTAssertEqual(correct("il cui nome è Charge B, che permette", ["ChargeBee"]),
                       "il cui nome è ChargeBee, che permette")
    }

    func testCapitalisation() {
        XCTAssertEqual(correct("CHARGE B is great", ["ChargeBee"]), "CHARGEBEE is great")
        // A term with its own capitals keeps them at a sentence start.
        XCTAssertEqual(correct("Iphone is here.", ["iPhone"]), "iPhone is here.")
        // An all-lowercase term takes the sentence's capital.
        XCTAssertEqual(correct("Kubernetis runs it.", ["kubernetes"]), "Kubernetes runs it.")
    }

    func testAcronymsComeBackInCapitals() {
        XCTAssertEqual(correct("Talk to the fbi", ["FBI"]), "Talk to the FBI")
        XCTAssertEqual(correct("Nasa data", ["NASA"]), "NASA data")
    }

    func testAmpersandTerms() {
        XCTAssertEqual(correct("send it to RD for review", ["R&D"]), "send it to R&D for review")
        XCTAssertEqual(correct("send it to R and D for review", ["R&D"]), "send it to R&D for review")
    }

    func testOrdinaryWordsAreLeftAlone() {
        let text = "Let's review the last couple of runs and see what changed."
        XCTAssertEqual(correct(text, ["Cadence", "FoundersEdge", "Hushhh", "ChatGPT", "Kubernetes"]), text)
        XCTAssertEqual(correct("Nothing to do here.", []), "Nothing to do here.")
    }

    func testSoundex() {
        XCTAssertEqual(CustomWords.soundex("Robert"), "R163")
        XCTAssertEqual(CustomWords.soundex("Rupert"), "R163")
        XCTAssertEqual(CustomWords.soundex("Ashcraft"), "A261")
        XCTAssertEqual(CustomWords.soundex("Tymczak"), "T522")
        XCTAssertEqual(CustomWords.soundex("Pfister"), "P236")
    }

    func testParsesLinesAndCommas() {
        XCTAssertEqual(CustomWords.parse("FoundersEdge\n Kubernetes , R&D\n\nFoundersEdge,"),
                       ["FoundersEdge", "Kubernetes", "R&D"])
    }
}
