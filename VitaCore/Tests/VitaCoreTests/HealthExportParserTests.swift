import Foundation
import Testing
@testable import VitaCore

/// Fixtures here are synthetic. They mirror the structure of a real Health export
/// exactly — attribute order, date format, the `<MetadataEntry>` child on sleep
/// records, the two source names a renamed Watch produces — but every value is
/// invented. Real export data must never enter the repository (CLAUDE.md hard rule 6).
@Suite("Health export parsing")
struct HealthExportParserTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    // MARK: - Fixture building

    func export(_ records: String, exportedOn: String = "2026-10-13 17:01:08 -0400") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!-- HealthKit Export Version: 13 -->
        ]>
        <HealthData locale="en_US">
         <ExportDate value="\(exportedOn)"/>
         <Me HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexNotSet"/>
        \(records)
        </HealthData>
        """
    }

    func steps(_ date: String, _ value: Int, source: String) -> String {
        """
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="\(source)" unit="count" \
        creationDate="\(date)" startDate="\(date)" endDate="\(date)" value="\(value)"/>
        """
    }

    func sleep(_ start: String, _ end: String, value: String, source: String = "Apple Watch") -> String {
        """
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="\(source)" \
        creationDate="\(start)" startDate="\(start)" endDate="\(end)" \
        value="HKCategoryValueSleepAnalysis\(value)">
          <MetadataEntry key="HKTimeZone" value="America/New_York"/>
         </Record>
        """
    }

    func weight(_ date: String, _ value: Double, unit: String) -> String {
        """
         <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Health" unit="\(unit)" \
        creationDate="\(date)" startDate="\(date)" endDate="\(date)" value="\(value)"/>
        """
    }

    func heartRate(_ date: String, _ value: Int, source: String = "Apple Watch") -> String {
        """
         <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="\(source)" unit="count/min" \
        creationDate="\(date)" startDate="\(date)" endDate="\(date)" value="\(value)"/>
        """
    }

    func parse(_ xml: String, days: Int = 30) throws -> HealthSnapshot {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try HealthExportParser.parse(contentsOf: url, days: days, calendar: calendar)
    }

    // MARK: - The export itself

    @Test func readsExportDate() throws {
        let snapshot = try parse(export(steps("2026-10-12 09:00:00 -0400", 5000, source: "Apple Watch")))
        #expect(snapshot.exportDate != nil)
        #expect(snapshot.windowDays == 30)
    }

    @Test func rejectsFilesThatArentHealthExports() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-health-\(UUID().uuidString).xml")
        try "<root><thing/></root>".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: HealthExportParser.ParseError.notAHealthExport) {
            try HealthExportParser.parse(contentsOf: url, calendar: calendar)
        }
    }

    // MARK: - Step de-duplication
    //
    // The real export carried 1,322 Watch records and 995 iPhone records over the same
    // 30 days, for the same walks. This is the hazard that would have been invisible:
    // a doubled step count reads as plausible.

    @Test func doesNotSumStepsFromTwoDevices() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 4000, source: "Apple Watch"),
            steps("2026-10-12 14:00:00 -0400", 2000, source: "Apple Watch"),
            steps("2026-10-12 09:05:00 -0400", 3500, source: "Arjun iPhone (2)"),
            steps("2026-10-12 14:05:00 -0400", 1800, source: "Arjun iPhone (2)"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        let day = try #require(snapshot.steps.daily.first)

        // Watch total is 6,000 and phone total is 5,300. The sum, 11,300, is wrong.
        #expect(isClose(day.value, 6000))
    }

    @Test func prefersTheWatchEvenWhenThePhoneRecordedMore() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 1000, source: "Apple Watch"),
            steps("2026-10-12 09:05:00 -0400", 9000, source: "Arjun iPhone (2)"),
        ].joined(separator: "\n"))

        let day = try #require(try parse(xml).steps.daily.first)
        #expect(isClose(day.value, 1000))
    }

    @Test func fallsBackToThePhoneOnDaysTheWatchWasntWorn() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 4000, source: "Apple Watch"),
            steps("2026-10-11 09:00:00 -0400", 7200, source: "Arjun iPhone (2)"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        #expect(snapshot.steps.daysWithData == 2)
        #expect(snapshot.steps.daily.map { Int($0.value) }.sorted() == [4000, 7200])
    }

    /// The same physical Watch appeared under two names after a rename, so matching
    /// has to be loose rather than an exact string.
    @Test func recognisesARenamedWatch() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 5000, source: "Arjun’s Apple Watch"),
            steps("2026-10-12 09:05:00 -0400", 9000, source: "Arjun iPhone (2)"),
        ].joined(separator: "\n"))

        let day = try #require(try parse(xml).steps.daily.first)
        #expect(isClose(day.value, 5000))
    }

    // MARK: - Sleep

    /// `InBed` spans the whole night and `Awake` is time awake in bed. Counting either
    /// as sleep roughly doubles the total and overlaps the real stages.
    @Test func countsOnlyAsleepStages() throws {
        let xml = export([
            sleep("2026-10-12 23:00:00 -0400", "2026-10-13 07:00:00 -0400", value: "InBed"),
            sleep("2026-10-12 23:30:00 -0400", "2026-10-13 02:30:00 -0400", value: "AsleepCore"),
            sleep("2026-10-13 02:30:00 -0400", "2026-10-13 03:30:00 -0400", value: "AsleepDeep"),
            sleep("2026-10-13 03:30:00 -0400", "2026-10-13 04:00:00 -0400", value: "Awake"),
            sleep("2026-10-13 04:00:00 -0400", "2026-10-13 05:30:00 -0400", value: "AsleepREM"),
        ].joined(separator: "\n"))

        let night = try #require(try parse(xml).sleepHours.daily.first)
        // 3h core + 1h deep + 1.5h REM = 5.5h. InBed's 8h and Awake's 0.5h don't count.
        #expect(isClose(night.value, 5.5, tolerance: 0.01))
    }

    /// Watch and phone both record sleep and their intervals overlap rather than tile.
    /// Adding the durations would invent hours that were only slept once.
    @Test func mergesOverlappingSleepFromTwoDevices() throws {
        let xml = export([
            sleep("2026-10-12 23:00:00 -0400", "2026-10-13 03:00:00 -0400",
                  value: "AsleepCore", source: "Apple Watch"),
            sleep("2026-10-13 01:00:00 -0400", "2026-10-13 05:00:00 -0400",
                  value: "AsleepCore", source: "Arjun iPhone (2)"),
        ].joined(separator: "\n"))

        let night = try #require(try parse(xml).sleepHours.daily.first)
        // Union is 23:00–05:00, six hours. Summing would give eight.
        #expect(isClose(night.value, 6, tolerance: 0.01))
    }

    @Test func attributesSleepToTheMorningItEndsOn() throws {
        let xml = export([
            sleep("2026-10-11 23:00:00 -0400", "2026-10-12 06:00:00 -0400", value: "AsleepCore"),
            sleep("2026-10-12 22:00:00 -0400", "2026-10-13 05:00:00 -0400", value: "AsleepCore"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        // Two separate nights, not one run of sleep.
        #expect(snapshot.sleepHours.daysWithData == 2)
    }

    @Test func ignoresDaytimeNaps() throws {
        let xml = export([
            sleep("2026-10-12 14:00:00 -0400", "2026-10-12 15:00:00 -0400", value: "AsleepCore"),
        ].joined(separator: "\n"))

        #expect(try parse(xml).sleepHours.daysWithData == 0)
    }

    @Test func mergeOverlappingCollapsesCorrectly() {
        func d(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

        let merged = Collector.mergeOverlapping([
            (d(0), d(100)),
            (d(50), d(150)),   // overlaps
            (d(200), d(260)),  // separate
            (d(150), d(180)),  // touches the first run's end
        ])

        #expect(merged.count == 2)
        #expect(merged[0].start == d(0) && merged[0].end == d(180))
        #expect(merged[1].start == d(200) && merged[1].end == d(260))
    }

    // MARK: - Units
    //
    // The real export reported body mass in pounds, not kilograms.

    @Test func convertsPoundsToKilograms() throws {
        let xml = export(weight("2026-10-12 08:00:00 -0400", 180, unit: "lb"))
        let latest = try #require(try parse(xml).weightKilograms.latest)
        #expect(isClose(latest.value, 81.6466, tolerance: 0.01))
    }

    @Test func leavesKilogramsAlone() throws {
        let xml = export(weight("2026-10-12 08:00:00 -0400", 81.4, unit: "kg"))
        let latest = try #require(try parse(xml).weightKilograms.latest)
        #expect(isClose(latest.value, 81.4, tolerance: 0.01))
    }

    @Test func unitConversionTable() {
        #expect(isClose(Collector.kilograms(180, unit: "lb"), 81.6466, tolerance: 0.001))
        #expect(isClose(Collector.kilograms(81.4, unit: "kg"), 81.4))
        #expect(isClose(Collector.kilograms(81400, unit: "g"), 81.4))
        #expect(isClose(Collector.kilograms(12, unit: "st"), 76.2035, tolerance: 0.001))
        #expect(isClose(Collector.kilograms(81.4, unit: nil), 81.4))
    }

    @Test func takesTheLastWeightOfEachDay() throws {
        let xml = export([
            weight("2026-10-12 08:00:00 -0400", 180, unit: "lb"),
            weight("2026-10-12 20:00:00 -0400", 182, unit: "lb"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        #expect(snapshot.weightKilograms.daysWithData == 1)
        let latest = try #require(snapshot.weightKilograms.latest)
        #expect(isClose(latest.value, 82.5535, tolerance: 0.01))
    }

    // MARK: - Resting heart rate

    /// A renamed Watch writes the same reading under both names. Averaging the
    /// duplicate would be harmless here but wrong in principle.
    @Test func deduplicatesHeartRateFromARenamedDevice() throws {
        let xml = export([
            heartRate("2026-10-12 06:00:00 -0400", 62, source: "Apple Watch"),
            heartRate("2026-10-12 06:00:00 -0400", 62, source: "Arjun’s Apple Watch"),
            heartRate("2026-10-12 18:00:00 -0400", 70, source: "Apple Watch"),
        ].joined(separator: "\n"))

        let day = try #require(try parse(xml).restingHeartRate.daily.first)
        #expect(isClose(day.value, 66))
    }

    // MARK: - Windowing

    @Test func ignoresRecordsOlderThanTheWindow() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 5000, source: "Apple Watch"),
            steps("2019-10-05 09:00:00 -0400", 9999, source: "Apple Watch"),
            steps("2026-08-01 09:00:00 -0400", 8888, source: "Apple Watch"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        #expect(snapshot.steps.daysWithData == 1)
        #expect(isClose(try #require(snapshot.steps.average), 5000))
    }

    @Test func respectsACustomWindow() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 5000, source: "Apple Watch"),
            steps("2026-10-01 09:00:00 -0400", 6000, source: "Apple Watch"),
        ].joined(separator: "\n"))

        #expect(try parse(xml, days: 30).steps.daysWithData == 2)
        #expect(try parse(xml, days: 5).steps.daysWithData == 1)
    }

    // MARK: - Missing data

    @Test func emptyExportProducesNoDataRatherThanCrashing() throws {
        let snapshot = try parse(export(""))
        #expect(snapshot.isEmpty)
        #expect(!snapshot.steps.hasData)
        #expect(snapshot.sleepHours.average == nil)
    }

    /// A metric the user doesn't record must not take the others down with it.
    @Test func oneMetricMissingDoesNotAffectTheRest() throws {
        let xml = export([
            steps("2026-10-12 09:00:00 -0400", 5000, source: "Apple Watch"),
            weight("2026-10-12 08:00:00 -0400", 180, unit: "lb"),
        ].joined(separator: "\n"))

        let snapshot = try parse(xml)
        #expect(snapshot.steps.hasData)
        #expect(snapshot.weightKilograms.hasData)
        #expect(!snapshot.sleepHours.hasData)
        #expect(!snapshot.restingHeartRate.hasData)
    }

    @Test func malformedValuesAreSkippedRatherThanCrashing() throws {
        let xml = export("""
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" \
        creationDate="2026-10-12 09:00:00 -0400" startDate="2026-10-12 09:00:00 -0400" \
        endDate="2026-10-12 09:00:00 -0400" value="not-a-number"/>
        \(steps("2026-10-12 10:00:00 -0400", 5000, source: "Apple Watch"))
        """)

        #expect(isClose(try #require(try parse(xml).steps.average), 5000))
    }
}
