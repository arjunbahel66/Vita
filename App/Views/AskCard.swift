import SwiftUI
import VitaCore

/// Ask a question about your own data.
///
/// Single turn, no memory: each question sees the fact sheet and nothing else. An
/// earlier answer never becomes a fact the model builds on, which matters because the
/// model's own output is the least trustworthy thing in the system.
struct AskCard: View {
    let llm: MLXLLMService
    let factSheet: String?

    @State private var question = ""
    @State private var state: AnswerState = .idle
    @FocusState private var isFocused: Bool

    enum AnswerState {
        case idle
        /// Dimmed while it streams — nothing is final until Guardrail has seen it all.
        case streaming(String)
        case answered(String)
        case blocked
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask").font(.headline)

            if factSheet == nil {
                Text("Import a Health export first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                field
                answer
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Ask about your data…", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 3)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit { ask() }

            Button {
                ask()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!canAsk)
        }
    }

    private var canAsk: Bool {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .streaming = state { return false }
        if case .loading = llm.state { return false }
        return true
    }

    @ViewBuilder
    private var answer: some View {
        switch state {
        case .idle:
            Text("One answer at a time. Questions aren't remembered between asks.")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case let .streaming(text):
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(llmIsLoading ? "Loading model…" : "Thinking…").font(.caption)
                    }
                } else {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case let .answered(text):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                Text("Generated on-device.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

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

    private var llmIsLoading: Bool {
        if case .loading = llm.state { return true }
        return false
    }

    // MARK: - Asking

    private func ask() {
        guard canAsk, let factSheet else { return }
        isFocused = false

        let asked = question
        Task { await run(question: asked, factSheet: factSheet) }
    }

    private func run(question asked: String, factSheet: String) async {
        if !llm.state.isReady {
            state = .streaming("")
            await llm.load()
            guard llm.state.isReady else {
                state = .failed("The model isn't available.")
                return
            }
        }

        state = .streaming("")
        var raw = ""

        do {
            for try await chunk in llm.generate(
                system: PromptBuilder.systemPrompt,
                user: PromptBuilder.askTask(factSheet: factSheet, question: asked),
                maxTokens: PromptBuilder.askMaxTokens
            ) {
                raw += chunk
                state = .streaming(InsightParser.clean(raw))
            }
        } catch {
            state = .failed("Couldn't answer that: \(error.localizedDescription)")
            return
        }

        // Guardrail runs once, on the finished answer. A rule like "no dosages" can't
        // be judged from half a sentence. CLAUDE.md section 4.7.
        let cleaned = InsightParser.clean(raw)
        guard !cleaned.isEmpty else {
            state = .failed("The model returned nothing. Try rephrasing.")
            return
        }
        state = Guardrail.isSafe(cleaned) ? .answered(cleaned) : .blocked
    }
}
