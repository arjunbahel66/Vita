import Foundation

/// One lab row as the user is editing it.
///
/// Values are held as text rather than numbers because a field being edited is often
/// not a valid number yet — empty, `"5."`, `"-"`, `"12.3.4"`. `LabValue` is the
/// validated type, and an entry becomes one only once it parses, which keeps
/// half-finished input out of the domain model entirely.
///
/// This lives in VitaCore rather than the app because `canConfirm` is a safety gate:
/// it decides what reaches the model, and gates belong where they can be tested.
public struct LabEntry: Codable, Equatable, Identifiable, Sendable {
    public var kind: LabKind
    public var valueText: String
    public var lowText: String
    public var highText: String
    public var isConfirmed: Bool

    public var id: LabKind { kind }

    /// A fresh row, prefilled with the printed defaults for its lab.
    public init(kind: LabKind) {
        self.kind = kind
        valueText = ""
        lowText = kind.defaultRange.low.map { Self.format($0, kind) } ?? ""
        highText = kind.defaultRange.high.map { Self.format($0, kind) } ?? ""
        isConfirmed = false
    }

    public init(
        kind: LabKind,
        valueText: String,
        lowText: String,
        highText: String,
        isConfirmed: Bool = false
    ) {
        self.kind = kind
        self.valueText = valueText
        self.lowText = lowText
        self.highText = highText
        self.isConfirmed = isConfirmed
    }

    private static func format(_ value: Double, _ kind: LabKind) -> String {
        String(format: "%.\(kind.fractionDigits)f", value)
    }

    public var value: Double? { Self.number(valueText) }

    /// A row with nothing in it cannot be confirmed. Confirming an empty value would
    /// put a meaningless entry in front of the model.
    public var canConfirm: Bool { value != nil }

    /// Nil until the value parses. A cleared bound becomes an open-ended range rather
    /// than silently reverting to the default, since a user who deletes a bound means
    /// their report doesn't print one.
    public var labValue: LabValue? {
        guard let value else { return nil }
        return LabValue(
            kind: kind,
            value: value,
            range: ReferenceRange(low: Self.number(lowText), high: Self.number(highText)),
            date: nil,
            isConfirmed: isConfirmed
        )
    }

    /// Strict on purpose. `Double("12abc")` is nil, which is what we want, but
    /// whitespace around a pasted value is ordinary and shouldn't be rejected.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}

public extension Collection<LabEntry> {
    /// What reaches the fact sheet: parsed, confirmed, and stamped with the draw date.
    func confirmedLabValues(date: Date?) -> [LabValue] {
        compactMap { entry in
            guard var lab = entry.labValue, lab.isConfirmed else { return nil }
            lab.date = date
            return lab
        }
    }
}
