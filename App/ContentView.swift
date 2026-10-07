//
//  ContentView.swift
//  Vita
//

import SwiftUI
import VitaCore

struct ContentView: View {
    // Sample data for now. M2 replaces this with a real Health export.
    private let snapshot = HealthSnapshot.sample()
    private let labs = LabValue.samples()

    private var factSheet: String {
        FactSheet.build(
            snapshot: snapshot,
            labs: labs,
            context: ["User has told us they live with NAFLD."]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DisclaimerBanner()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Fact sheet")
                        .font(.headline)

                    Text("This is the only thing the model will ever see. Every number here was computed in Swift.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                .padding()
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
