import Foundation

/// Builds the prompts handed to the model.
///
/// In VitaCore rather than the app because the system prompt carries the
/// no-diagnosis rules. It isn't the safety mechanism — `Guardrail` is, because a 1.7B
/// model cannot be relied on to follow instructions — but it is the first line, and a
/// first line that silently lost its rules would be worth catching.
public enum PromptBuilder {
    /// Shared by both tasks. Mirrors CLAUDE.md section 4.5.
    public static let systemPrompt = """
    You are Vita, a private wellness companion running on the user's own phone.
    You help the user understand their own health data in plain language.
    Rules:
    - Only use the facts provided. Never invent numbers. Quote the user's numbers exactly.
    - You do NOT diagnose, name diseases the user may have, or recommend medications, supplements, or doses.
    - Suggestions must be low-risk everyday habits (sleep, movement, food quality, hydration).
    - When something looks outside a reference range, say so neutrally and suggest asking a doctor.
    - Be brief, warm, and specific.
    """

    public static let insightsMaxTokens = 400
    public static let askMaxTokens = 250

    /// Longer questions are truncated rather than refused. The fact sheet is about 300
    /// tokens and the model has limited attention; a wall of text pushes the user's own
    /// data out of view.
    public static let maxQuestionCharacters = 400

    // MARK: - Insights

    /// Asks for JSON in the prompt, because constrained decoding is unavailable on the
    /// pinned MLX version (CLAUDE.md section 2.1a).
    ///
    /// The literal skeleton is deliberate. A 1.7B model follows a shape it can see far
    /// more reliably than one described in prose, and `InsightParser` has to recover
    /// whatever comes back regardless.
    public static func insightsTask(factSheet: String) -> String {
        """
        \(factSheet)

        Reply with ONLY a JSON object in exactly this shape, and nothing else:

        {
          "summary": "two or three sentences",
          "suggestions": ["first", "second", "third"],
          "doctorQuestions": ["first", "second", "third"]
        }

        summary: what stands out, quoting the numbers above exactly.
        suggestions: exactly 3 low-risk everyday habits tied to those numbers.
        doctorQuestions: exactly 3 questions to bring to a doctor.

        /no_think
        """
    }

    // MARK: - Ask

    /// Single turn, no chat memory. Each question sees the fact sheet and nothing else,
    /// so an earlier answer can't become a fact the model then builds on.
    public static func askTask(factSheet: String, question: String) -> String {
        """
        \(factSheet)

        User question: \(sanitize(question))

        Answer in under 120 words using only the facts above. If the question asks for a
        diagnosis, treatment, or medication advice, say you can't help with that and
        suggest a question to ask their doctor instead.

        /no_think
        """
    }

    /// Collapses whitespace and truncates. Not a security boundary — this is a
    /// single-user app and the user is the one typing — but a question containing
    /// newlines can imitate the surrounding prompt structure, and collapsing them is
    /// free.
    static func sanitize(_ question: String) -> String {
        let collapsed = question
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > maxQuestionCharacters else { return collapsed }
        return String(collapsed.prefix(maxQuestionCharacters)) + "…"
    }
}
