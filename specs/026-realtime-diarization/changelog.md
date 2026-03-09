# 026 - 实时转写说话人识别 Changelog

## 2026-03-09 — 修复：只能识别一个说话人

### 根因分析

参考 `speaker_diarization_guide.md` "挑战 1: 只能识别到一个说话人" 章节，问题有三个：

1. **`clusteringThreshold: 0.8` 过高** — DiarizerManager 内部计算 `speakerThreshold = threshold × 1.2 = 0.96`，两个不同人的 cosine distance 几乎不可能超过 0.96，导致全部归为同一说话人
2. **5s chunk + 0s overlap** — 块太短（5s）经常只包含一个人说话，且无 overlap 导致说话人切换时缺乏过渡上下文
3. **缺少 `minSpeechDuration` / `minSilenceGap` 配置** — 默认值过滤掉有效短语音片段

### 修复内容 (`RealtimeDiarizationService.swift`)

| 参数 | 修复前 | 修复后 | 依据 |
|------|--------|--------|------|
| `clusteringThreshold` | 0.8 | **0.5** | guide 推荐实时场景 0.5（speakerThreshold=0.6） |
| `minSpeechDuration` | 未设置 | **0.5s** | 更快响应新说话人 |
| `minSilenceGap` | 未设置 | **0.3s** | 更快识别说话人切换 |
| `chunkDuration` | 5.0s | **10.0s** | guide 推荐 10s（平衡延迟和精度） |
| `chunkSkip` | 5.0s (无 overlap) | **3.0s** | 7s overlap 确保捕获说话人过渡 |

### 增强日志

- 每个 chunk 输出：chunk 编号、时间、segment 数量、当前 chunk 说话人列表、全局已追踪说话人总数
- 启动时输出完整配置参数
- 停止时输出统计摘要（处理 chunk 数、识别说话人数）
- 输出 segmentation / embedding / clustering 各阶段耗时

---

## 2026-03-09 — 初始实现

### 新增文件

- `TransFlow/TransFlow/Services/RealtimeDiarizationService.swift` — 封装 FluidAudio `DiarizerManager` + `AudioStream` 的流式 diarization 服务
- `TransFlow/TransFlow/Views/MediaPlayerBarView.swift` — 统一的媒体播放器控件（播放/暂停 + 进度条），用于音频文件历史回放

### 数据模型变更

- `TranscriptionSentence` — 新增 `speakerId: String?`；改为 memberwise init 以支持扩展字段
- `JSONLContentEntry` — 新增 `speaker_id` 字段，实时转写的说话人信息持久化到 JSONL
- `AppSettings` — 新增 `liveEnableDiarization: Bool`（UserDefaults 持久化）
- `HistoryItemType` — 从 `.live` / `.video` 扩展为 `.live` / `.video` / `.audio`
- `HistoryFilter` — 新增 `.media`（音频）筛选项

### ViewModel 变更

- `TransFlowViewModel.startListening()` — 新增第 4 路 audio fork（diarization），根据 `liveEnableDiarization` 和模型状态决定是否启动
- `TransFlowViewModel` — 新增 `isDiarizationEnabled`, `activeSpeakerCount` 状态
- `TransFlowViewModel` — 新增 diarization segment 接收、speaker backfill、JSONL 重写逻辑

### UI 变更

- `ControlBarView` — 新增说话人识别开关按钮（`person.2.wave.2` 图标，橙色高亮），显示活跃说话人数
- `TranscriptionView.SentenceRow` — 显示彩色说话人标签（复用 `SpeakerColor` / `SpeakerDisplayName`）
- `FloatingPreviewView` — 字幕行前添加说话人名称前缀
- `HistoryView.EntryRowView` — 实时历史条目显示说话人标签
- `HistoryView.HistoryRowView` — 三种类型（实时/音频/视频）使用不同颜色和图标标签
- `HistoryView` — 筛选器支持 All / Live / Audio / Video 四种
- `VideoSessionDetailView` — 音频文件使用 `MediaPlayerBarView`（播放/暂停 + 进度条），替代原来的简单按钮

### 国际化

- 新增 keys: `control.enable_diarization`, `control.disable_diarization`, `control.diarization_model_required`, `history.badge.audio`, `history.filter.audio`（en + zh-Hans）

### 架构要点

- Speaker 分配通过时间重叠匹配：sentence 的时间范围与 diarization segment 的时间范围取最大交叉区间
- Backfill 机制：diarization 结果到达时回溯更新 `speakerId == nil` 的历史 sentence，并重写 JSONL
- 前置条件：diarization 模型已下载（`DiarizationModelManager.shared.modelStatus.isReady`），否则按钮置灰
