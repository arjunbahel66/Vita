import Foundation

// Development and preview data. Not test fixtures — the tests build their own values
// so they stay readable in isolation. This exists so the UI has something realistic to
// render before a real export has been imported, and so SwiftUI previews work offline.
//
// Values here are invented. Nothing in this file is anyone's health data.

public extension HealthSnapshot {
    /// A plausible 30-day snapshot with a visible downward step trend.
    static func sample(referenceDate: Date = Date()) -> HealthSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let end = calendar.startOfDay(for: referenceDate)

        func days(_ count: Int, _ value: (Int) -> Double) -> [DailyValue] {
            (0 ..< count).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: end)
                    .map { DailyValue(date: $0, value: value(offset)) }
            }
        }

        return HealthSnapshot(
            windowDays: 30,
            exportDate: end,
            steps: MetricSeries(
                // Recent week noticeably lower than the preceding three.
                daily: days(30) { $0 < 7 ? 5100 + Double($0 % 3) * 180 : 6500 + Double($0 % 5) * 220 },
                windowEnd: end,
                calendar: calendar
            ),
            sleepHours: MetricSeries(
                daily: days(26) { 6.2 + Double($0 % 4) * 0.3 },
                windowEnd: end,
                calendar: calendar
            ),
            restingHeartRate: MetricSeries(
                daily: days(30) { 61 + Double($0 % 3) },
                windowEnd: end,
                calendar: calendar
            ),
            weightKilograms: MetricSeries(
                daily: days(30) { 81.4 + Double($0) * 0.027 },
                windowEnd: end,
                calendar: calendar
            )
        )
    }
}

public extension LabValue {
    /// Four confirmed labs, one of them above range so the formatting is visible.
    static func samples(referenceDate: Date = Date()) -> [LabValue] {
        let drawn = Calendar.current.date(byAdding: .day, value: -23, to: referenceDate)

        return [
            LabValue(kind: .alt, value: 62, date: drawn, isConfirmed: true),
            LabValue(kind: .ast, value: 38, date: drawn, isConfirmed: true),
            LabValue(kind: .triglycerides, value: 140, date: drawn, isConfirmed: true),
            LabValue(kind: .a1c, value: 5.4, date: drawn, isConfirmed: true),
        ]
    }
}
