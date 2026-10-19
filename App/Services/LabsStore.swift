import Foundation
import Observation
import VitaCore

/// Holds the four lab rows and the date of the blood draw.
///
/// Saved to UserDefaults so they survive a relaunch — CLAUDE.md allows current values,
/// which is what these are. Each edit replaces the last; no history accumulates.
///
/// The row type and its validation live in `VitaCore.LabEntry`. This is only storage.
@Observable
@MainActor
final class LabsStore {
    var entries: [LabEntry] { didSet { save() } }

    /// One date for the whole panel rather than one per lab. The four values come from
    /// a single blood draw, so separate pickers would be four ways to disagree about
    /// the same fact.
    var panelDate: Date { didSet { save() } }

    /// Whether a date has been set at all. A draw date the user never entered must not
    /// reach the fact sheet as today's date.
    var hasPanelDate: Bool { didSet { save() } }

    private let defaults = UserDefaults.standard
    private let entriesKey = "labs.entries.v1"
    private let dateKey = "labs.panelDate.v1"
    private let hasDateKey = "labs.hasPanelDate.v1"

    init() {
        if let data = defaults.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([LabEntry].self, from: data),
           decoded.count == LabKind.allCases.count {
            entries = decoded
        } else {
            entries = LabKind.allCases.map(LabEntry.init)
        }
        panelDate = defaults.object(forKey: dateKey) as? Date ?? Date()
        hasPanelDate = defaults.bool(forKey: hasDateKey)
    }

    var confirmedLabValues: [LabValue] {
        entries.confirmedLabValues(date: hasPanelDate ? panelDate : nil)
    }

    var confirmedCount: Int { confirmedLabValues.count }

    /// Clears every row back to the printed defaults.
    func reset() {
        entries = LabKind.allCases.map(LabEntry.init)
        hasPanelDate = false
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: entriesKey)
        }
        defaults.set(panelDate, forKey: dateKey)
        defaults.set(hasPanelDate, forKey: hasDateKey)
    }
}
