import Foundation
import VitaCore

/// Where the imported data stands.
enum ImportState: Equatable {
    case empty
    case importing
    case imported(Date)
    case failed(String)
}

/// Supplies the 30-day snapshot.
///
/// Vita does not read HealthKit — see CLAUDE.md section 2.1. The user exports their
/// data from the Health app and hands Vita the file, so this protocol is about
/// importing rather than querying.
@MainActor
protocol HealthService: AnyObject {
    var snapshot: HealthSnapshot? { get }
    var state: ImportState { get }

    /// Parses an `export.xml` chosen by the user. Never throws — failure lands in
    /// `state` so the card can explain it.
    func importExport(from url: URL) async
}

/// Realistic data for previews and for working on the UI before an export exists.
@Observable
@MainActor
final class MockHealthService: HealthService {
    private(set) var snapshot: HealthSnapshot? = .sample()
    private(set) var state: ImportState = .imported(Date())

    func importExport(from url: URL) async {
        state = .importing
        try? await Task.sleep(for: .milliseconds(600))
        snapshot = .sample()
        state = .imported(Date())
    }
}
