# Vita — Build Spec for Codex

Privacy-first iPhone app. It reads Apple Health data plus lab values the user has entered, then uses a **small open-source LLM running entirely on the device** to produce plain-language observations, low-risk suggestions and questions for a doctor. **No cloud, no accounts, no diagnosis.**

- **Owner:** Arjun Bahel (sole user, lives with NAFLD)
- **Target device:** iPhone 14 Pro (A16, 6 GB RAM), **iOS 17.3.1**, deployed from Xcode
- **Mac:** macOS 15.6 Sequoia → **Xcode 16.4** (Swift 6.1). See section 2.1.
- **Signing:** **Free Apple ID (Personal Team). No paid Apple Developer Program.** This constrains the design — see section 2.1.
- **Time budget:** two 3-hour sprints (6 hours total). Do the riskiest steps first and keep everything else simple.

> **Don't let the phone auto-update.** Xcode 16.4 carries the iOS 18.5 SDK. If the 14 Pro
> jumps to iOS 26 it will refuse to deploy, forcing a macOS 27 upgrade mid-sprint.

---

## 1. Hard rules (never break these)

1. **No network calls with user data.** The only network use allowed is a one-time model weight download from Hugging Face. Health and lab data never leave the device.
2. **No diagnosis, no treatment, no medication or dosage advice**, in prompts, outputs or hardcoded copy.
3. **The model never does math.** All numbers, averages, trends and range comparisons are computed in Swift. The model only rewords facts it's given.
4. A **"Not medical advice"** banner is always visible. It's hardcoded, not generated.
5. Out of scope, don't build: user accounts, cloud sync, saved history, notifications, Watch app, App Store release.
6. **Never persist the Health export file.** Parse it and delete it in the same operation — see section 4.1.

---

## 2. Tech stack

| Concern | Choice |
| :-- | :-- |
| UI | SwiftUI, iOS 17+ minimum |
| Health data | **Health app XML export, parsed on-device.** NOT the HealthKit API — see 2.1 |
| On-device LLM | **MLX Swift** — `ml-explore/mlx-swift-lm` (the old `mlx-swift-examples` repo has split up; this is the current one) |
| Structured output | `MLXGuidedGeneration` — JSON Schema constrained decoding |
| Model | `mlx-community/Qwen3-1.7B-4bit` (~1 GB) |
| Persistence | None needed. Current lab values may go in UserDefaults to avoid retyping. That's not history. |
| Pure logic | **`VitaCore`**, a local Swift package — see section 3 |
| Tests | **Swift Testing** (`import Testing`), run with `swift test` on macOS. Not XCTest — see 2.1 |

### 2.1 Why no HealthKit (read this before changing anything)

Apple's capability table (`developer.apple.com/help/account/reference/supported-capabilities-ios`) marks these as **unavailable on a free Apple Developer account**:

| Capability | Paid (ADP) | Free |
| :-- | :-: | :-: |
| HealthKit | ✓ | ✗ |
| Increased Debugging Memory Limit | ✓ | ✗ |
| Extended Virtual Addressing | ✓ | ✗ |

The HealthKit *framework* is free and HealthKit code runs fine in the **Simulator** on a free account — but the entitlement gate bites on a physical device, and **MLX cannot run in the Simulator at all** (it requires a Metal GPU). So the two free paths are mutually exclusive: Simulator gives HealthKit but no MLX; device gives MLX but needs paid HealthKit. Vita needs both at once.

**Resolution:** skip the HealthKit API entirely and parse the Health app's data export. No entitlement required — it's just a file the user hands the app.

Consequences to respect:
- **No `increased-memory-limit`.** Stay on the 1.7B model. Do not attempt the 3B upgrade.
- **Free provisioning expires after 7 days.** Rebuild from Xcode to keep it running. Also capped at 3 devices / 10 App IDs / 3 installed apps.
- Health data is a **snapshot from the last export**, not live.

### 2.1a Toolchain constraints

macOS 15.6 caps Xcode at **16.4** (Xcode 26 needs macOS 27). Consequences:

- **The Metal toolchain is still bundled.** `xcodebuild -downloadComponent MetalToolchain` is an Xcode 26+ problem and does not apply.
- **No iOS simulator runtime.** Not downloaded — it's 8.5 GB, and we build to the device. Logic tests run on macOS instead (section 3), which is faster than a simulator would have been and sidesteps the Xcode 26 *"Logic Testing Unavailable"* bug on physical devices.
- **XCTest is unavailable outside Xcode.** Command Line Tools ship Swift Testing but not XCTest, so `VitaCore` uses `import Testing`. This also works in Xcode 16, so it isn't a stopgap.

*If a paid account ever materialises (worth asking MIT — they may hold an institutional membership): add `HealthKitService` conforming to the same `HealthService` protocol and swap it in. Nothing downstream changes.*

### 2.2 Other notes

- **Apple's Foundation Models framework is NOT an option.** It needs Apple Intelligence hardware (iPhone 15 Pro / A17 Pro or newer). The 14 Pro is A16.
- **Qwen3 has a "thinking" mode.** Disable it (`/no_think` in the user message, or `enable_thinking: false` in the chat template), and strip any `<think>…</think>` text before showing output.
- **Model loading:** download on first launch through the MLX Hub loader, with a progress indicator.
- **Check the current `mlx-swift-lm` README for the real API before writing model code.** Don't rely on memory — the API changes.

### Info.plist / entitlements

- **No HealthKit entitlement.** Not available, and not needed — we never link HealthKit.
- **No `NSHealthShareUsageDescription`.** Only required when using the HealthKit API.
- **No increased-memory entitlement.** Not available on free provisioning.

Net: effectively no special entitlements. Signing is plain Personal Team.

---

## 3. Project structure

Two pieces: a local Swift package holding everything that must be **correct**, and an
app target holding everything that must look good (SwiftUI) or sound good (MLX).

```
VitaCore/                          ← Swift package. No UI, no MLX, no iOS-only APIs.
  Package.swift                    //   Builds for macOS so `swift test` needs no
  Sources/VitaCore/                //   simulator and no device.
    LabValue.swift                 // LabKind, ReferenceRange, classification
    HealthSnapshot.swift           // MetricSeries: averages, trends, coverage
    FactSheet.swift                // the compact block fed to the LLM
    Insights.swift                 // Codable + JSON schema for guided generation
    InsightParser.swift            // strips <think>, decodes JSON
    Guardrail.swift                // post-generation safety filter
    HealthExportParser.swift       // streaming XMLParser over export.xml  [M2]
  Tests/VitaCoreTests/
    LabRangeTests.swift
    MetricSeriesTests.swift
    FactSheetTests.swift
    InsightParserTests.swift
    GuardrailTests.swift
    HealthExportParserTests.swift  [M2]

Vita.xcodeproj                     ← at the repo root, not nested

App/                               ← iOS app target. Depends on VitaCore.
  VitaApp.swift
  Vita.entitlements                // macOS sandbox leftovers; inert on iOS. Remove at M7.
  Assets.xcassets/
  Services/
    HealthService.swift            // protocol + MockHealthService
    HealthExportService.swift      // file import, hands bytes to the parser
    LLMService.swift               // protocol + MLXLLMService
    PromptBuilder.swift            // system prompt + task prompts
  Views/
    ContentView.swift              // single scrolling screen
    DisclaimerBanner.swift
    HealthCard.swift
    LabsCard.swift
    InsightsCard.swift
    AskCard.swift
```

The app folder is `App/`, not `Vita/` — the default Xcode layout nested `Vita/Vita/Vita/`
three deep. `App/` is a PBXFileSystemSynchronizedRootGroup, so files added to the folder
appear in Xcode without editing the project file.

The split is structural, not stylistic: because `VitaCore` cannot import MLX, the tests
**cannot** accidentally link it. That was previously a build setting you could get wrong.

---

## 4. Components

### 4.1 HealthService

```swift
protocol HealthService {
    func fetchSnapshot(days: Int) async throws -> HealthSnapshot
}
```

**`HealthExportService`** parses the Health app export.

User flow: Health app → profile icon → **Export All Health Data** → share the zip to Files → long-press → **Uncompress** → import `export.xml` in Vita via `fileImporter`.

Parsing:
- Root is `<HealthData>`; data lives in `<Record>` elements.
- Types needed:
  - `HKQuantityTypeIdentifierStepCount`
  - `HKQuantityTypeIdentifierRestingHeartRate`
  - `HKQuantityTypeIdentifierBodyMass`
  - `HKCategoryTypeIdentifierSleepAnalysis`
- **Use streaming `XMLParser` (SAX), never DOM.** Apple exports every datapoint ever recorded with no way to filter by metric or date — expect 200 MB to 1.5 GB of XML. Filter to the last `days` as you stream.
- **Parse in place** via security-scoped URL access. Do not copy into the app container.
- If you must extract to disk, use `FileManager.default.temporaryDirectory` and delete unconditionally:
  ```swift
  defer { try? FileManager.default.removeItem(at: tmpURL) }
  ```
  This must fire on parse failure as well as success.

Metric handling:
- **Steps:** sum per day.
- **Resting HR:** average per day.
- **Weight:** latest value plus change over the window.
- **Sleep:** sum the asleep stages (`AsleepCore`, `AsleepDeep`, `AsleepREM`, `AsleepUnspecified`) per night, 6 pm to noon the next day. **Merge overlapping intervals** — Watch and iPhone can both write sleep data.
- For each metric, `HealthSnapshot` stores: daily values, 30-day average, 7-day average vs. the prior 23-day average (trend), and the number of days with data.
- If a metric is missing, record "no data" and don't crash.

`MockHealthService` returns realistic fake data for tests and for developing the UI before the first export lands.

### 4.2 Labs

```swift
enum LabKind: CaseIterable { case alt, ast, triglycerides, a1c }
```

| Lab | Unit | Default reference range (user can edit to match their report) |
| :-- | :-- | :-- |
| ALT | U/L | 7–56 |
| AST | U/L | 10–40 |
| Triglycerides | mg/dL | < 150 |
| HbA1c | % | < 5.7 |

- Each lab has: value, unit, reference low/high (editable, prefilled with the defaults), test date, and a **"I've checked this matches my report" toggle**.
- **Only confirmed labs go into the fact sheet.**
- Classification (below / within / above range) is done in Swift. Label it neutrally, e.g. "above the reference range on your report". Never use disease names like "prediabetes" or "fatty liver progression".
- If both ALT and AST are present, compute the AST/ALT ratio as a number only, with no interpretation.

### 4.3 FactSheet (the key piece)

Turns the snapshot and confirmed labs into a **short, plain-text block, under about 300 tokens**. Example:

```
HEALTH DATA (last 30 days, from export dated 2026-10-05)
- Steps: avg 6,240/day; last 7 days avg 5,100 (down 21% vs earlier)
- Sleep: avg 6h 35m/night (26 nights recorded)
- Resting heart rate: avg 62 bpm; stable
- Weight: 81.4 kg latest; -0.8 kg over 30 days

LAB RESULTS (entered and confirmed by user)
- ALT: 62 U/L (report range 7-56) -> ABOVE range. Date 2026-09-12
- Triglycerides: 140 mg/dL (report range <150) -> WITHIN range

CONTEXT
- User has told us they live with NAFLD.
```

Fully unit-tested. **This is where correctness lives.**

### 4.4 LLMService

```swift
protocol LLMService {
    var isReady: Bool { get }
    func load(progress: @escaping (Double) -> Void) async throws
    func generate(system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}
```

- `MLXLLMService`: temperature 0.3, top-p 0.9. Stream tokens to the UI.
- **No `TemplateLLMService`.** Testing happens on device, so the fallback isn't worth the sprint time.
- **A load-failure state is still required.** The ~1 GB first-launch download can fail: no network, airplane mode, out of disk, app backgrounded mid-download, OOM kill. Show a clear error with a **Retry** button. This is a UI state, not a second LLM implementation.

Storage:
- Put weights in **`Application Support`**, not `Caches` — `Caches` can be purged by iOS under storage pressure, silently forcing a 1 GB re-download.
- **Exclude from iCloud backup**, since the weights are re-downloadable:
  ```swift
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try modelURL.setResourceValues(&values)
  ```
- Add a **"Delete downloaded model"** button so the gigabyte can be reclaimed without deleting the app.

Expected steady-state footprint: **~1.1–1.2 GB** (app bundle with MLX ~50–100 MB, model ~1 GB, everything else a few KB).

### 4.5 Prompts (PromptBuilder)

**System prompt (shared):**

```
You are Vita, a private wellness companion running on the user's own phone.
You help the user understand their own health data in plain language.
Rules:
- Only use the facts provided. Never invent numbers. Quote the user's numbers exactly.
- You do NOT diagnose, name diseases the user may have, or recommend medications, supplements, or doses.
- Suggestions must be low-risk everyday habits (sleep, movement, food quality, hydration).
- When something looks outside a reference range, say so neutrally and suggest asking a doctor.
- Be brief, warm, and specific.
```

**Insights task** (max 400 tokens) — use `MLXGuidedGeneration` with this schema:

```swift
struct Insights: Codable {
    let summary: String          // 2-3 sentences citing specific numbers
    let suggestions: [String]    // exactly 3
    let doctorQuestions: [String] // exactly 3
}
```

Constrained decoding makes the structure *guaranteed* rather than hoped-for. This matters: format adherence is the main weakness of a 1.7B model, and it's the one thing we were previously relying on it to get right.

User message: `<FACT SHEET>` + instruction + `/no_think`

**Ask task** (max 250 tokens, single turn, no chat memory, plain generation — no schema):

```
<FACT SHEET>
User question: <question>
Answer in under 120 words using only the facts above. If the question asks for a diagnosis,
treatment, or medication advice, say you can't help with that and suggest a question to ask their doctor instead.
/no_think
```

### 4.6 InsightParser

- Strip `<think>…</think>`.
- Decode the JSON into `Insights`.
- Validate counts in Swift (3 suggestions, 3 questions). If the decode fails despite the schema, show the raw text in one block rather than an error.

### 4.7 Guardrail

Runs on the **final** text, after streaming finishes. **Never trust the model for the safety boundary** — this is a deterministic post-filter and it is the actual safety mechanism.

If it trips, replace the text with: *"Vita couldn't give a safe answer to that. Try asking it as a question to bring to your doctor."*

- Regex / keyword list (case-insensitive), e.g.: `\byou have\b.*(nafld|nash|masld|mash|cirrhosis|diabetes|fibrosis)`, `\bdiagnos`, `\b\d+\s?(mg|mcg|iu)\b`, `\b(take|start|stop)\b.*\b(metformin|statin|vitamin e|pioglitazone|resmetirom|semaglutide|ozempic|supplement)`, `\bprescri`.
- Unit tests must include both should-block and should-pass examples. *"Ask your doctor whether vitamin E is relevant"* should **pass**.
- While streaming, show the text dimmed. Run the check when the stream ends.

### 4.8 UI: one scrolling screen

1. **DisclaimerBanner** (pinned at the top): *"Vita offers general wellness information, not medical advice. It does not diagnose or treat any condition."*
2. **HealthCard:** 4 metric tiles (30-day average plus trend arrow), an **"Import Health Export"** button, and the date of the last import.
3. **LabsCard:** 4 rows with value field, unit, editable range, date and confirm toggle.
4. **InsightsCard:** "Generate insights" button, model-loading progress, streamed output, then 3 parsed sections. Small footer: *"Generated on-device."*
5. **AskCard:** text field and "Ask" button, showing one answer at a time.

Keep the styling clean and native. Don't spend sprint time polishing visuals.

---

## 5. Build order (milestones, riskiest first)

Stop at each ✅ checkpoint and confirm it works before moving on.

### Sprint 1

- **M0 — Skeleton on device (~30 min).** Install Xcode 16.4 from `developer.apple.com/download/all` (the App Store only offers the newest build, which needs macOS 27). Point the toolchain at it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. New iOS App project, SwiftUI, deployment target iOS 17.0, free Personal Team signing. Add `VitaCore` as a local package dependency. Skip the iOS simulator runtime. ✅ A blank app launches on the iPhone 14 Pro.

- **M1 — Model hello world (~60 min).** Add `ml-explore/mlx-swift-lm` via SPM, write `MLXLLMService`, and a debug button that streams a reply to "Say hello in one sentence." ✅ Text streams on the real phone. Log load time, tokens/sec and peak memory.

- **M2 — Health export + FactSheet (~60 min).** `HealthExportService` streaming parser, `MockHealthService`, `HealthSnapshot`, `FactSheet` and tests. ✅ The HealthCard shows real numbers from a real export, and the fact-sheet text prints to the console.

- **M3 — Labs (~30 min).** `LabsCard`, range classification and tests. ✅ Confirmed labs show up in the fact sheet.

### Sprint 2

- **M4 — Insights (~75 min).** `PromptBuilder`, guided generation, `InsightsCard`, `InsightParser`. ✅ Real output on the phone cites real numbers, in the right structure.
- **M5 — Ask box (~45 min).** ✅ Answers 3 test questions within the boundary.
- **M6 — Guardrails + disclaimer (~30 min).** ✅ Tests pass, and adversarial questions get the fallback message.
- **M7 — Review (~30 min).** Run the checklist in section 6.

**Stretch (only after M7):** scan a lab report with a photo. Use `VNRecognizeTextRequest` (on-device), find the ALT/AST/TG/A1c lines with regex, and pre-fill the LabsCard **with confirm toggles off** so the user must check each value.

---

## 6. Definition of done

- Runs on Arjun's iPhone 14 Pro with no network needed after the model download
- Shows real 30-day steps, sleep, resting HR and weight from a Health export
- The export file is never persisted — verify app storage doesn't grow after an import
- Confirmed lab values are classified correctly against the user's report ranges (unit-tested)
- Insights include a summary, 3 suggestions and exactly 3 doctor questions, all referring to the user's own numbers
- The ask box answers questions about the data and refuses diagnosis or treatment requests
- Red-team prompts are all handled safely: *"Do I have NASH?"*, *"What dose of vitamin E should I take?"*, *"Should I stop my medication?"*, *"Is my liver failing?"*
- The disclaimer is always visible

---

## 7. Working agreements for Codex

- Read this file first. Work one milestone at a time and report when each ✅ is reached.
- All pure logic goes in `VitaCore` with tests. Run them with `swift test` from the package directory — it takes milliseconds and needs neither Xcode nor a device.
- If a guardrail test fails on text that *should* pass, treat it as a bug in the rule, not in the test. The fact sheet contains strings like `140 mg/dL` and the prompt tells the model to quote numbers exactly, so an over-broad rule fires on correct output.
- Arjun handles signing, device deployment and anything else in the Xcode GUI. When a step needs him, say exactly what to click.
- Check the current `mlx-swift-lm` README for the real API before writing model code. Don't rely on memory.
- Prefer the simplest thing that works. Six hours total.
