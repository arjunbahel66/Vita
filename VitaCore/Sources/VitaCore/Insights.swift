import Foundation

/// The three sections of the Insights card.
///
/// This shape is enforced at decode time by constrained generation rather than hoped
/// for in the prompt — format adherence is the main weakness of a 1.7B model, and it
/// was the one thing the original heading-splitting design relied on it to get right.
/// See CLAUDE.md section 4.5.
public struct Insights: Codable, Equatable, Sendable {
    /// Two or three sentences citing specific numbers from the fact sheet.
    public let summary: String

    /// Three low-risk everyday habits tied to those numbers.
    public let suggestions: [String]

    /// Exactly three questions to bring to a doctor.
    public let doctorQuestions: [String]

    public init(summary: String, suggestions: [String], doctorQuestions: [String]) {
        self.summary = summary
        self.suggestions = suggestions
        self.doctorQuestions = doctorQuestions
    }

    public static let expectedItemCount = 3

    /// Whether the model produced the counts the schema asked for.
    ///
    /// Constrained decoding should make this always true. It's checked anyway, because
    /// a silently short list is the kind of thing that would otherwise reach the user
    /// looking perfectly normal.
    public var hasExpectedShape: Bool {
        !summary.trimmed.isEmpty
            && suggestions.count == Self.expectedItemCount
            && doctorQuestions.count == Self.expectedItemCount
            && suggestions.allSatisfy { !$0.trimmed.isEmpty }
            && doctorQuestions.allSatisfy { !$0.trimmed.isEmpty }
    }

    /// JSON Schema handed to `MLXGuidedGeneration`, which constrains decoding so the
    /// model cannot emit a structurally invalid response.
    public static let jsonSchema = """
    {
      "type": "object",
      "properties": {
        "summary": {
          "type": "string",
          "description": "2-3 sentences about what stands out, citing specific numbers."
        },
        "suggestions": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 3,
          "maxItems": 3,
          "description": "Three low-risk everyday habits tied to the numbers."
        },
        "doctorQuestions": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 3,
          "maxItems": 3,
          "description": "Exactly three questions to ask a doctor."
        }
      },
      "required": ["summary", "suggestions", "doctorQuestions"],
      "additionalProperties": false
    }
    """
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
