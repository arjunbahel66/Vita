import Foundation
import Testing
@testable import VitaCore

/// Arithmetic tests for the statistics the model is never allowed to compute.
/// CLAUDE.md hard rule 3.
@Suite("Metric series")
struct MetricSeriesTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    let windowEnd = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "UTC"),
        year: 2026, month: 10, day: 5
    ).date!

    /// `offset` days before the window end.
    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: windowEnd)!
    }

    func series(_ values: [(offset: Int, value: Double)]) -> MetricSeries {
        MetricSeries(
            daily: values.map { DailyValue(date: day($0.offset), value: $0.value) },
            windowEnd: windowEnd,
            calendar: calendar
        )
    }

    // MARK: - Empty

    @Test func emptySeriesHasNoStatistics() {
        let empty = series([])
        #expect(empty.average == nil)
        #expect(empty.trend == .insufficientData)
        #expect(empty.daysWithData == 0)
        #expect(!empty.hasData)
    }

    // MARK: - Average

    @Test func averageOverRecordedDays() throws {
        let average = try #require(series([(0, 10), (1, 20), (2, 30)]).average)
        #expect(isClose(average, 20))
    }

    /// A day with no samples is unknown, not a day of zero. Averaging it as zero would
    /// quietly understate every metric that has a gap.
    @Test func missingDaysAreExcludedRatherThanTreatedAsZero() throws {
        let result = series([(0, 10), (5, 20)])
        #expect(isClose(try #require(result.average), 15))
        #expect(result.daysWithData == 2)
    }

    // MARK: - Ordering

    @Test func dailyValuesAreSortedOldestFirst() {
        #expect(series([(0, 3), (5, 1), (2, 2)]).daily.map(\.value) == [1, 2, 3])
    }

    @Test func latestAndEarliest() {
        let result = series([(0, 3), (5, 1), (2, 2)])
        #expect(result.latest?.value == 3)
        #expect(result.earliest?.value == 1)
    }

    // MARK: - Trend

    @Test func detectsDownwardTrend() {
        let recent = (0 ..< 7).map { (offset: $0, value: 5000.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 10000.0) }

        guard case let .down(percent) = series(recent + prior).trend else {
            Issue.record("Expected a downward trend")
            return
        }
        #expect(isClose(percent, 50, tolerance: 0.5))
    }

    @Test func detectsUpwardTrend() {
        let recent = (0 ..< 7).map { (offset: $0, value: 12000.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 10000.0) }

        guard case let .up(percent) = series(recent + prior).trend else {
            Issue.record("Expected an upward trend")
            return
        }
        #expect(isClose(percent, 20, tolerance: 0.5))
    }

    /// Small fluctuations read as stable rather than as a trend worth mentioning.
    @Test func smallChangeReadsAsStable() {
        let recent = (0 ..< 7).map { (offset: $0, value: 10200.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 10000.0) }
        #expect(series(recent + prior).trend == .stable)
    }

    @Test func changeJustOverThresholdIsNotStable() {
        let recent = (0 ..< 7).map { (offset: $0, value: 10600.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 10000.0) }
        #expect(series(recent + prior).trend != .stable)
    }

    @Test func tooFewRecentDaysGivesInsufficientData() {
        let recent = (0 ..< 2).map { (offset: $0, value: 5000.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 10000.0) }
        #expect(series(recent + prior).trend == .insufficientData)
    }

    @Test func tooFewPriorDaysGivesInsufficientData() {
        let recent = (0 ..< 7).map { (offset: $0, value: 5000.0) }
        let prior = (7 ..< 9).map { (offset: $0, value: 10000.0) }
        #expect(series(recent + prior).trend == .insufficientData)
    }

    @Test func zeroPriorAverageGivesInsufficientDataRatherThanDividingByZero() {
        let recent = (0 ..< 7).map { (offset: $0, value: 5000.0) }
        let prior = (7 ..< 20).map { (offset: $0, value: 0.0) }
        #expect(series(recent + prior).trend == .insufficientData)
    }

    /// The split is by date, not by element count, so gaps in the data don't move it.
    @Test func splitBoundaryIsByDateNotElementCount() throws {
        let result = series([(0, 1), (1, 1), (2, 1), (10, 99), (11, 99), (12, 99)])
        #expect(isClose(try #require(result.recentAverage), 1))
        #expect(isClose(try #require(result.priorAverage), 99))
    }

    // MARK: - Change over window

    @Test func changeOverWindowUsesFirstAndLast() throws {
        let change = try #require(series([(29, 82.2), (0, 81.4)]).changeOverWindow)
        #expect(isClose(change, -0.8))
    }

    @Test func changeOverWindowNilWithSinglePoint() {
        #expect(series([(0, 81.4)]).changeOverWindow == nil)
    }

    // MARK: - Trend labels

    @Test func trendLabels() {
        #expect(MetricTrend.down(percent: 21).factSheetLabel == "down 21% vs earlier")
        #expect(MetricTrend.up(percent: 12.6).factSheetLabel == "up 13% vs earlier")
        #expect(MetricTrend.stable.factSheetLabel == "stable")
    }
}
