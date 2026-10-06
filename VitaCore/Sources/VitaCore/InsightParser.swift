import Foundation

/// Turns raw model output into `Insights`.
///
/// Per CLAUDE.md section 4.6, a parse failure shows the raw text in one block rather
/// than an error: a response that didn't fit the schema is still worth reading, and
/// an error message would discard work the model actually did.
public enum InsightParser {
    public enum Result: Equatable, Sendable {
        case parsed(Insights)
        /// Decoding failed. Carries the cleaned text — thinking and fences already removed.
        case raw(String)
    }

    public static func parse(_ rawOutput: String) -> Result {
        let cleaned = clean(rawOutput)

        guard let json = extractJSONObject(from: cleaned),
              let data = json.data(using: .utf8),
              let insights = try? JSONDecoder().decode(Insights.self, from: data)
        else {
            return .raw(cleaned)
        }

        return .parsed(insights)
    }

    /// Strips reasoning traces and markdown fences. Used on Ask answers too, which are
    /// prose rather than JSON.
    public static func clean(_ rawOutput: String) -> String {
        stripCodeFences(stripThinking(rawOutput)).trimmed
    }

    // MARK: - Thinking

    /// Removes `<think>…</think>`.
    ///
    /// Qwen3 is a hybrid thinking model. `/no_think` in the user message should suppress
    /// this, but the tag still appears often enough — and an empty `<think></think>` pair
    /// almost always does — that stripping is not optional.
    ///
    /// An unterminated `<think>` means generation was cut off mid-reasoning, so everything
    /// from the tag onward is discarded.
    public static func stripThinking(_ text: String) -> String {
        var result = text

        while let open = result.range(of: "<think>", options: .caseInsensitive) {
            if let close = result.range(
                of: "</think>",
                options: .caseInsensitive,
                range: open.upperBound ..< result.endIndex
            ) {
                result.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound ..< result.endIndex)
                break
            }
        }

        return result
    }

    // MARK: - Fences

    /// Removes a wrapping ```json … ``` fence. Models add these unprompted, and the
    /// backticks make the payload invalid JSON.
    static func stripCodeFences(_ text: String) -> String {
        let trimmed = text.trimmed
        guard trimmed.hasPrefix("```") else { return text }

        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()
        if let last = lines.last, last.trimmed.hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON extraction

    /// Pulls the outermost `{…}` out of surrounding prose.
    ///
    /// Constrained generation should return bare JSON, but a model that slips a
    /// "Here you go:" in front shouldn't cost the user their insights.
    ///
    /// Brace counting ignores braces inside string literals, and honours backslash
    /// escapes so a `"\\"` at the end of a string doesn't swallow the closing quote.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var insideString = false
        var escaped = false

        for index in text[start...].indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }

            if character == "\\", insideString {
                escaped = true
                continue
            }

            if character == "\"" {
                insideString.toggle()
                continue
            }

            guard !insideString else { continue }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start ... index])
                }
            }
        }

        return nil
    }
}
