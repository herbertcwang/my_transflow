# Next Step: Swap to Apple Speech Multilingual Recognition

## Goal

Replace Qwen3 ASR with **Apple Speech's Multilingual Recognition** (macOS 26) for live meeting transcription. The app should concurrently recognize **English + Chinese** without any language toggle, and transcribe English to file.

## Why

Qwen3's language detection is confused by mixed EN/ZH conversations. Apple Speech's `SpeechTranscriber` supports multilingual recognition natively — we can configure it to recognize both languages simultaneously with no language switching overhead.

## Current State (after partial changes)

| File | What's been done | What's still needed |
|------|------------------|---------------------|
| `AppSettings.swift` | Live Qwen3 language config removed; UI language/appearance/floating panel/video config kept | Add nothing — clean |
| `ControlBarView.swift` | Language picker + translation toggle removed | Add nothing — clean |
| `TransFlowViewModel.swift` | `TranslationService` removed from live pipeline | **MUST REWRITE** to use Apple SpeechEngine instead of Qwen3ASREngine |
| `ContentView.swift` | Translation parameters removed | Add nothing — clean |
| `FloatingPreviewView.swift` | Translation display removed | Add nothing — clean |
| `SettingsView.swift` | Multi-language sections removed | **MUST REWRITE** to use SpeechModelManager for EN/ZH model status |
| `Qwen3ASREngine.swift` | `languageHint` removed | **Keep as-is** (backup code) |
| `Qwen3ModelManager.swift` | — | **Keep as-is** (backup code) |
| `SpeechEngine.swift` | — | **MUST MODIFY** to support multiple locales concurrently |
| `SpeechModelManager.swift` | — | **Must add** `ensureBilingualModelsReady()` for EN+ZH |
| `Localizable.xcstrings` | Many keys added/removed | May need minor additions |
| `TranslationService.swift` | — | **Keep as-is** (still used by video transcription) |

---

## Implementation Plan

### Step 1: Enhance `SpeechEngine` for multilingual (`SpeechEngine.swift`)

**Problem:** Current `SpeechEngine` takes a single `Locale` and creates one `SpeechTranscriber`.

**Solution:** Create a new `MultilingualSpeechEngine` (or add a class method) that:

- Takes **two locales**: `en-US` + `zh-Hans`
- Creates **two `SpeechTranscriber` instances** (one per locale)
- Creates **one `SpeechAnalyzer`** with both transcribers as modules
- Processes incoming audio once, feeds it to the analyzer
- Consumes results from **both** transcribers' `.results` async sequences
- Merges results into a single `AsyncStream<TranscriptionEvent>`
- Deduplicates overlapping results by timestamp

Key API (macOS 26):
```swift
let enTranscriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [.fastResults, .volatileResults],
    attributeOptions: []
)
let zhTranscriber = SpeechTranscriber(
    locale: Locale(identifier: "zh-Hans"),
    transcriptionOptions: [],
    reportingOptions: [.fastResults, .volatileResults],
    attributeOptions: []
)
let analyzer = SpeechAnalyzer(modules: [enTranscriber, zhTranscriber])
```

**Deduplication Strategy:**
- Both transcribers may produce results for the same spoken utterance
- Use `range.start` timestamps to detect overlap
- Prefer the result with higher confidence (if available) or longer text
- For now: emit both results, letting the user see EN + ZH in the live preview

### Step 2: Add bilingual model management (`SpeechModelManager.swift`)

Add a new method:
```swift
/// Ensure both EN-US and ZH-Hans models are installed.
func ensureBilingualModelsReady() async -> Bool {
    let en = await ensureModelReady(for: Locale(identifier: "en-US"))
    let zh = await ensureModelReady(for: Locale(identifier: "zh-Hans"))
    return en && zh
}
```

Also add `checkBilingualStatus()` that returns a combined status display for Settings.

### Step 3: Rewrite `TransFlowViewModel.startListening()` to use Apple Speech

**Replace** the current Qwen3 engine initialization:
```swift
// OLD (to remove):
let qwen3Engine = try await Qwen3ASREngine(...)
let events = qwen3Engine.processStream(engineStream)

// NEW (to add):
let speechEngine = MultilingualSpeechEngine(locales: [en, zh])
let events = await speechEngine.processStream(engineStream)
```

Flow:
1. Call `SpeechModelManager.shared.ensureBilingualModelsReady()` instead of `qwen3ModelManager.ensureModelReady()`
2. Create `MultilingualSpeechEngine` instead of `Qwen3ASREngine`
3. Process events the same way (`.partial`, `.sentenceComplete`, `.error`)
4. Sentences are written to JSONL file as before

**Speaker diarization** — no changes needed, it's independent of the ASR engine.

### Step 4: Simplify `SettingsView.swift` to show Apple Speech models

Replace the "Qwen3 Speech Model" section with "Speech Recognition Models" showing:
- Status of EN-US model (installed/not downloaded)
- Status of ZH-Hans model (installed/not downloaded)
- "Download All" button if either is missing
- Progress bar during download

Remove all Qwen3-related settings UI.

### Step 5: Remove Qwen3 references from `TransFlowViewModel.init()` and lifecycle

- Remove `qwen3ModelManager` property (or make it private/unused)
- Remove `await qwen3ModelManager.checkStatus()` calls from `initialize()` and `setupLifecycleObserver()`
- Replace with `SpeechModelManager.shared` calls

### Step 6: Clean up `AppSettings.swift` — remove Qwen3-related UserDefaults

If there are any lingering Qwen3 config keys in UserDefaults, clean them up. (Should already be done.)

### Step 7: Verify and build

- Open Xcode, build (Cmd+B)
- Fix any compilation errors
- The only expected warning is the Sendable warning in `RealtimeDiarizationService.swift`

---

## Files to NOT touch (backup code to keep)

| File | Reason |
|------|--------|
| `Qwen3ASREngine.swift` | Backup — user may want to switch back |
| `Qwen3ModelManager.swift` | Backup — user may want to switch back |
| `TranslationService.swift` | Still used by video transcription feature |
| `VideoTranscriptionView.swift` | Separate workflow, unaffected |
| `VideoTranscriptionViewModel.swift` | Separate workflow, unaffected |
| `VideoJSONLStore.swift` | Separate workflow, unaffected |

---

## Files to CREATE

| File | Description |
|------|-------------|
| `TransFlow/TransFlow/Services/MultilingualSpeechEngine.swift` | New class running two `SpeechTranscriber` instances on one audio stream, merging results |

---

## Risk Assessment

- **Apple Speech model download size:** EN-US ~300MB, ZH-Hans ~500MB. Both must be downloaded on first use.
- **Deduplication quality:** Two transcribers may produce overlapping results. If dedup is poor, fall back to single-locale mode (EN only, add ZH as a separate toggle later).
- **Real-time performance:** Two transcribers on one analyzer should be fine — Apple's engine is designed for this.
- **No breaking changes** to video transcription, diarization, recording, or export features.

---

## Rollback Plan

If Apple Speech multilingual doesn't work well:
1. Revert `TransFlowViewModel.swift` to use `Qwen3ASREngine`
2. Revert `SettingsView.swift` to show Qwen3 model manager
3. Qwen3 code is still in the project and importable