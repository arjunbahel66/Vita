import Testing
@testable import VitaCore

@Suite("Insight parsing")
struct InsightParserTests {
    let validJSON = """
    {
      "summary": "Your steps are down 21% this week.",
      "suggestions": ["Walk daily", "Sleep earlier", "Drink water"],
      "doctorQuestions": ["What explains my ALT?", "Should I retest?", "How soon?"]
    }
    """

    // MARK: - Thinking tags

    @Test func stripsThinkingBlock() {
        let output = "<think>Let me work through this.</think>Here is the answer."
        #expect(InsightParser.stripThinking(output) == "Here is the answer.")
    }

    @Test func stripsMultipleThinkingBlocks() {
        #expect(InsightParser.stripThinking("<think>one</think>A<think>two</think>B") == "AB")
    }

    /// Qwen3 emits an empty pair even with /no_think.
    @Test func stripsEmptyThinkingBlock() {
        #expect(InsightParser.stripThinking("<think></think>Answer") == "Answer")
    }

    @Test func stripsMultilineThinking() {
        let output = """
        <think>
        Step one.
        Step two.
        </think>
        Answer here.
        """
        #expect(InsightParser.stripThinking(output).trimmed == "Answer here.")
    }

    /// Generation cut off mid-reasoning: everything from the open tag is discarded
    /// rather than leaking chain-of-thought into the UI.
    @Test func unterminatedThinkingDiscardsRemainder() {
        #expect(InsightParser.stripThinking("Visible part.<think>never closed") == "Visible part.")
    }

    @Test func textWithoutThinkingIsUnchanged() {
        #expect(InsightParser.stripThinking("Plain answer.") == "Plain answer.")
    }

    @Test func thinkingTagIsCaseInsensitive() {
        #expect(InsightParser.stripThinking("<THINK>x</THINK>Answer") == "Answer")
    }

    // MARK: - Code fences

    @Test func stripsJSONCodeFence() {
        guard case let .parsed(insights) = InsightParser.parse("```json\n\(validJSON)\n```") else {
            Issue.record("Expected fenced JSON to parse")
            return
        }
        #expect(insights.suggestions.count == 3)
    }

    @Test func stripsBareCodeFence() {
        guard case .parsed = InsightParser.parse("```\n\(validJSON)\n```") else {
            Issue.record("Expected fenced JSON to parse")
            return
        }
    }

    // MARK: - Parsing

    @Test func parsesValidJSON() {
        guard case let .parsed(insights) = InsightParser.parse(validJSON) else {
            Issue.record("Expected valid JSON to parse")
            return
        }
        #expect(insights.summary == "Your steps are down 21% this week.")
        #expect(insights.suggestions == ["Walk daily", "Sleep earlier", "Drink water"])
        #expect(insights.doctorQuestions.count == 3)
    }

    @Test func parsesJSONWrappedInProse() {
        let output = "Here are your insights:\n\(validJSON)\nHope that helps!"
        guard case .parsed = InsightParser.parse(output) else {
            Issue.record("Expected to recover JSON from surrounding prose")
            return
        }
    }

    @Test func parsesJSONAfterThinkingBlock() {
        guard case .parsed = InsightParser.parse("<think>planning</think>\(validJSON)") else {
            Issue.record("Expected to parse JSON following a thinking block")
            return
        }
    }

    // MARK: - Brace counting

    /// A brace inside a string literal must not be mistaken for structure.
    @Test func bracesInsideStringsDoNotConfuseExtraction() {
        let json = """
        {"summary": "a { brace } in text", "suggestions": ["a","b","c"], "doctorQuestions": ["x","y","z"]}
        """
        guard case let .parsed(insights) = InsightParser.parse(json) else {
            Issue.record("Expected braces inside strings to be ignored")
            return
        }
        #expect(insights.summary == "a { brace } in text")
    }

    /// An escaped quote must not be read as closing the string, or the brace counter
    /// falls out of sync and the object is truncated.
    @Test func escapedQuotesDoNotTerminateStrings() {
        let json = """
        {"summary": "she said \\"hi\\" then left", "suggestions": ["a","b","c"], "doctorQuestions": ["x","y","z"]}
        """
        guard case let .parsed(insights) = InsightParser.parse(json) else {
            Issue.record("Expected escaped quotes to be handled")
            return
        }
        #expect(insights.summary == #"she said "hi" then left"#)
    }

    @Test func nestedObjectsExtractOutermost() {
        let json = """
        {"summary": "x", "suggestions": ["a","b","c"], "doctorQuestions": ["x","y","z"], "extra": {"nested": true}}
        """
        guard case .parsed = InsightParser.parse(json) else {
            Issue.record("Expected nested object to be handled")
            return
        }
    }

    // MARK: - Failure falls back to raw

    @Test func malformedJSONReturnsCleanedRawText() {
        guard case let .raw(text) = InsightParser.parse("<think>x</think>Sorry, I couldn't format that.") else {
            Issue.record("Expected unparseable output to come back as raw")
            return
        }
        // Thinking is still stripped on the failure path.
        #expect(text == "Sorry, I couldn't format that.")
        #expect(!text.contains("<think>"))
    }

    @Test func missingRequiredFieldFallsBackToRaw() {
        guard case .raw = InsightParser.parse(#"{"summary": "only this field"}"#) else {
            Issue.record("Expected missing fields to fall back to raw")
            return
        }
    }

    @Test func emptyOutputReturnsEmptyRaw() {
        guard case let .raw(text) = InsightParser.parse("") else {
            Issue.record("Expected empty output to come back as raw")
            return
        }
        #expect(text.isEmpty)
    }

    // MARK: - Shape validation

    @Test func expectedShapeAcceptsThreeAndThree() {
        let insights = Insights(
            summary: "A summary.",
            suggestions: ["a", "b", "c"],
            doctorQuestions: ["x", "y", "z"]
        )
        #expect(insights.hasExpectedShape)
    }

    @Test func expectedShapeRejectsWrongCounts() {
        let short = Insights(
            summary: "A summary.",
            suggestions: ["a", "b"],
            doctorQuestions: ["x", "y", "z"]
        )
        #expect(!short.hasExpectedShape)
    }

    @Test func expectedShapeRejectsBlankEntries() {
        let blank = Insights(
            summary: "A summary.",
            suggestions: ["a", "  ", "c"],
            doctorQuestions: ["x", "y", "z"]
        )
        #expect(!blank.hasExpectedShape)
    }

    @Test func expectedShapeRejectsEmptySummary() {
        let blank = Insights(
            summary: "   ",
            suggestions: ["a", "b", "c"],
            doctorQuestions: ["x", "y", "z"]
        )
        #expect(!blank.hasExpectedShape)
    }

    // MARK: - Clean (used for Ask answers, which are prose not JSON)

    @Test func cleanStripsThinkingAndTrims() {
        #expect(InsightParser.clean("  <think>reasoning</think>  The answer.  ") == "The answer.")
    }
}
