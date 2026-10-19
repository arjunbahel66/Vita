import SwiftUI
import VitaCore

/// Generates the summary, suggestions and doctor questions.
///
/// Owns the model's lifecycle as far as the user sees it: loading, progress, failure
/// and retry all surface here rather than in a separate debug section.
struct InsightsCard: View {
    let llm: MLXLLMService
    let factSheet: String?

    @State private var state: InsightsState = .idle

    enum InsightsState {
        case idle
        /// Raw text as it streams. Shown dimmed — nothing is final until Guardrail
        /// has seen the whole thing.
        case streaming(String)
        case ready(Insights)
        /// Decoding failed. The cleaned text is shown rather than an error, since a
        /// response that missed the shape is still worth reading.
        case unstructured(String)
        case blocked
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights").font(.headline)

            if factSheet == nil {
                Text("Import a Health export first — the model only ever sees the fact sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                controls
                content
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch llm.state {
        case .idle, .ready:
            HStack(spacing: 10) {
                Button(isBusy ? "Generating…" : "Generate insights") {
                    Task { await generate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                if case .ready = llm.state {} else {
                    Text("Loads the model first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case let .loading(progress):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction) { Text("Downloading model…").font(.caption) }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(progress.updates > 0 ? "Downloading model…" : "Loading model…")
                            .font(.caption)
                    }
                }
                if let summary = progress.byteSummary {
                    Text(summary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.subheadline)
                }
                Button("Retry") { Task { await generate() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var isBusy: Bool {
        if case .streaming = state { return true }
        if case .loading = llm.state { return true }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()

        case let .streaming(text):
            if !text.isEmpty {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

        case let .ready(insights):
            sections(insights)
            generatedOnDevice

        case let .unstructured(text):
            VStack(alignment: .leading, spacing: 6) {
                Text("The model didn't return the expected shape. Its answer:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            generatedOnDevice

        case .blocked:
            Text(Guardrail.fallbackMessage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sections(_ insights: Insights) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Summary") {
                Text(insights.summary).font(.callout)
            }
            section("Suggestions") {
                numbered(insights.suggestions)
            }
            section("Questions for my doctor") {
                numbered(insights.doctorQuestions)
            }
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numbered(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(item).font(.callout)
                }
            }
        }
    }

    private var generatedOnDevice: some View {
        HStack(spacing: 4) {
            Text("Generated on-device.")
            if let rate = llm.metrics.chunksPerSecond {
                Text(String(format: "· %.0f tok/s", rate))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Generation

    private func generate() async {
        guard let factSheet else { return }

        if !llm.state.isReady {
            await llm.load()
            guard llm.state.isReady else { return }
        }

        state = .streaming("")
        var raw = ""

        do {
            for try await chunk in llm.generate(
                system: PromptBuilder.systemPrompt,
                user: PromptBuilder.insightsTask(factSheet: factSheet),
                maxTokens: PromptBuilder.insightsMaxTokens
            ) {
                raw += chunk
                state = .streaming(raw)
            }
        } catch {
            state = .failed("Generation failed: \(error.localizedDescription)")
            return
        }

        state = finish(raw)
    }

    /// Guardrail runs here, on the finished text — never on chunks. A rule like
    /// "no dosages" cannot be judged from half a sentence. CLAUDE.md section 4.7.
    private func finish(_ raw: String) -> InsightsState {
        switch InsightParser.parse(raw) {
        case let .parsed(insights):
            guard let safe = Guardrail.filter(insights) else { return .blocked }
            return .ready(safe)

        case let .raw(text):
            guard Guardrail.isSafe(text) else { return .blocked }
            return text.isEmpty
                ? .failed("The model returned nothing. Try again.")
                : .unstructured(text)
        }
    }
}
