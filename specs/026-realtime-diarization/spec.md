# 026 - 实时转写说话人识别

## 背景

视频转写中的说话人识别已经可用，使用 FluidAudio 的 `OfflineDiarizerManager`（pyannote 分割 + WeSpeaker embedding + VBx 聚类）对完整音频进行离线 diarization，再与 Apple Speech 的转写结果按时间重叠合并。效果较好，因为离线模式可以看到全局音频，聚类质量高。

实时转写目前没有说话人识别。实时场景的核心难点：

1. **数据不完整** — 无法看到未来的音频，聚类只能基于已有数据
2. **低延迟要求** — 用户期望近实时看到"谁在说话"
3. **说话人数量未知** — 不能预设说话人数量
4. **短片段质量差** — 短于 1-2 秒的语音片段 embedding 质量低，容易误判
5. **声纹漂移** — 同一个人在不同时段的 embedding 可能有偏移

## 现有架构概览

### 实时转写管线

```
麦克风 / App 音频
    → AudioCaptureService（16kHz mono Float32, ~100ms chunks）
    → Fork: engineStream / levelStream / recordingStream
    → SpeechEngine（~200ms 批量 → SpeechAnalyzer）
    → TranscriptionEvent（partial / sentenceComplete）
    → TransFlowViewModel 更新 UI
```

### 视频转写说话人识别管线

```
视频文件 → AudioExtractorService（完整 16kHz 音频）
    → SpeechEngine 转写 → [TranscriptionSentence]
    → DiarizationService.performDiarization（OfflineDiarizerManager, 全量音频）
    → [SpeakerSegment]
    → mergeResults（按时间重叠合并、标点分割）
    → [VideoTranscriptionSegment]（含 speakerId）
```

### 已有的 FluidAudio 能力

FluidAudio 提供两套 diarization 方案：

| 方案 | API | 特点 |
|------|-----|------|
| **DiarizerManager**（流式） | `performCompleteDiarization(_:atTime:)` + `AudioStream` | pyannote 分割 + WeSpeaker embedding + `SpeakerManager` 在线聚类，支持 chunk-by-chunk 处理 |
| **OfflineDiarizerManager**（离线） | `process(audio:)` | pyannote + VBx 全局聚类，精度最高但需要完整音频 |
| **Sortformer**（流式/端到端） | `Pipeline.processSamples(_:)` | NVIDIA 端到端神经网络，~1s 延迟，固定 4 说话人上限 |

## 技术方案分析

### 方案 A：DiarizerManager 流式 Diarization（推荐）

使用 FluidAudio 已有的 `DiarizerManager` + `AudioStream` + `SpeakerManager` 流式管线。

#### 工作原理

```
实时音频流（16kHz, ~100ms chunks）
    ├→ SpeechEngine（转写）
    └→ AudioStream（累积 5-10s chunk）
         → DiarizerManager.performCompleteDiarization(chunk, atTime: t)
         → SpeakerManager 在线分配/创建说话人
         → [TimedSpeakerSegment]
         → 与 TranscriptionSentence 按时间合并
```

`AudioStream` 负责音频的滑窗与 chunking：
- `chunkDuration`: 每个 chunk 的持续时长（推荐 5s）
- `chunkSkip`: 相邻 chunk 起始时间间隔（推荐 5s，即无 overlap）
- `chunkingStrategy`: `.useMostRecent` 或 `.useFixedSkip`

> **Benchmark 数据**（AMI SDM 数据集）：
>
> | 配置 | Avg DER | Speaker Error | 说话人数偏差 |
> |------|---------|--------------|------------|
> | 3s chunks, 1s overlap, 0.85 | 49.7% | 38.6% | 严重过多 |
> | 10s chunks, 0s overlap, 0.7 | 33.3% | 21.5% | 偏多 |
> | **5s chunks, 0s overlap, 0.8** | **26.2%** | **13.1%** | **最合理** |
> | 5s chunks, 2s overlap, 0.8 | 43.0% | 32.3% | 过多 |
>
> **5s/0s/0.8 是 FluidAudio benchmark 验证的最优流式配置。**
> 3s chunk 精度最差（DER 几乎翻倍），overlap 反而导致 SpeakerManager 重复处理相同音频，增加 speaker 碎片化。

`SpeakerManager` 是流式方案的关键组件，维护一个在线说话人数据库：
- 对每个 chunk 的 embedding 进行最近邻匹配（cosine distance < `speakerThreshold`）
- 匹配成功则归属现有说话人并更新其 embedding（EMA 指数移动平均）
- 匹配失败且语音时长 ≥ `minSpeechDuration` 则创建新说话人
- 支持预注册已知说话人（`initializeKnownSpeakers`）
- 支持合并相似说话人（`findMergeablePairs` + `mergeSpeaker`）

#### 优势

- **FluidAudio 原生支持**，`DiarizerManager` 已有完整的流式 API 和 `AudioStream` 封装
- **无说话人数量限制**，`SpeakerManager` 按需创建
- **声纹累积改善**，EMA 机制使 embedding 越来越准
- **与视频 diarization 共用模型文件**（`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc`）
- **SpeakerManager 功能丰富**：支持说话人合并、移除不活跃说话人、持久化/恢复

#### 劣势

- **延迟较高**，最优 chunk 为 5s（benchmark 验证），加上推理时间约 1-2s，总延迟约 6-7s
- **短片段精度有限**，< 3s 的 chunk 可能不可靠
- **对噪声敏感**，背景噪音可能导致 false speaker，需要 VAD 过滤
- **chunk 边界效应**，说话人切换恰好在 chunk 边界时可能分配错误

#### 架构设计

```swift
// 新增服务：RealtimeDiarizationService
final class RealtimeDiarizationService: Sendable {
    private let diarizer: DiarizerManager
    private var audioStream: AudioStream

    // 初始化时复用已有的 diarization 模型
    func initialize() async throws {
        let models = try await DiarizerModels.downloadIfNeeded()
        diarizer.initialize(models: models)
    }

    // 将实时音频喂入 AudioStream，由 bind callback 触发 diarization
    func feedAudio(_ samples: [Float]) throws {
        try audioStream.write(from: samples)
    }

    // AudioStream callback 中调用
    func processDiarizationChunk(_ chunk: [Float], atTime time: Float) throws -> [TimedSpeakerSegment] {
        let result = try diarizer.performCompleteDiarization(chunk, atTime: time)
        return result.segments
    }
}
```

#### 合并策略

Diarization chunk 处理结果与转写句子之间的合并需要特别处理：

1. **时间对齐**：`TranscriptionSentence` 的 `startTimestamp` / `timestamp` 是 `Date`，需转换为会话相对时间，与 diarization 的 `startTimeSeconds` / `endTimeSeconds` 对齐
2. **延迟容忍**：diarization 结果可能比转写结果晚 3-10 秒到达，需要缓冲已完成的句子等待 diarization 结果
3. **回填机制**：当 diarization 结果到达时，回填之前未标记 speakerId 的句子
4. **默认行为**：在 diarization 结果到来之前，句子显示为无说话人标记

### 方案 B：Sortformer 端到端流式 Diarization

使用 FluidAudio 的 Sortformer 模型——NVIDIA 的端到端神经 diarization 模型。

#### 工作原理

```
实时音频流（16kHz, ~100ms chunks）
    ├→ SpeechEngine（转写）
    └→ Pipeline.processSamples(samples)
         → Mel Spectrogram → CoreML Model → [T', 4] speaker probabilities
         → SortformerTimeline（confirmed + tentative segments）
         → 与 TranscriptionSentence 按时间合并
```

Sortformer 直接输出每帧 4 个说话人的概率（~80ms 分辨率），无需分割 + embedding + 聚类的多阶段处理。

streaming 状态管理：
- **Speaker Cache**（188 帧）：压缩的历史说话人 embedding
- **FIFO Queue**（40 帧）：最近未压缩的 embedding
- 当 FIFO 溢出时自动压缩到 Speaker Cache

#### 优势

- **极低延迟**，默认配置 ~1.04s 延迟（6 帧 chunk + 7 帧右侧上下文）
- **端到端神经网络**，无需手工调参聚类阈值
- **处理重叠语音**，可以同时检测多个说话人
- **对噪声更鲁棒**，比 pyannote pipeline 在噪声环境下表现更好
- **有 tentative predictions**，可以在结果最终确认前就显示给用户

#### 劣势

- **固定 4 说话人上限**，无法处理 5+ 人的场景
- **无说话人 ID 持续性**，Sortformer 输出的是 speaker slot（0-3），不是基于声纹的 ID；不同会话无法识别同一个人
- **额外模型下载**，需要下载 Sortformer CoreML 模型（独立于 pyannote 模型）
- **安静语音可能丢失**，Sortformer 被训练为忽略背景对话，安静的或远处的语音可能被遗漏
- **无法跨会话识别说话人**，每次重新开始 slot 编号重置

#### 适用场景

- 2-4 人的会议/对话
- 需要极低延迟的场景
- 噪声环境
- 不需要跨会话识别说话人

### 方案 C：VAD 辅助 + 离线后处理

不进行实时 diarization，而是使用 VAD 辅助在转写过程中标记语音活动段，在会话结束后用 `OfflineDiarizerManager` 对录音文件进行离线 diarization。

#### 工作原理

```
实时阶段：
    实时音频流
    ├→ SpeechEngine（转写）
    ├→ VadManager.processStreamingChunk（标记语音活动）
    └→ AudioRecordingService（录音保存 M4A）

    UI 中仅显示转写文本，不显示说话人标签

结束后自动后处理：
    录音 M4A → AudioExtractorService → [Float]
    → OfflineDiarizerManager.process(audio:) → [SpeakerSegment]
    → 与 [TranscriptionSentence] 按时间合并
    → 回填 speakerId，更新 UI 和 JSONL
```

#### 优势

- **最高精度**，使用 VBx 全局聚类（与视频转写一致）
- **无说话人数量限制**
- **不增加实时负载**，diarization 在后台异步进行
- **实现最简单**，复用已有的 `OfflineDiarizerManager` + `mergeResults`

#### 劣势

- **无实时说话人显示**，用户在转写过程中看不到"谁在说"
- **会话结束后需等待**，后处理耗时取决于录音长度（~数秒到数十秒）
- **用户体验差**，不满足"实时识别说话人"的预期

### 方案 D：混合方案 — 流式 + 离线修正（最佳体验）

结合方案 A（或 B）和方案 C：实时阶段使用流式 diarization 提供即时说话人标签，会话结束后使用离线 diarization 自动修正。

#### 工作原理

```
实时阶段：
    实时音频流
    ├→ SpeechEngine（转写）
    ├→ DiarizerManager / Sortformer（流式 diarization）
    └→ AudioRecordingService（录音保存 M4A）

    UI 实时显示说话人标签（provisional，可能有误）

结束后自动修正（可选）：
    录音 M4A → OfflineDiarizerManager → [SpeakerSegment]
    → 重新合并，覆盖流式结果
    → 更新 UI 和 JSONL（speakerId 可能变化）
```

#### 优势

- **实时反馈**，用户可以即时看到说话人标签
- **最终高精度**，离线修正后精度与视频转写一致
- **用户可选**，可以跳过离线修正步骤直接使用流式结果

#### 劣势

- **实现复杂度最高**
- **说话人 ID 可能变化**，离线修正后 speaker_0 可能变成 speaker_2，需要做 ID 映射
- **双重计算开销**，同一段音频处理两次

## 方案对比总结

| 维度 | A: DiarizerManager 流式 | B: Sortformer | C: 离线后处理 | D: 混合 |
|------|------------------------|---------------|-------------|---------|
| 实时延迟 | ~6-7s | ~1s | 无实时 | 1-7s |
| 精度 | 中 | 中高 | 最高 | 实时中/最终最高 |
| 说话人上限 | 无限制 | 4 | 无限制 | 取决于实时方案 |
| 跨会话识别 | 可（SpeakerManager） | 否 | 可 | 可 |
| 额外模型 | 无（复用已有） | 需下载 Sortformer | 无 | 取决于实时方案 |
| 实现复杂度 | 中 | 中 | 低 | 高 |
| 噪声鲁棒性 | 低（需 VAD） | 高 | 最高 | 取决于实时方案 |
| 重叠语音 | 不支持 | 支持 | 不支持 | 取决于实时方案 |

## 推荐方案

**推荐方案 A（DiarizerManager 流式 Diarization）作为首选实现。** 理由：

1. **复用已有模型** — 不需要额外下载新模型，`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` 已在 Settings 中管理
2. **与视频 diarization 架构一致** — 底层共用同一套分割 + embedding 模型，维护成本低
3. **SpeakerManager 功能强大** — 在线声纹累积、说话人合并、不活跃清理等功能成熟
4. **无说话人数量限制** — 适用于多人会议
5. **5-10s 延迟可接受** — 对于"识别说话人"场景，用户可以容忍几秒的延迟看到标签
6. **可扩展到方案 D** — 如果将来需要更高精度，可以增加离线修正步骤

### 关键实现要点

#### 1. 音频流分叉

在现有的 3-fork（engine / level / recording）基础上增加第 4 个 fork 给 diarization：

```
audioStream → fork → engineStream（转写）
                   → levelStream（音量）
                   → recordingStream（录音）
                   → diarizationStream（说话人识别）  ← 新增
```

#### 2. AudioStream 配置

```swift
var stream = AudioStream(
    chunkDuration: 5.0,              // 5 秒一个 chunk（benchmark 最优配置）
    chunkSkip: 5.0,                  // 无 overlap（overlap 反而降低精度）
    streamStartTime: 0.0,
    chunkingStrategy: .useFixedSkip  // 固定间隔，确保 chunk 均匀分布
)
```

#### 3. SpeakerManager 调优

```swift
// DiarizerManager 使用默认 config 即可，clustering threshold 在 DiarizerConfig 中设置
let config = DiarizerConfig(
    clusteringThreshold: 0.8          // benchmark 最优值（5s chunk 时）
)
let diarizer = DiarizerManager(config: config)

// SpeakerManager 由 DiarizerManager 内部管理，可通过 diarizer.speakerManager 访问
// 默认参数（speakerThreshold: 0.65, minSpeechDuration: 1.0）通常无需修改
```

#### 4. 数据模型扩展

`TranscriptionSentence` 需要增加 `speakerId` 字段：

```swift
struct TranscriptionSentence: Identifiable, Sendable {
    let id: UUID
    let startTimestamp: Date
    let timestamp: Date
    let text: String
    var translation: String?
    var speakerId: String?         // 新增：说话人 ID
}
```

`TranscriptionEvent` 可能需要新增事件类型：

```swift
enum TranscriptionEvent: Sendable {
    case partial(String)
    case sentenceComplete(TranscriptionSentence)
    case speakerUpdate(sentenceId: UUID, speakerId: String)  // 新增：回填说话人
    case error(String)
}
```

#### 5. 合并时序问题

流式 diarization 的结果相对于转写有延迟，需要设计回填机制：

```
时间轴：
t=0s   t=5s   t=7s   t=10s  t=12s
  |------|------|------|------|
  sentence1  sentence2  sentence3
         |---- chunk1 ----|
                    |---- chunk2 ----|

sentence1 在 t=3s 完成，chunk1 在 t=7s 才返回 diarization 结果
→ sentence1 需要等 4 秒才能获得 speakerId
→ 用 pending buffer 暂存，chunk 结果到达后回填
```

#### 6. VAD 增强（可选但推荐）

在 diarization 之前加入 VAD 过滤，减少噪声导致的 false speaker：

```swift
let vadManager = try await VadManager(config: VadConfig(defaultThreshold: 0.5))

// 在 AudioStream callback 中先过滤
stream.bind { chunk, time in
    let vadResults = try await vadManager.process(chunk)
    let speechOnly = extractSpeechSegments(chunk, vadResults)
    // 只对语音部分做 diarization
}
```

#### 7. UI 变更

- 实时转写的每个句子左侧增加说话人颜色标记和标签
- 复用 `SpeakerColor` 和 `SpeakerDisplayName`
- 说话人标签在回填前显示为空或占位状态
- 浮动预览窗口也需要显示说话人标签
- ControlBarView 增加"说话人识别"开关（当 diarization 模型已下载时可用）

#### 8. 设置与模型复用

- 复用 Settings 中已有的 diarization 模型管理（`DiarizationModelManager`）
- 新增 `AppSettings.liveEnableDiarization: Bool`
- 复用 `AppSettings.diarizationSensitivity`（映射到 `SpeakerManager.speakerThreshold`）

## 潜在风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 短片段 embedding 质量差 | 说话人频繁切换或误判 | `minSpeechDuration` 设为 1s+；忽略过短片段 |
| 同一人被识别为多人 | 说话人数量虚高 | 定期调用 `findMergeablePairs` 合并相似说话人 |
| CPU/GPU 负载增加 | 转写卡顿 | diarization 在独立 Task 中运行；如负载过高可降低 chunk 频率 |
| 模型未下载时的体验 | 用户无法使用 | UI 中灰掉开关，引导到 Settings 下载 |
| 麦克风 vs App 音频表现差异 | App 音频质量更稳定 | 可能需要根据音频源调整阈值 |

## 参考文件

| 文件 | 相关性 |
|------|--------|
| `Services/DiarizationService.swift` | 离线 diarization 封装，可参考 |
| `Services/DiarizationModelManager.swift` | 模型管理，直接复用 |
| `ViewModels/TransFlowViewModel.swift` | 实时转写主 ViewModel，需修改 |
| `ViewModels/VideoTranscriptionViewModel.swift` | 合并逻辑参考 |
| `Models/TranscriptionModels.swift` | 数据模型，需扩展 |
| `Models/VideoTranscriptionModels.swift` | SpeakerColor / SpeakerDisplayName，可复用 |
| `reference/fluidaudio-docs/Diarization/GettingStarted.md` | DiarizerManager + AudioStream API |
| `reference/fluidaudio-docs/Diarization/SpeakerManager.md` | SpeakerManager 完整 API |
| `reference/fluidaudio-docs/Diarization/Sortformer.md` | Sortformer 方案参考 |
