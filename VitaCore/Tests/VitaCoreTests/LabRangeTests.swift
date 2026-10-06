import Testing
@testable import VitaCore

@Suite("Lab range classification")
struct LabRangeTests {
    // MARK: - Classification

    @Test func valueAboveRangeIsAbove() {
        #expect(LabValue(kind: .alt, value: 62).classification == .above)
    }

    @Test func valueBelowRangeIsBelow() {
        #expect(LabValue(kind: .alt, value: 3).classification == .below)
    }

    @Test func valueInsideRangeIsWithin() {
        #expect(LabValue(kind: .alt, value: 30).classification == .within)
    }

    /// Bounds are inclusive. A value printed as exactly the limit on a report is not
    /// flagged — reports treat the limit itself as acceptable.
    @Test func valueExactlyAtUpperBoundIsWithin() {
        #expect(LabValue(kind: .alt, value: 56).classification == .within)
    }

    @Test func valueExactlyAtLowerBoundIsWithin() {
        #expect(LabValue(kind: .alt, value: 7).classification == .within)
    }

    @Test func justOverUpperBoundIsAbove() {
        #expect(LabValue(kind: .alt, value: 56.1).classification == .above)
    }

    /// Triglycerides and HbA1c are reported as an upper limit only, so there is no
    /// "below range" for them.
    @Test func upperOnlyRangeNeverClassifiesBelow() {
        #expect(LabValue(kind: .triglycerides, value: 10).classification == .within)
        #expect(LabValue(kind: .triglycerides, value: 140).classification == .within)
        #expect(LabValue(kind: .triglycerides, value: 151).classification == .above)
    }

    @Test func a1cUsesUpperOnlyRange() {
        #expect(LabValue(kind: .a1c, value: 5.6).classification == .within)
        #expect(LabValue(kind: .a1c, value: 5.7).classification == .within)
        #expect(LabValue(kind: .a1c, value: 5.8).classification == .above)
    }

    @Test func emptyRangeIsUnknown() {
        let lab = LabValue(kind: .alt, value: 62, range: ReferenceRange(low: nil, high: nil))
        #expect(lab.classification == .unknown)
    }

    /// The user edits ranges to match their own report, and classification must follow
    /// their numbers rather than our defaults.
    @Test func userEditedRangeOverridesDefault() {
        let lab = LabValue(kind: .alt, value: 62, range: ReferenceRange(low: 7, high: 70))
        #expect(lab.classification == .within)
    }

    // MARK: - Defaults

    @Test func defaultRangesMatchSpec() {
        #expect(LabKind.alt.defaultRange == ReferenceRange(low: 7, high: 56))
        #expect(LabKind.ast.defaultRange == ReferenceRange(low: 10, high: 40))
        #expect(LabKind.triglycerides.defaultRange == ReferenceRange(low: nil, high: 150))
        #expect(LabKind.a1c.defaultRange == ReferenceRange(low: nil, high: 5.7))
    }

    @Test func unitsMatchSpec() {
        #expect(LabKind.alt.unit == "U/L")
        #expect(LabKind.ast.unit == "U/L")
        #expect(LabKind.triglycerides.unit == "mg/dL")
        #expect(LabKind.a1c.unit == "%")
    }

    // MARK: - Range display

    @Test func rangeDisplayText() {
        #expect(ReferenceRange(low: 7, high: 56).displayText() == "7-56")
        #expect(ReferenceRange(low: nil, high: 150).displayText() == "<150")
        #expect(ReferenceRange(low: 40, high: nil).displayText() == ">40")
        #expect(ReferenceRange(low: nil, high: nil).displayText() == "no range set")
    }

    @Test func a1cRangeDisplaysOneDecimal() {
        #expect(LabKind.a1c.defaultRange.displayText(fractionDigits: 1) == "<5.7")
    }

    // MARK: - Confirmation gate

    @Test func onlyConfirmedLabsSurviveFiltering() {
        let labs = [
            LabValue(kind: .alt, value: 62, isConfirmed: true),
            LabValue(kind: .ast, value: 38, isConfirmed: false),
        ]
        #expect(labs.confirmed.map(\.kind) == [.alt])
    }

    @Test func unconfirmedLabsAreAllExcluded() {
        let labs = [
            LabValue(kind: .alt, value: 62),
            LabValue(kind: .ast, value: 38),
        ]
        #expect(labs.confirmed.isEmpty)
    }

    // MARK: - AST/ALT ratio

    @Test func astAltRatioComputedWhenBothPresent() throws {
        let labs = [
            LabValue(kind: .alt, value: 60, isConfirmed: true),
            LabValue(kind: .ast, value: 39, isConfirmed: true),
        ]
        let ratio = try #require(labs.astAltRatio)
        #expect(isClose(ratio, 0.65))
    }

    @Test func astAltRatioNilWhenOneMissing() {
        #expect([LabValue(kind: .alt, value: 60, isConfirmed: true)].astAltRatio == nil)
    }

    @Test func astAltRatioNilWhenAltIsZero() {
        let labs = [
            LabValue(kind: .alt, value: 0, isConfirmed: true),
            LabValue(kind: .ast, value: 39, isConfirmed: true),
        ]
        #expect(labs.astAltRatio == nil)
    }

    // MARK: - Formatting

    @Test func a1cFormatsToOneDecimalAndOthersToWhole() {
        #expect(LabValue(kind: .a1c, value: 5.74).formattedValue == "5.7")
        #expect(LabValue(kind: .alt, value: 62.4).formattedValue == "62")
    }
}
