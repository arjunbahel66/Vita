import Foundation
import Testing
@testable import VitaCore

@Suite("Lab entry")
struct LabEntryTests {
    // MARK: - Defaults

    @Test func freshEntryIsPrefilledWithThePrintedRange() {
        let alt = LabEntry(kind: .alt)
        #expect(alt.valueText.isEmpty)
        #expect(alt.lowText == "7")
        #expect(alt.highText == "56")
        #expect(!alt.isConfirmed)
    }

    /// Triglycerides and HbA1c are reported as an upper bound only, so the low field
    /// starts empty rather than at zero.
    @Test func upperOnlyLabsHaveNoLowBound() {
        #expect(LabEntry(kind: .triglycerides).lowText.isEmpty)
        #expect(LabEntry(kind: .triglycerides).highText == "150")
        #expect(LabEntry(kind: .a1c).lowText.isEmpty)
        #expect(LabEntry(kind: .a1c).highText == "5.7")
    }

    // MARK: - Parsing

    @Test func parsesOrdinaryInput() {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "62"
        #expect(entry.value == 62)
    }

    @Test func toleratesWhitespaceAroundAPastedValue() {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "  62 "
        #expect(entry.value == 62)
    }

    /// Mid-edit states must not parse into something plausible.
    @Test func halfTypedInputDoesNotParse() {
        for text in ["", " ", "-", ".", "abc", "12abc", "1.2.3"] {
            var entry = LabEntry(kind: .alt)
            entry.valueText = text
            #expect(entry.value == nil, "\"\(text)\" should not parse")
        }
    }

    @Test func trailingDecimalPointParsesAsTheWholeNumber() {
        var entry = LabEntry(kind: .a1c)
        entry.valueText = "5."
        #expect(entry.value == 5)
    }

    // MARK: - The confirm gate
    //
    // The toggle is the only thing standing between a typed value and the model.

    @Test func anEmptyRowCannotBeConfirmed() {
        #expect(!LabEntry(kind: .alt).canConfirm)
    }

    @Test func aParseableRowCanBeConfirmed() {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "62"
        #expect(entry.canConfirm)
    }

    @Test func unparseableTextCannotBeConfirmed() {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "sixty-two"
        #expect(!entry.canConfirm)
    }

    // MARK: - Conversion to the domain type

    @Test func becomesALabValueOnceItParses() throws {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "62"
        let lab = try #require(entry.labValue)

        #expect(lab.kind == .alt)
        #expect(lab.value == 62)
        #expect(lab.classification == .above)
    }

    @Test func isNilUntilItParses() {
        #expect(LabEntry(kind: .alt).labValue == nil)
    }

    /// Classification follows the range the user typed, not the default — the whole
    /// point of making the bounds editable.
    @Test func usesTheEditedRangeNotTheDefault() throws {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "62"
        entry.highText = "70"

        let lab = try #require(entry.labValue)
        #expect(lab.classification == .within)
    }

    /// Deleting a bound means the report doesn't print one, so the range opens up
    /// rather than quietly reverting to our default.
    @Test func clearingABoundOpensTheRange() throws {
        var entry = LabEntry(kind: .alt)
        entry.valueText = "200"
        entry.highText = ""

        let lab = try #require(entry.labValue)
        #expect(lab.range.high == nil)
        #expect(lab.classification == .within)
    }

    // MARK: - What reaches the fact sheet

    @Test func onlyConfirmedEntriesBecomeLabValues() {
        var alt = LabEntry(kind: .alt); alt.valueText = "62"; alt.isConfirmed = true
        var ast = LabEntry(kind: .ast); ast.valueText = "38"; ast.isConfirmed = false

        let labs = [alt, ast].confirmedLabValues(date: nil)
        #expect(labs.map(\.kind) == [.alt])
    }

    @Test func unparseableEntriesAreDroppedEvenIfFlaggedConfirmed() {
        // Shouldn't be reachable through the UI, but a decode of older saved data could
        // produce it, and it must not reach the model.
        var broken = LabEntry(kind: .alt)
        broken.valueText = ""
        broken.isConfirmed = true

        #expect([broken].confirmedLabValues(date: nil).isEmpty)
    }

    @Test func stampsTheDrawDateOnEveryConfirmedValue() throws {
        let drawn = Date(timeIntervalSince1970: 1_760_000_000)
        var alt = LabEntry(kind: .alt); alt.valueText = "62"; alt.isConfirmed = true

        let lab = try #require([alt].confirmedLabValues(date: drawn).first)
        #expect(lab.date == drawn)
    }

    @Test func leavesTheDateOffWhenNoneWasSet() throws {
        var alt = LabEntry(kind: .alt); alt.valueText = "62"; alt.isConfirmed = true
        let lab = try #require([alt].confirmedLabValues(date: nil).first)
        #expect(lab.date == nil)
    }

    @Test func noConfirmedEntriesYieldsNothing() {
        let entries = LabKind.allCases.map(LabEntry.init)
        #expect(entries.confirmedLabValues(date: nil).isEmpty)
    }

    // MARK: - Round trip

    @Test func survivesEncodingAndDecoding() throws {
        var entry = LabEntry(kind: .a1c)
        entry.valueText = "5.4"
        entry.highText = "5.6"
        entry.isConfirmed = true

        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([LabEntry].self, from: data)
        #expect(decoded == [entry])
    }
}
