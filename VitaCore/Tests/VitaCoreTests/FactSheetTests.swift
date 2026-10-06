import Foundation
import Testing
@testable import VitaCore

@Suite("Fact sheet")
struct FactSheetTests {
    let utc = TimeZone(identifier: "UTC")!

    func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    /// Builds a series with explicit statistics, bypassing the computing initialiser so
    /// these tests exercise formatting rather than arithmetic. The arithmetic is covered
    /// by `MetricSeriesTests`.
    func series(
        days: Int,
        average: Double?,
        recent: Double? = nil,
        trend: MetricTrend = .insufficientData,
        latest: Double? = nil,
        first: Double? = nil
    ) -> MetricSeries {
        let start = date("2026-09-06")
        let daily = (0 ..< max(days, 0)).map { index -> DailyValue in
            let value = if index == 0, let first {
                first
            } else if index == days - 1, let latest {
                latest
            } else {
                average ?? 0
            }
            return DailyValue(
                date: start.addingTimeInterval(Double(index) * 86400),
                value: value
            )
        }
        return MetricSeries(
            daily: daily,
            average: average,
            recentAverage: recent,
            priorAverage: nil,
            trend: trend
        )
    }

    var fullSnapshot: HealthSnapshot {
        HealthSnapshot(
            windowDays: 30,
            exportDate: date("2026-10-05"),
            steps: series(days: 30, average: 6240, recent: 5100, trend: .down(percent: 21)),
            sleepHours: series(days: 26, average: 6.583),
            restingHeartRate: series(days: 30, average: 62, recent: 62, trend: .stable),
            weightKilograms: series(days: 30, average: 81.4, latest: 81.4, first: 82.2)
        )
    }

    // MARK: - The worked example from CLAUDE.md section 4.3

    @Test func reproducesSpecExample() {
        let labs = [
            LabValue(kind: .alt, value: 62, date: date("2026-09-12"), isConfirmed: true),
            LabValue(kind: .triglycerides, value: 140, isConfirmed: true),
        ]

        let sheet = FactSheet.build(
            snapshot: fullSnapshot,
            labs: labs,
            context: ["User has told us they live with NAFLD."],
            timeZone: utc
        )

        #expect(sheet.contains("HEALTH DATA (last 30 days, from export dated 2026-10-05)"))
        #expect(sheet.contains("- Steps: avg 6,240/day; last 7 days avg 5,100 (down 21% vs earlier)"))
        #expect(sheet.contains("- Sleep: avg 6h 35m/night (26 nights recorded)"))
        #expect(sheet.contains("- Resting heart rate: avg 62 bpm; stable"))
        #expect(sheet.contains("- Weight: 81.4 kg latest; -0.8 kg over 30 days"))
        #expect(sheet.contains("LAB RESULTS (entered and confirmed by user)"))
        #expect(sheet.contains("- ALT: 62 U/L (report range 7-56) -> ABOVE range. Date 2026-09-12"))
        #expect(sheet.contains("- Triglycerides: 140 mg/dL (report range <150) -> WITHIN range"))
        #expect(sheet.contains("CONTEXT"))
        #expect(sheet.contains("- User has told us they live with NAFLD."))
    }

    /// The sheet is the model's entire view of the user. If it grows unbounded, a 1.7B
    /// model starts quoting the wrong numbers.
    @Test func staysWithinTokenBudget() {
        let labs = LabKind.allCases.map {
            LabValue(kind: $0, value: 50, date: date("2026-09-12"), isConfirmed: true)
        }

        let sheet = FactSheet.build(
            snapshot: fullSnapshot,
            labs: labs,
            context: ["User has told us they live with NAFLD."],
            timeZone: utc
        )

        // ~4 characters per token is the usual rough conversion; 300 tokens ≈ 1200 chars.
        #expect(sheet.count < 1200, "Fact sheet is over the ~300 token budget: \(sheet.count) chars")
    }

    // MARK: - Missing data

    @Test func missingMetricsSayNoDataRatherThanZero() {
        let sheet = FactSheet.build(
            snapshot: HealthSnapshot(windowDays: 30),
            labs: [],
            timeZone: utc
        )

        #expect(sheet.contains("- Steps: no data"))
        #expect(sheet.contains("- Sleep: no data"))
        #expect(sheet.contains("- Resting heart rate: no data"))
        #expect(sheet.contains("- Weight: no data"))
    }

    @Test func omitsExportDateWhenUnknown() {
        let sheet = FactSheet.build(snapshot: HealthSnapshot(windowDays: 30), labs: [], timeZone: utc)
        #expect(sheet.contains("HEALTH DATA (last 30 days)"))
    }

    @Test func partialCoverageIsFlagged() {
        let snapshot = HealthSnapshot(windowDays: 30, steps: series(days: 4, average: 6000))
        let sheet = FactSheet.build(snapshot: snapshot, labs: [], timeZone: utc)
        #expect(sheet.contains("(4 days recorded)"))
    }

    @Test func fullCoverageOmitsDayCount() {
        let snapshot = HealthSnapshot(windowDays: 30, steps: series(days: 30, average: 6000))
        let sheet = FactSheet.build(snapshot: snapshot, labs: [], timeZone: utc)
        #expect(!sheet.contains("days recorded"))
    }

    @Test func trendOmittedWhenInsufficientData() {
        let snapshot = HealthSnapshot(
            windowDays: 30,
            steps: series(days: 4, average: 6000, recent: 5000, trend: .insufficientData)
        )
        let sheet = FactSheet.build(snapshot: snapshot, labs: [], timeZone: utc)
        #expect(!sheet.contains("last 7 days"))
    }

    // MARK: - Labs

    @Test func unconfirmedLabsNeverReachTheModel() {
        let labs = [
            LabValue(kind: .alt, value: 62, isConfirmed: false),
            LabValue(kind: .ast, value: 38, isConfirmed: true),
        ]
        let sheet = FactSheet.build(snapshot: HealthSnapshot(), labs: labs, timeZone: utc)

        #expect(!sheet.contains("ALT: 62"))
        #expect(sheet.contains("AST: 38"))
    }

    @Test func noConfirmedLabsStatesNoneRatherThanOmittingSection() {
        let sheet = FactSheet.build(snapshot: HealthSnapshot(), labs: [], timeZone: utc)
        #expect(sheet.contains("LAB RESULTS (entered and confirmed by user)"))
        #expect(sheet.contains("- None confirmed."))
    }

    /// Output must not depend on the order the user happened to type the labs in.
    @Test func labOrderingIsDeterministic() {
        let forward = [
            LabValue(kind: .alt, value: 62, isConfirmed: true),
            LabValue(kind: .a1c, value: 5.4, isConfirmed: true),
        ]
        let reversed: [LabValue] = forward.reversed()

        #expect(
            FactSheet.labsSection(forward, timeZone: utc)
                == FactSheet.labsSection(reversed, timeZone: utc)
        )
    }

    @Test func astAltRatioAppearsWithoutInterpretation() {
        let labs = [
            LabValue(kind: .alt, value: 60, isConfirmed: true),
            LabValue(kind: .ast, value: 39, isConfirmed: true),
        ]
        let section = FactSheet.labsSection(labs, timeZone: utc)

        #expect(section.contains("- AST/ALT ratio: 0.65"))
        // Hard rule 2: a bare number, never a reading of it.
        #expect(!section.lowercased().contains("suggest"))
        #expect(!section.lowercased().contains("indicat"))
    }

    @Test func labDateOmittedWhenAbsent() {
        let labs = [LabValue(kind: .alt, value: 62, isConfirmed: true)]
        #expect(!FactSheet.labsSection(labs, timeZone: utc).contains("Date"))
    }

    // MARK: - Context

    @Test func contextSectionOmittedWhenEmpty() {
        let sheet = FactSheet.build(snapshot: HealthSnapshot(), labs: [], timeZone: utc)
        #expect(!sheet.contains("CONTEXT"))
    }

    // MARK: - Formatting helpers

    @Test func thousandsGrouping() {
        #expect(FactSheet.grouped(6240) == "6,240")
        #expect(FactSheet.grouped(999) == "999")
        #expect(FactSheet.grouped(1000) == "1,000")
        #expect(FactSheet.grouped(1_234_567) == "1,234,567")
        #expect(FactSheet.grouped(0) == "0")
    }

    @Test func hoursAndMinutes() {
        #expect(FactSheet.hoursAndMinutes(6.583) == "6h 35m")
        #expect(FactSheet.hoursAndMinutes(8) == "8h 0m")
        #expect(FactSheet.hoursAndMinutes(0.5) == "0h 30m")
    }

    /// A 59.7-minute remainder must roll into the next hour, not print "6h 60m".
    @Test func hoursAndMinutesRollsOverRatherThanPrintingSixty() {
        #expect(FactSheet.hoursAndMinutes(6.999) == "7h 0m")
    }

    @Test func weightGainShowsPlusSign() {
        let snapshot = HealthSnapshot(
            windowDays: 30,
            weightKilograms: series(days: 30, average: 81, latest: 82.2, first: 81.4)
        )
        let sheet = FactSheet.build(snapshot: snapshot, labs: [], timeZone: utc)
        #expect(sheet.contains("+0.8 kg over 30 days"))
    }
}
