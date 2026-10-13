import Foundation
import Observation
import VitaCore

/// Imports a Health export chosen by the user and keeps the resulting snapshot.
///
/// The export file itself is never copied into app storage and never persisted — it
/// is read in place, under security-scoped access, and only the summary survives
/// (CLAUDE.md hard rule 6). A real export runs to hundreds of megabytes; the snapshot
/// it reduces to is a few kilobytes.
@Observable
@MainActor
final class HealthExportService: HealthService {
    private(set) var snapshot: HealthSnapshot?
    private(set) var state: ImportState = .empty

    /// How long the last parse took. Useful while the on-device cost is still unknown:
    /// the same file parses in about 8 seconds on a Mac.
    private(set) var lastParseSeconds: Double?

    private let windowDays = 30
    private let defaults = UserDefaults.standard
    private let snapshotKey = "health.snapshot.v1"
    private let importedAtKey = "health.importedAt.v1"

    init() {
        restore()
    }

    // MARK: - Import

    func importExport(from url: URL) async {
        state = .importing
        lastParseSeconds = nil

        // A file handed over by the document picker lives outside the sandbox, so access
        // has to be claimed explicitly and released whether or not parsing succeeds.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let started = Date()
        let days = windowDays

        do {
            // Parsing hundreds of megabytes takes seconds on a Mac and longer on a
            // phone, so it must not run on the main actor.
            let parsed = try await Task.detached(priority: .userInitiated) {
                try HealthExportParser.parse(contentsOf: url, days: days)
            }.value

            lastParseSeconds = Date().timeIntervalSince(started)
            snapshot = parsed

            let importedAt = Date()
            state = .imported(importedAt)
            persist(parsed, importedAt: importedAt)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Discards the imported data. The export file was never kept, so this is all
    /// there is to forget.
    func clear() {
        snapshot = nil
        state = .empty
        lastParseSeconds = nil
        defaults.removeObject(forKey: snapshotKey)
        defaults.removeObject(forKey: importedAtKey)
    }

    // MARK: - Persistence
    //
    // The snapshot is saved so the app opens with data instead of an empty screen.
    // This is current state, not history: each import replaces it, nothing accumulates,
    // and the export file is still never written anywhere (hard rules 5 and 6).

    private func persist(_ snapshot: HealthSnapshot, importedAt: Date) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.set(importedAt, forKey: importedAtKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: snapshotKey),
              let decoded = try? JSONDecoder().decode(HealthSnapshot.self, from: data)
        else { return }

        snapshot = decoded
        state = .imported(defaults.object(forKey: importedAtKey) as? Date ?? Date())
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> String {
        if let parseError = error as? HealthExportParser.ParseError {
            return parseError.errorDescription ?? "Couldn't read that file."
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return "Vita couldn't open that file. Try choosing it again from Files."
        }
        return error.localizedDescription
    }
}
