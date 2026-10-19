//
//  ContentView.swift
//  Vita
//

import SwiftUI
import VitaCore

struct ContentView: View {
    @State private var health = HealthExportService()
    @State private var labs = LabsStore()
    @State private var llm = MLXLLMService()
    @State private var showsFactSheet = false

    /// Nil until an export has been imported. The fact sheet is the model's whole view,
    /// so there is nothing to generate from before then.
    private var factSheet: String? {
        guard let snapshot = health.snapshot else { return nil }
        return FactSheet.build(
            snapshot: snapshot,
            labs: labs.confirmedLabValues,
            context: ["User has told us they live with NAFLD."]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DisclaimerBanner()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HealthCard(service: health)
                    Divider()
                    LabsCard(store: labs)
                    Divider()
                    InsightsCard(llm: llm, factSheet: factSheet)
                    Divider()
                    factSheetSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// A development view of the model's input, collapsed by default.
    ///
    /// Not part of the product, but worth keeping reachable: it is the only way to see
    /// exactly what the model was told, which is what makes a wrong answer debuggable.
    private var factSheetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showsFactSheet) {
                if let factSheet {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(factSheet)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("\(factSheet.count) characters — budget is ~1200")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else {
                    Text("Import a Health export and this fills in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What the model sees").font(.subheadline.weight(.medium))
                    Text("Every number computed in Swift")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Hardcoded, never generated. CLAUDE.md hard rule 4.
struct DisclaimerBanner: View {
    var body: some View {
        Text("Vita offers general wellness information, not medical advice. It does not diagnose or treat any condition.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
    }
}

#Preview {
    ContentView()
}
