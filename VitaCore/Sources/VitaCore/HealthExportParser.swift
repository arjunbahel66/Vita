import Foundation

/// Parses the file produced by Health → Export All Health Data.
///
/// Written against a real 579 MB export containing 3.3 million records going back to
/// 2018. The shape of this code is dictated by three things found in that file:
///
/// 1. **Two devices log the same metric.** In one 30-day window there were 1,322 step
///    records from an Apple Watch and 995 from the iPhone, for the same walks. Summing
///    them doubles the step count, and the result looks perfectly plausible.
/// 2. **Units are per-record, not global.** Body mass came back in `lb`, not kilograms.
/// 3. **`InBed` and `Awake` are sleep records too.** Counting them as sleep roughly
///    doubles the night and overlaps the real asleep stages.
///
/// It streams. The file is far too large to hold in memory, and only about four
/// kilobytes of summary statistics survive the parse — see CLAUDE.md hard rule 6.
public enum HealthExportParser {
    public enum ParseError: LocalizedError, Equatable {
        case unreadable(String)
        case notAHealthExport

        public var errorDescription: String? {
            switch self {
            case let .unreadable(detail): "Couldn't read the export: \(detail)"
            case .notAHealthExport: "That file doesn't look like a Health export. Choose export.xml."
            }
        }
    }

    /// - Parameters:
    ///   - url: `export.xml`, read in place. Nothing is copied into app storage.
    ///   - days: size of the window, counted back from the export date.
    public static func parse(
        contentsOf url: URL,
        days: Int = 30,
        calendar: Calendar = .current
    ) throws -> HealthSnapshot {
        guard let parser = XMLParser(contentsOf: url) else {
            throw ParseError.unreadable("could not open \(url.lastPathComponent)")
        }

        let collector = Collector(days: days, calendar: calendar)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "malformed XML"
            throw ParseError.unreadable(detail)
        }
        guard collector.sawHealthData else { throw ParseError.notAHealthExport }

        return collector.buildSnapshot()
    }
}

// MARK: - Streaming collector

/// Internal rather than private so the interval merging and unit conversion can be
/// tested directly — both are places a silent error would be invisible in the output.
final class Collector: NSObject, XMLParserDelegate {
    private let days: Int
    private let calendar: Calendar

    private(set) var sawHealthData = false
    private var exportDate: Date?

    /// Day → source → total. Kept per source so one device can be chosen later;
    /// merging first is what causes double counting.
    private var stepsByDaySource: [Date: [String: Double]] = [:]

    private var heartRateByDay: [Date: [Double]] = [:]
    /// Deduplicated on start instant, since the same reading appears under both the
    /// old and new name of a renamed Watch.
    private var seenHeartRateInstants: Set<Date> = []

    private var weights: [(date: Date, kilograms: Double)] = []

    /// Asleep intervals from every source, merged at the end.
    private var sleepIntervals: [(start: Date, end: Date)] = []

    /// Set once the export date is known; records starting before it are skipped
    /// before any expensive parsing happens.
    private var cutoffPrefix: String?

    init(days: Int, calendar: Calendar) {
        self.days = days
        self.calendar = calendar
        super.init()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return Self.formatter.date(from: string)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attrs: [String: String] = [:]
    ) {
        switch element {
        case "HealthData":
            sawHealthData = true

        case "ExportDate":
            guard let value = attrs["value"], let parsed = date(value) else { return }
            exportDate = parsed
            // "2026-10-13 17:01:08 -0400" sorts lexically by its first ten characters,
            // so a string comparison rejects most of the file without constructing a
            // Date. With 3.3 million records and perhaps 3,000 in range, this is the
            // difference between seconds and minutes.
            if let cutoff = calendar.date(byAdding: .day, value: -days, to: parsed) {
                cutoffPrefix = String(Self.formatter.string(from: cutoff).prefix(10))
            }

        case "Record":
            handle(attrs)

        default:
            // MetadataEntry and friends. Sleep records are not self-closing.
            break
        }
    }

    private func handle(_ attrs: [String: String]) {
        guard let type = attrs["type"], let startRaw = attrs["startDate"] else { return }

        if let cutoffPrefix, String(startRaw.prefix(10)) < cutoffPrefix { return }

        switch type {
        case "HKQuantityTypeIdentifierStepCount":
            guard let start = date(startRaw),
                  let value = Double(attrs["value"] ?? ""),
                  let source = attrs["sourceName"]
            else { return }
            let day = calendar.startOfDay(for: start)
            stepsByDaySource[day, default: [:]][source, default: 0] += value

        case "HKQuantityTypeIdentifierRestingHeartRate":
            guard let start = date(startRaw),
                  let value = Double(attrs["value"] ?? "")
            else { return }
            guard seenHeartRateInstants.insert(start).inserted else { return }
            heartRateByDay[calendar.startOfDay(for: start), default: []].append(value)

        case "HKQuantityTypeIdentifierBodyMass":
            guard let start = date(startRaw),
                  let value = Double(attrs["value"] ?? "")
            else { return }
            weights.append((start, Self.kilograms(value, unit: attrs["unit"])))

        case "HKCategoryTypeIdentifierSleepAnalysis":
            guard Self.isAsleep(attrs["value"]),
                  let start = date(startRaw),
                  let end = date(attrs["endDate"]),
                  end > start
            else { return }
            sleepIntervals.append((start, end))

        default:
            break
        }
    }

    /// Only the asleep stages count. `InBed` spans the whole night and overlaps every
    /// other stage; `Awake` is time spent awake in bed. Counting either as sleep roughly
    /// doubles the total.
    ///
    /// `AsleepUnspecified` is the pre-iOS 16 value and appears in older history.
    private static func isAsleep(_ value: String?) -> Bool {
        guard let value else { return false }
        let stages = [
            "HKCategoryValueSleepAnalysisAsleepCore",
            "HKCategoryValueSleepAnalysisAsleepDeep",
            "HKCategoryValueSleepAnalysisAsleepREM",
            "HKCategoryValueSleepAnalysisAsleepUnspecified",
            "HKCategoryValueSleepAnalysisAsleep",
        ]
        return stages.contains(value)
    }

    static func kilograms(_ value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "lb": value * 0.453_592_37
        case "g": value / 1000
        case "st": value * 6.350_293_18
        default: value // kg, or unlabelled
        }
    }

    // MARK: - Assembly

    func buildSnapshot() -> HealthSnapshot {
        let windowEnd = exportDate ?? Date()

        return HealthSnapshot(
            windowDays: days,
            exportDate: exportDate,
            steps: MetricSeries(daily: dailySteps(), windowEnd: windowEnd, calendar: calendar),
            sleepHours: MetricSeries(daily: dailySleepHours(), windowEnd: windowEnd, calendar: calendar),
            restingHeartRate: MetricSeries(
                daily: heartRateByDay.compactMap { day, values in
                    values.mean.map { DailyValue(date: day, value: $0) }
                },
                windowEnd: windowEnd,
                calendar: calendar
            ),
            weightKilograms: MetricSeries(daily: dailyWeights(), windowEnd: windowEnd, calendar: calendar)
        )
    }

    /// One source per day, never the sum.
    ///
    /// A worn Watch counts steps the phone misses, so it wins where present — matched
    /// loosely because the same device appeared as both "Apple Watch" and
    /// "Arjun's Apple Watch" after a rename. On days with no Watch data the phone is
    /// used instead, and between two candidates the one with the larger total wins,
    /// since a partial day is usually a device that was set down.
    private func dailySteps() -> [DailyValue] {
        stepsByDaySource.compactMap { day, bySource in
            let watch = bySource.filter { $0.key.localizedCaseInsensitiveContains("watch") }
            let candidates = watch.isEmpty ? bySource : watch
            guard let best = candidates.values.max() else { return nil }
            return DailyValue(date: day, value: best)
        }
    }

    /// Merged asleep time per night, where a night runs 6 pm to noon the next day and
    /// is labelled by the morning it ends on — the way people talk about it.
    ///
    /// Merging matters: the Watch and the phone both record sleep, and their intervals
    /// overlap rather than tile. Adding the durations would invent hours that were
    /// slept once.
    private func dailySleepHours() -> [DailyValue] {
        let merged = Self.mergeOverlapping(sleepIntervals)

        var secondsByNight: [Date: Double] = [:]
        for interval in merged {
            guard let night = night(of: interval.start) else { continue }
            secondsByNight[night, default: 0] += interval.end.timeIntervalSince(interval.start)
        }

        return secondsByNight.map { DailyValue(date: $0.key, value: $0.value / 3600) }
    }

    /// The morning a sleep interval belongs to, or nil for a daytime nap that falls
    /// outside the 6 pm – noon window.
    private func night(of start: Date) -> Date? {
        let hour = calendar.component(.hour, from: start)
        let day = calendar.startOfDay(for: start)
        if hour >= 18 { return calendar.date(byAdding: .day, value: 1, to: day) }
        if hour < 12 { return day }
        return nil
    }

    /// Last reading of each day. Weight is a point measurement, not something to average.
    private func dailyWeights() -> [DailyValue] {
        var latestPerDay: [Date: (Date, Double)] = [:]
        for entry in weights {
            let day = calendar.startOfDay(for: entry.date)
            if let existing = latestPerDay[day], existing.0 >= entry.date { continue }
            latestPerDay[day] = (entry.date, entry.kilograms)
        }
        return latestPerDay.map { DailyValue(date: $0.key, value: $0.value.1) }
    }

    /// Collapses overlapping and touching intervals into the union of their time.
    static func mergeOverlapping(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }

        var merged: [(start: Date, end: Date)] = [sorted[0]]
        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.start <= last.end {
                if interval.end > last.end { merged[merged.count - 1].end = interval.end }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
