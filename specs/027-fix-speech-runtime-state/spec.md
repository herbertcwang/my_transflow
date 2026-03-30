# 027 - 修复语音模型真实状态与首页说话人识别初始化

## 背景

当前桌面版有两个相互关联的问题：

1. Apple Speech 转写模型在 App 闲置一段时间后，可能已经被系统回收或解绑，但 UI 和启动前检查仍把它当作可用
2. 实时说话人识别在首页初次进入时经常不可用，必须先进入设置页触发一次模型状态检查，返回首页后才恢复

## 根因

### 1. Speech 模型状态误判

- `SpeechModelManager` 目前主要依赖 `AssetInventory.status(forModules:)`
- 这个状态会受到框架缓存和 reservation 状态影响，可能出现“看起来 installed，但实际 locale 已不在设备安装列表里”的假阳性
- `ensureModelReady()` 因此会放过一个其实已经不可用的模型，直到 `SpeechEngine` 启动才失败

### 2. Diarization 首页没有首轮状态刷新

- `DiarizationModelManager` 初始状态是 `.checking`
- 首页开关直接读这个状态，但 app 启动时没有主动刷新
- 设置页会调用 `checkStatus()`，所以进入设置页后状态才变正确

## 修复方案

### 1. SpeechModelManager

- 将“模型是否已安装”的真相来源切换为 `SpeechTranscriber.installedLocales`
- `AssetInventory.status(forModules:)` 只用于：
  - 判断 `.downloading`
  - 判断 `.unsupported`
  - 辅助 stale cache / re-reserve 恢复
- 当 `AssetInventory` 报 `.installed` 但 `installedLocales` 中不存在对应 locale 时，视为未安装并记录日志
- `refreshAllStatuses()` 使用同一批 `installedLocales` 快照，避免整页刷新时逐个 locale 重新读取导致状态不一致

### 2. Runtime Recovery

- 当实时转写或视频转写过程中收到 `SpeechEngine` error 事件时，立即触发 speech model 状态刷新
- 这样失败后的 UI 会尽快收敛到真实状态，不再继续把该语言显示为可用

### 3. Diarization 初始化

- `DiarizationModelManager` 在 singleton 初始化时立即执行 `checkStatus()`
- 同时监听 `NSApplication.didBecomeActiveNotification`，App 回到前台时重新检查本地模型文件
- `TransFlowViewModel.initialize()` 和首页会话启动前都再主动做一次 `checkStatus()`
- 首页 `ControlBarView` 显式观察 `DiarizationModelManager.shared`，确保状态变化会驱动按钮刷新

## 影响范围

- 实时转写首页语言可用性
- 视频转写语言可用性
- `ensureModelReady()` 启动前校验
- 首页说话人识别按钮的启用状态
