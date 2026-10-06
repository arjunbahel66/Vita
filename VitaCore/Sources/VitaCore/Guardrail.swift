import Foundation

/// Deterministic safety filter applied to the model's **final** output.
///
/// This — not the prompt — is the actual safety mechanism. A 1.7B model cannot be
/// relied on to hold a boundary, so the boundary is enforced here where it can be
/// unit-tested. See CLAUDE.md section 4.7.
///
/// Runs after streaming completes, because a rule like "no dosages" can't be judged
/// from a half-written sentence.
public enum Guardrail {
    public static let fallbackMessage =
        "Vita couldn't give a safe answer to that. Try asking it as a question to bring to your doctor."

    public struct Violation: Equatable, Sendable {
        /// Which rule tripped. For tests and debugging — never shown to the user,
        /// since naming the trigger would leak the thing we just suppressed.
        public let rule: String
        public let matchedText: String
    }

    /// A named rule. Patterns are held as strings rather than compiled regexes so the
    /// type stays trivially Sendable; compiling five patterns costs nothing next to
    /// model inference, and this runs once per generation.
    struct Rule {
        let name: String
        let pattern: String
    }

    /// Proximity bound used instead of a bare `.*`, which would match across an entire
    /// response and flag "you have" in one paragraph against "diabetes" three paragraphs
    /// later. `[^.!?\n]` keeps each rule inside a single sentence.
    private static let withinSentence = "[^.!?\\n]{0,100}"

    static let rules: [Rule] = [
        // Attributing a condition to the user. Hard rule 2.
        Rule(
            name: "condition-attribution",
            pattern: "\\byou(?:'ve| have| has)\\b\(withinSentence)"
                + "\\b(nafld|nash|masld|mash|cirrhosis|diabetes|fibrosis|fatty liver|prediabetes)\\b"
        ),

        // Any form of diagnosing.
        //
        // Deliberately broad: this also catches the model's own refusals ("I can't
        // diagnose that"), which get replaced by `fallbackMessage`. That swap is
        // acceptable — both are safe refusals — and the alternative is a narrower
        // pattern that lets real diagnostic language through.
        Rule(name: "diagnosis", pattern: "\\bdiagnos"),

        // Dosages.
        //
        // The trailing `(?!/)` keeps concentration units out of this: "140 mg/dL" is a
        // lab result the fact sheet itself contains and the model is told to quote
        // exactly, whereas "400 mg" is a dose. Without the lookahead this rule fires on
        // almost every well-behaved response.
        //
        // Bare `g` and `ml` are deliberately absent. They read as food and drink far
        // more often than as doses, and "500 ml of water" is precisely the kind of
        // low-risk hydration suggestion the prompt asks for.
        Rule(name: "dosage", pattern: "\\b\\d+\\s?(mg|mcg|ug|iu)\\b(?!/)"),

        // Starting, stopping or taking a named drug or supplement.
        Rule(
            name: "medication-instruction",
            pattern: "\\b(take|taking|start|starting|stop|stopping|increase|decrease)\\b\(withinSentence)"
                + "\\b(metformin|statin|statins|vitamin\\s*e|pioglitazone|resmetirom"
                + "|semaglutide|ozempic|wegovy|mounjaro|supplement|supplements|medication|medications)\\b"
        ),

        // Prescribing.
        Rule(name: "prescription", pattern: "\\bprescri"),
    ]

    /// The first rule the text trips, or nil if it's clean.
    public static func firstViolation(in text: String) -> Violation? {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)

        for rule in rules {
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern,
                options: [.caseInsensitive]
            ) else { continue }

            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let matchRange = Range(match.range, in: text)
            else { continue }

            return Violation(rule: rule.name, matchedText: String(text[matchRange]))
        }

        return nil
    }

    public static func isSafe(_ text: String) -> Bool {
        firstViolation(in: text) == nil
    }

    /// Returns the text unchanged, or `fallbackMessage` if any rule trips.
    public static func filter(_ text: String) -> String {
        isSafe(text) ? text : fallbackMessage
    }

    /// Applies the filter across an `Insights` value, checking every field.
    ///
    /// Returns nil if any section is unsafe. The whole card is dropped rather than
    /// partially shown: a summary that survives while its suggestions were suppressed
    /// would read as complete and wouldn't be.
    public static func filter(_ insights: Insights) -> Insights? {
        let allText = ([insights.summary] + insights.suggestions + insights.doctorQuestions)
            .joined(separator: "\n")
        return isSafe(allText) ? insights : nil
    }
}
