import SwiftUI
import VitaCore

/// Four lab rows: value, editable reference range, and a confirm toggle.
///
/// The ranges are prefilled with common defaults but are meant to be edited — they
/// vary between laboratories, and classification compares against whatever is printed
/// on the user's own report (CLAUDE.md section 4.2).
struct LabsCard: View {
    @Bindable var store: LabsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 10) {
                ForEach($store.entries) { $entry in
                    LabRow(entry: $entry)
                }
            }

            panelDateRow

            Text("Only confirmed values are shown to the model. Ranges differ between "
                 + "labs — edit them to match what's printed on your report.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack {
            Text("Labs").font(.headline)
            Spacer()
            Text("\(store.confirmedCount) of \(store.entries.count) confirmed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var panelDateRow: some View {
        HStack {
            Toggle(isOn: $store.hasPanelDate) {
                Text("Test date").font(.subheadline)
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Text("Test date").font(.subheadline)

            Spacer()

            if store.hasPanelDate {
                // One date for the panel: the four values come from one blood draw,
                // so separate pickers would just be four ways to disagree.
                DatePicker("", selection: $store.panelDate, displayedComponents: .date)
                    .labelsHidden()
            } else {
                Text("not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LabRow: View {
    @Binding var entry: LabEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.kind.displayName)
                    .font(.subheadline.weight(.medium))
                    .frame(width: 92, alignment: .leading)

                TextField("value", text: $entry.valueText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .monospacedDigit()

                Text(entry.kind.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Spacer(minLength: 0)

                Toggle("", isOn: $entry.isConfirmed)
                    .labelsHidden()
                    .disabled(!entry.canConfirm)
            }

            HStack(spacing: 8) {
                Text("range")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)

                TextField("low", text: $entry.lowText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.caption)

                Text("–").font(.caption).foregroundStyle(.secondary)

                TextField("high", text: $entry.highText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.caption)

                Spacer(minLength: 0)

                classification
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Clearing the value un-confirms the row, so a confirmed-but-empty entry can't
        // exist. The toggle is the only gate on what the model sees.
        .onChange(of: entry.valueText) { _, _ in
            if !entry.canConfirm { entry.isConfirmed = false }
        }
    }

    /// Neutral wording only — where the number sits, never what it might mean.
    /// CLAUDE.md hard rule 2.
    @ViewBuilder
    private var classification: some View {
        if let lab = entry.labValue {
            switch lab.classification {
            case .above:
                Text("above range").font(.caption2).foregroundStyle(.orange)
            case .below:
                Text("below range").font(.caption2).foregroundStyle(.orange)
            case .within:
                Text("within range").font(.caption2).foregroundStyle(.secondary)
            case .unknown:
                Text("no range").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
