import Foundation

/// One day's value for a metric. `date` is the start of that day.
public struct DailyValue: Sendable, Equatable, Codable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Direction of travel for a metric, comparing the most recent 7 days against
/// the preceding stretch of the window.
public enum MetricTrend: Sendable, Equatable, Codable {
    case up(percent: Double)
    case down(percent: Double)
    case stable
    case insufficientData

    /// Phrasing for the fact sheet. Kept factual — the model rewords, it doesn't judge.
    public var factSheetLabel: String {
        switch self {
        case let .up(percent): "up \(Int(percent.rounded()))% vs earlier"
        case let .down(percent): "down \(Int(percent.rounded()))% vs earlier"
        case .stable: "stable"
        case .insufficientData: "not enough data for a trend"
        }
    }
}

/// Daily values for one metric plus the statistics derived from them.
///
/// Every number Vita displays or hands to the model comes from here. The model
/// never computes anything — CLAUDE.md hard rule 3.
public struct MetricSeries: Sendable, Equatable, Codable {
    /// Days that actually had data, oldest first. Days without data are absent rather
    /// than zero: a day with no step samples is unknown, not a day of zero steps.
    public let daily: [DailyValue]

    public let average: Double?
    public let recentAverage: Double?
    public let priorAverage: Double?
    public let trend: MetricTrend

    /// Below this relative change, a metric reads as stable rather than up or down.
    public static let stableThresholdPercent: Double = 5

    /// A trend needs at least this many days on each side of the split to mean anything.
    public static let minimumDaysPerTrendBucket = 3

    /// Days in the recent bucket. The window's remaining days form the prior bucket —
    /// 7 and 23 for a 30-day window.
    public static let recentWindowDays = 7

    public var daysWithData: Int { daily.count }
    public var hasData: Bool { !daily.isEmpty }

    /// Most recent value, used for weight where the latest reading matters more
    /// than the average.
    public var latest: DailyValue? { daily.last }

    public var earliest: DailyValue? { daily.first }

    /// Change from the first recorded value in the window to the last.
    public var changeOverWindow: Double? {
        guard let first = daily.first, let last = daily.last, daily.count >= 2 else { return nil }
        return last.value - first.value
    }

    /// Builds a series from raw daily values.
    ///
    /// - Parameters:
    ///   - daily: One entry per day with data, in any order.
    ///   - windowEnd: The day the window ends on, normally the export date.
    ///   - calendar: Injectable so tests are not at the mercy of the machine's time zone.
    public init(
        daily: [DailyValue],
        windowEnd: Date,
        calendar: Calendar = .current
    ) {
        let sorted = daily.sorted { $0.date < $1.date }
        self.daily = sorted

        guard !sorted.isEmpty else {
            average = nil
            recentAverage = nil
            priorAverage = nil
            trend = .insufficientData
            return
        }

        average = sorted.map(\.value).mean

        // Split on the boundary of the recent window rather than on element count, so
        // gaps in the data don't shift the split date around.
        let boundary = calendar.date(
            byAdding: .day,
            value: -Self.recentWindowDays,
            to: calendar.startOfDay(for: windowEnd)
        )

        guard let boundary else {
            recentAverage = nil
            priorAverage = nil
            trend = .insufficientData
            return
        }

        let recent = sorted.filter { $0.date > boundary }
        let prior = sorted.filter { $0.date <= boundary }

        recentAverage = recent.map(\.value).mean
        priorAverage = prior.map(\.value).mean

        trend = Self.trend(
            recent: recent,
            prior: prior,
            recentAverage: recentAverage,
            priorAverage: priorAverage
        )
    }

    /// Memberwise init for tests and for callers that have already done the arithmetic.
    public init(
        daily: [DailyValue],
        average: Double?,
        recentAverage: Double?,
        priorAverage: Double?,
        trend: MetricTrend
    ) {
        self.daily = daily
        self.average = average
        self.recentAverage = recentAverage
        self.priorAverage = priorAverage
        self.trend = trend
    }

    private static func trend(
        recent: [DailyValue],
        prior: [DailyValue],
        recentAverage: Double?,
        priorAverage: Double?
    ) -> MetricTrend {
        guard recent.count >= minimumDaysPerTrendBucket,
              prior.count >= minimumDaysPerTrendBucket,
              let recentAverage,
              let priorAverage,
              priorAverage != 0
        else { return .insufficientData }

        let percentChange = ((recentAverage - priorAverage) / abs(priorAverage)) * 100

        if abs(percentChange) < stableThresholdPercent { return .stable }
        return percentChange > 0 ? .up(percent: percentChange) : .down(percent: abs(percentChange))
    }

    /// An empty series, for metrics the export had nothing for.
    public static let noData = MetricSeries(
        daily: [],
        average: nil,
        recentAverage: nil,
        priorAverage: nil,
        trend: .insufficientData
    )
}

/// The 30-day picture handed to `FactSheet`.
///
/// Units are fixed here so formatting has nothing to guess: steps are counts,
/// sleep is hours per night, resting heart rate is bpm, weight is kilograms.
public struct HealthSnapshot: Sendable, Equatable, Codable {
    public let windowDays: Int

    /// When the underlying export was produced. Shown in the fact sheet so the model —
    /// and the user — know how stale the data is. Nil if it couldn't be determined.
    public let exportDate: Date?

    public let steps: MetricSeries
    public let sleepHours: MetricSeries
    public let restingHeartRate: MetricSeries
    public let weightKilograms: MetricSeries

    public init(
        windowDays: Int = 30,
        exportDate: Date? = nil,
        steps: MetricSeries = .noData,
        sleepHours: MetricSeries = .noData,
        restingHeartRate: MetricSeries = .noData,
        weightKilograms: MetricSeries = .noData
    ) {
        self.windowDays = windowDays
        self.exportDate = exportDate
        self.steps = steps
        self.sleepHours = sleepHours
        self.restingHeartRate = restingHeartRate
        self.weightKilograms = weightKilograms
    }

    /// True when every metric came back empty, which usually means the export was
    /// unreadable or the window is wrong rather than that the user did nothing for a month.
    public var isEmpty: Bool {
        !steps.hasData && !sleepHours.hasData
            && !restingHeartRate.hasData && !weightKilograms.hasData
    }
}

extension Collection<Double> {
    /// Nil rather than zero for an empty collection, so "no data" never reads as "zero".
    var mean: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
