import Foundation

/// Where the model is in its lifecycle.
///
/// `failed` is a first-class state rather than a thrown error that disappears: the
/// ~1 GB first-launch download can fail for ordinary reasons — no network, airplane
/// mode, out of disk, backgrounded mid-download — and the user needs a Retry button
/// rather than a dead screen. See CLAUDE.md section 4.4.
enum LLMState: Equatable {
    case idle
    case loading(Double)
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// What a run of the model cost. M1 exists to produce these numbers.
struct GenerationMetrics: Equatable {
    var loadSeconds: Double?
    var generateSeconds: Double?
    var chunks: Int = 0
    var peakMemoryBytes: Int?

    /// Chunks per second. MLX streams a chunk per token in practice, so this is a
    /// close stand-in for tokens/sec — close enough to tell "usable" from "painful".
    var chunksPerSecond: Double? {
        guard let generateSeconds, generateSeconds > 0, chunks > 0 else { return nil }
        return Double(chunks) / generateSeconds
    }
}

/// The boundary between Vita and the model.
///
/// Everything above this line is tested Swift; everything below is a 1.7B model that
/// can be wrong in ways nothing can check. Keeping it behind a protocol is what lets
/// the model be swapped — Qwen3 for Gemma or Llama — without touching a caller.
@MainActor
protocol LLMService: AnyObject {
    var state: LLMState { get }
    var metrics: GenerationMetrics { get }

    /// Downloads the weights if needed and loads them. Never throws — failure lands
    /// in `state` so the UI can offer Retry.
    func load() async

    /// Streams the reply. The caller is responsible for running `Guardrail` on the
    /// finished text — not on the chunks, because a rule like "no dosages" cannot be
    /// judged from half a sentence.
    func generate(system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}
