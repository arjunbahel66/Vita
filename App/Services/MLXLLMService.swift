import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// Runs Qwen3 on the phone's GPU through MLX.
///
/// Pinned to mlx-swift-lm 3.31.4 — see CLAUDE.md section 2.1a for why 3.32 is out of
/// reach, and why `MLXGuidedGeneration` is therefore unavailable.
///
/// This cannot run in the Simulator. MLX needs a Metal GPU, and the Simulator has none;
/// the code compiles there but `load()` will fail at runtime.
@Observable
@MainActor
final class MLXLLMService: LLMService {
    private(set) var state: LLMState = .idle
    private(set) var metrics = GenerationMetrics()

    private var container: ModelContainer?

    /// Hugging Face repo id. Swapping models is this one line — see CLAUDE.md 2.2.
    private let modelID = "mlx-community/Qwen3-1.7B-4bit"

    /// Cap on MLX's buffer-reuse cache.
    ///
    /// MLX keeps freed GPU buffers around so it can reuse them instead of reallocating
    /// between operations. Starving this cache is slow: the first device run used a
    /// 32 MB cap and managed only 3.5 tokens/sec.
    ///
    /// That cap was set defensively, before anything was measured. Measurement showed
    /// peak GPU use of 978 MB against roughly 2–3 GB available on a 6 GB device, so
    /// there is over a gigabyte spare and no reason to be that frugal. 256 MB buys
    /// back the reuse without approaching the ceiling that would get the app killed.
    ///
    /// Revisit this if peak memory ever climbs near 1.8 GB.
    private let gpuCacheLimit = 256 * 1024 * 1024

    // MARK: - Loading

    func load() async {
        guard !state.isReady else { return }

        MLX.Memory.cacheLimit = gpuCacheLimit
        state = .loading(.unknown)
        let started = Date()
        var updates = 0

        do {
            let configuration = ModelConfiguration(id: modelID)

            // First launch downloads ~1 GB; later launches read from disk and report
            // almost nothing. Whatever the downloader can tell us is passed through
            // verbatim — including "I don't know the total" — so the UI can be honest
            // rather than showing a motionless bar.
            let loaded = try await #huggingFaceLoadModelContainer(
                configuration: configuration
            ) { progress in
                let known = progress.totalUnitCount > 0
                let snapshot = LoadProgress(
                    fraction: known ? progress.fractionCompleted : nil,
                    completedBytes: progress.completedUnitCount > 0 ? progress.completedUnitCount : nil,
                    totalBytes: known ? progress.totalUnitCount : nil
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    updates += 1
                    var next = snapshot
                    next.updates = updates
                    self.state = .loading(next)
                }
            }

            container = loaded
            metrics.loadSeconds = Date().timeIntervalSince(started)
            metrics.peakMemoryBytes = MLX.Memory.peakMemory
            state = .ready
        } catch {
            container = nil
            state = .failed(Self.describe(error))
        }
    }

    /// Frees the weights without deleting the download. Call this on a memory warning
    /// so iOS reclaims the GPU allocation instead of killing the app.
    func unload() {
        container = nil
        MLX.Memory.clearCache()
        state = .idle
    }

    // MARK: - Generation

    func generate(system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let container else {
                    continuation.finish(throwing: LLMError.notLoaded)
                    return
                }

                let parameters = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: 0.3,
                    topP: 0.9
                )

                let session = ChatSession(
                    container,
                    instructions: system,
                    generateParameters: parameters
                )

                let started = Date()
                var chunks = 0

                do {
                    for try await chunk in session.streamResponse(to: user) {
                        chunks += 1
                        continuation.yield(chunk)
                    }
                    self.metrics.generateSeconds = Date().timeIntervalSince(started)
                    self.metrics.chunks = chunks
                    self.metrics.peakMemoryBytes = MLX.Memory.peakMemory
                    continuation.finish()
                } catch {
                    self.metrics.generateSeconds = Date().timeIntervalSince(started)
                    self.metrics.chunks = chunks
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Errors

    enum LLMError: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded: "The model hasn't finished loading yet."
            }
        }
    }

    /// Turns MLX and networking errors into something a person can act on.
    private static func describe(_ error: Error) -> String {
        let raw = error.localizedDescription
        let ns = error as NSError

        if ns.domain == NSURLErrorDomain {
            return "Couldn't download the model. Check your connection and try again."
        }
        if raw.localizedCaseInsensitiveContains("space") {
            return "Not enough storage for the model (about 1 GB needed)."
        }
        return raw
    }
}
