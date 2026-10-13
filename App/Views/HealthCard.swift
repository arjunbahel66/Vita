import SwiftUI
import UniformTypeIdentifiers
import VitaCore

/// Four metric tiles and the import control.
struct HealthCard: View {
    let service: HealthExportService
    @State private var isPickingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch service.state {
            case .empty:
                emptyState

            case .importing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading your export…").font(.caption)
                }
                Text("Large exports take a while. Nothing is copied to the app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            case let .imported(date):
                if let snapshot = service.snapshot {
                    tiles(for: snapshot)
                    footer(importedAt: date, snapshot: snapshot)
                }

            case let .failed(message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.subheadline)
                }
                Button("Choose a file") { isPickingFile = true }
                    .buttonStyle(.bordered)
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await service.importExport(from: url) }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("Health").font(.headline)
            Spacer()
            if case .imported = service.state {
                Button("Re-import") { isPickingFile = true }
                    .font(.caption)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No health data yet.")
                .font(.subheadline)

            // Spelled out because the export is buried and the uncompress step is easy
            // to miss — the picker only accepts export.xml, not the zip.
            VStack(alignment: .leading, spacing: 3) {
                Text("In the Health app: tap your profile picture, scroll to the bottom, "
                     + "then Export All Health Data.")
                Text("Save the zip to Files, long-press it, and choose Uncompress.")
                Text("Then come back and pick export.xml.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Import Health Export") { isPickingFile = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func tiles(for snapshot: HealthSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(
                title: "Steps",
                value: snapshot.steps.average.map { FactSheet.grouped($0) } ?? "—",
                unit: "avg/day",
                series: snapshot.steps
            )
            MetricTile(
                title: "Sleep",
                value: snapshot.sleepHours.average.map { FactSheet.hoursAndMinutes($0) } ?? "—",
                unit: "avg/night",
                series: snapshot.sleepHours
            )
            MetricTile(
                title: "Resting HR",
                value: snapshot.restingHeartRate.average.map { "\(Int($0.rounded()))" } ?? "—",
                unit: "bpm",
                series: snapshot.restingHeartRate
            )
            MetricTile(
                title: "Weight",
                value: snapshot.weightKilograms.latest.map { String(format: "%.1f", $0.value) } ?? "—",
                unit: "kg latest",
                series: snapshot.weightKilograms
            )
        }
    }

    private func footer(importedAt: Date, snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Imported \(importedAt.formatted(date: .abbreviated, time: .shortened))")
            if let seconds = service.lastParseSeconds {
                Text(String(format: "Parsed in %.1f s. The export file was not kept.", seconds))
            } else {
                Text("The export file was not kept.")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// One metric: its 30-day average, a trend arrow, and how complete the data is.
private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                trendArrow
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()

            Text(coverage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Coverage is shown rather than hidden: an average over 15 of 30 nights means
    /// something different from an average over all of them.
    private var coverage: String {
        guard series.hasData else { return "no data" }
        return "\(unit) · \(series.daysWithData)d"
    }

    @ViewBuilder
    private var trendArrow: some View {
        switch series.trend {
        case let .up(percent):
            Label("\(Int(percent.rounded()))%", systemImage: "arrow.up.right")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case let .down(percent):
            Label("\(Int(percent.rounded()))%", systemImage: "arrow.down.right")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .stable:
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .insufficientData:
            EmptyView()
        }
    }
}
