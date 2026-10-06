import Foundation

/// Builds the compact text block that is the *only* thing the model ever sees.
///
/// The model never reads `export.xml`, never sees raw daily values, and never sees a
/// number it wasn't handed here. Everything in this block was computed in Swift —
/// CLAUDE.md hard rule 3 — so the model's job is reduced to rewording facts.
///
/// Target is roughly 300 tokens. The limit is not context size (Qwen3 has plenty) but
/// attention: at 1.7B, every extra number is another chance to quote the wrong one.
public enum FactSheet {
    /// - Parameters:
    ///   - snapshot: Precomputed metrics. See `HealthSnapshot`.
    ///   - labs: All labs; unconfirmed ones are filtered out here, not by the caller.
    ///   - context: Free-text lines the user has chosen to share, e.g. a condition they
    ///     live with. Passed in rather than hardcoded so this library holds no personal
    ///     health information of its own.
    ///   - timeZone: Injectable so output doesn't shift with the machine's zone.
    public static func build(
        snapshot: HealthSnapshot,
        labs: [LabValue],
        context: [String] = [],
        timeZone: TimeZone = .current
    ) -> String {
        var sections: [String] = [
            healthSection(snapshot, timeZone: timeZone),
            labsSection(labs, timeZone: timeZone),
        ]

        if !context.isEmpty {
            sections.append(contextSection(context))
        }


        return sections.joined(separator: "\n\n")
    }

    // MARK: - Health

    static func healthSection(_ snapshot: HealthSnapshot, timeZone: TimeZone) -> String {
        var header = "HEALTH DATA (last \(snapshot.windowDays) days"
        if let exportDate = snapshot.exportDate {
            header += ", from export dated \(format(date: exportDate, timeZone: timeZone))"
        }
        header += ")"

        let lines = [
            stepsLine(snapshot.steps, windowDays: snapshot.windowDays),
            sleepLine(snapshot.sleepHours, windowDays: snapshot.windowDays),
            restingHeartRateLine(snapshot.restingHeartRate, windowDays: snapshot.windowDays),
            weightLine(snapshot.weightKilograms, windowDays: snapshot.windowDays),
        ]

        return ([header] + lines).joined(separator: "\n")
    }

    static func stepsLine(_ series: MetricSeries, windowDays: Int) -> String {
        guard let average = series.average else { return "- Steps: no data" }

        var line = "- Steps: avg \(grouped(average))/day"
        if let recent = series.recentAverage, series.trend.isMeaningful {
            line += "; last 7 days avg \(grouped(recent)) (\(series.trend.factSheetLabel))"
        }
        line += coverageSuffix(series, windowDays: windowDays, noun: "days")
        return line
    }

    static func sleepLine(_ series: MetricSeries, windowDays: Int) -> String {
        guard let average = series.average else { return "- Sleep: no data" }

        var line = "- Sleep: avg \(hoursAndMinutes(average))/night"
        if series.trend.isMeaningful {
            line += "; \(series.trend.factSheetLabel)"
        }
        line += coverageSuffix(series, windowDays: windowDays, noun: "nights")
        return line
    }

    static func restingHeartRateLine(_ series: MetricSeries, windowDays: Int) -> String {
        guard let average = series.average else { return "- Resting heart rate: no data" }

        var line = "- Resting heart rate: avg \(Int(average.rounded())) bpm"
        if series.trend.isMeaningful {
            line += "; \(series.trend.factSheetLabel)"
        }
        line += coverageSuffix(series, windowDays: windowDays, noun: "days")
        return line
    }

    static func weightLine(_ series: MetricSeries, windowDays: Int) -> String {
        guard let latest = series.latest else { return "- Weight: no data" }

        var line = "- Weight: \(decimal(latest.value, places: 1)) kg latest"
        if let change = series.changeOverWindow {
            let sign = change >= 0 ? "+" : "-"
            line += "; \(sign)\(decimal(abs(change), places: 1)) kg over \(windowDays) days"
        }
        return line
    }

    /// Flags incomplete coverage so neither the user nor the model reads an average
    /// over 4 days as an average over 30.
    private static func coverageSuffix(
        _ series: MetricSeries,
        windowDays: Int,
        noun: String
    ) -> String {
        guard series.daysWithData < windowDays else { return "" }
        return " (\(series.daysWithData) \(noun) recorded)"
    }

    // MARK: - Labs

    static func labsSection(_ labs: [LabValue], timeZone: TimeZone) -> String {
        let confirmed = labs.confirmed
        let header = "LAB RESULTS (entered and confirmed by user)"

        guard !confirmed.isEmpty else {
            return "\(header)\n- None confirmed."
        }

        // Stable ordering so output is deterministic regardless of entry order.
        let ordered = LabKind.allCases.compactMap { kind in
            confirmed.first { $0.kind == kind }
        }

        var lines = ordered.map { labLine($0, timeZone: timeZone) }

        // A bare number, with no interpretation — CLAUDE.md section 4.2.
        if let ratio = confirmed.astAltRatio {
            lines.append("- AST/ALT ratio: \(decimal(ratio, places: 2))")
        }

        return ([header] + lines).joined(separator: "\n")
    }

    static func labLine(_ lab: LabValue, timeZone: TimeZone) -> String {
        var line = "- \(lab.kind.displayName): \(lab.formattedValue) \(lab.kind.unit)"
        line += " (report range \(lab.range.displayText(fractionDigits: lab.kind.fractionDigits)))"
        line += " -> \(lab.classification.factSheetLabel)"
        if let date = lab.date {
            line += ". Date \(format(date: date, timeZone: timeZone))"
        }
        return line
    }

    // MARK: - Context

    static func contextSection(_ context: [String]) -> String {
        (["CONTEXT"] + context.map { "- \($0)" }).joined(separator: "\n")
    }

    // MARK: - Formatting
    //
    // Formatters are built per call rather than held statically: Foundation's
    // formatters are not Sendable, and these are cheap relative to model inference.
    // Locale is pinned to en_US_POSIX because the prompt itself is English — output
    // must not change because the user's region does.

    static func format(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "6240" -> "6,240"
    static func grouped(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        let digits = String(abs(rounded))
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (rounded < 0 ? "-" : "") + String(result.reversed())
    }

    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// 6.583 -> "6h 35m". Minutes are rounded, and a 59.7-minute remainder rolls the
    /// hour rather than printing "6h 60m".
    static func hoursAndMinutes(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}

extension MetricTrend {
    /// Whether this trend is worth spending tokens on.
    var isMeaningful: Bool {
        if case .insufficientData = self { return false }
        return true
    }
}
