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

    @State private var llm = MLXLLMService()
    @State private var output = ""
    @State private var isGenerating = false

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
                VStack(alignment: .leading, spacing: 24) {
                    modelSection
                    Divider()
                    factSheetSection
                }
                .padding()
            }
        }
    }

    // MARK: - M1 debug

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)

            switch llm.state {
            case .idle:
                Button("Load Qwen3-1.7B") {
                    Task { await llm.load() }
                }
                .buttonStyle(.borderedProminent)

                Text("Downloads about 1 GB the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case let .loading(fraction):
                ProgressView(value: fraction) {
                    Text(fraction > 0 ? "Downloading…" : "Loading…")
                        .font(.caption)
                }
                .tint(.accentColor)

            case .ready:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready").font(.subheadline)
                }

                Button("Say hello in one sentence") {
                    Task { await sayHello() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)

            case let .failed(message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.subheadline)
                }
                Button("Retry") {
                    Task { await llm.load() }
                }
                .buttonStyle(.bordered)
            }

            if !output.isEmpty {
                Text(output)
                    // Dimmed while streaming: the text isn't final, and nothing is safe
                    // to present as an answer until Guardrail has seen the whole thing.
                    .foregroundStyle(isGenerating ? .secondary : .primary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let line = metricsLine {
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metricsLine: String? {
        let m = llm.metrics
        var parts: [String] = []
        if let load = m.loadSeconds { parts.append(String(format: "load %.1fs", load)) }
        if let rate = m.chunksPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
        if let peak = m.peakMemoryBytes {
            parts.append(String(format: "peak %.0f MB", Double(peak) / 1_048_576))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sayHello() async {
        output = ""
        isGenerating = true
        defer { isGenerating = false }

        do {
            for try await chunk in llm.generate(
                system: "You are a concise assistant.",
                user: "Say hello in one sentence. /no_think",
                maxTokens: 64
            ) {
                output += chunk
            }
            // Strip any <think> block before showing the result — Qwen3 emits one even
            // with /no_think. VitaCore already knows how.
            output = InsightParser.clean(output)
        } catch {
            output = "Generation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Fact sheet

    private var factSheetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fact sheet")
                .font(.headline)

            Text("The only thing the model ever sees. Every number computed in Swift.")
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
