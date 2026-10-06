import Foundation

/// The four labs Vita tracks. See CLAUDE.md section 4.2.
public enum LabKind: String, CaseIterable, Sendable, Codable {
    case alt
    case ast
    case triglycerides
    case a1c

    public var displayName: String {
        switch self {
        case .alt: "ALT"
        case .ast: "AST"
        case .triglycerides: "Triglycerides"
        case .a1c: "HbA1c"
        }
    }

    public var unit: String {
        switch self {
        case .alt, .ast: "U/L"
        case .triglycerides: "mg/dL"
        case .a1c: "%"
        }
    }

    /// Prefilled only. The user edits these to match the ranges printed on their own report,
    /// which is why classification always cites "the reference range on your report".
    public var defaultRange: ReferenceRange {
        switch self {
        case .alt: ReferenceRange(low: 7, high: 56)
        case .ast: ReferenceRange(low: 10, high: 40)
        case .triglycerides: ReferenceRange(low: nil, high: 150)
        case .a1c: ReferenceRange(low: nil, high: 5.7)
        }
    }

    /// Number of decimal places to show. HbA1c is reported to one; the rest are whole numbers.
    public var fractionDigits: Int {
        switch self {
        case .a1c: 1
        case .alt, .ast, .triglycerides: 0
        }
    }
}

/// A lab reference range. Either bound may be absent — triglycerides and HbA1c are
/// normally reported as an upper limit only.
public struct ReferenceRange: Equatable, Sendable, Codable {
    public var low: Double?
    public var high: Double?

    public init(low: Double?, high: Double?) {
        self.low = low
        self.high = high
    }

    public var isEmpty: Bool { low == nil && high == nil }

    /// Rendered the way a lab report writes it: "7-56", "<150", ">40".
    public func displayText(fractionDigits: Int = 0) -> String {
        func fmt(_ value: Double) -> String {
            String(format: "%.\(fractionDigits)f", value)
        }
        return switch (low, high) {
        case let (low?, high?): "\(fmt(low))-\(fmt(high))"
        case let (nil, high?): "<\(fmt(high))"
        case let (low?, nil): ">\(fmt(low))"
        case (nil, nil): "no range set"
        }
    }
}

/// Where a value sits relative to the user's own reported range.
///
/// Deliberately neutral. Hard rule 2 in CLAUDE.md forbids disease names, so this never
/// says "prediabetes" or "fatty liver" — only where the number falls.
public enum RangeClassification: String, Sendable, Equatable, Codable {
    case below
    case within
    case above
    case unknown

    /// The phrasing used in the fact sheet handed to the model.
    public var factSheetLabel: String {
        switch self {
        case .below: "BELOW range"
        case .within: "WITHIN range"
        case .above: "ABOVE range"
        case .unknown: "NO RANGE SET"
        }
    }

    /// The phrasing shown in the UI.
    public var neutralDescription: String {
        switch self {
        case .below: "below the reference range on your report"
        case .within: "within the reference range on your report"
        case .above: "above the reference range on your report"
        case .unknown: "no reference range set"
        }
    }
}

/// A single lab result the user typed in.
public struct LabValue: Equatable, Sendable, Codable, Identifiable {
    public var kind: LabKind
    public var value: Double
    public var range: ReferenceRange
    public var date: Date?

    /// Mirrors the "I've checked this matches my report" toggle. Only confirmed labs
    /// reach the fact sheet — see CLAUDE.md section 4.2.
    public var isConfirmed: Bool

    public var id: LabKind { kind }

    public init(
        kind: LabKind,
        value: Double,
        range: ReferenceRange? = nil,
        date: Date? = nil,
        isConfirmed: Bool = false
    ) {
        self.kind = kind
        self.value = value
        self.range = range ?? kind.defaultRange
        self.date = date
        self.isConfirmed = isConfirmed
    }

    /// Computed in Swift, never by the model. Hard rule 3.
    ///
    /// Bounds are inclusive: a value exactly equal to a limit counts as within range.
    public var classification: RangeClassification {
        if range.isEmpty { return .unknown }
        if let low = range.low, value < low { return .below }
        if let high = range.high, value > high { return .above }
        return .within
    }

    public var formattedValue: String {
        String(format: "%.\(kind.fractionDigits)f", value)
    }
}

public extension Collection<LabValue> {
    /// Only confirmed labs are shown to the model.
    var confirmed: [LabValue] {
        filter(\.isConfirmed)
    }

    /// AST/ALT ratio as a bare number, with no interpretation attached — CLAUDE.md
    /// section 4.2 is explicit that Vita must not read anything into it.
    ///
    /// Returns nil unless both labs are present and ALT is non-zero.
    var astAltRatio: Double? {
        guard let ast = first(where: { $0.kind == .ast })?.value,
              let alt = first(where: { $0.kind == .alt })?.value,
              alt != 0
        else { return nil }
        return ast / alt
    }
}
