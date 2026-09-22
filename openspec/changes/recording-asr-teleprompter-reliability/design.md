## Context

CueRecord 已将屏幕、摄像头和音频采集放在不同组件中，但当前 `ScreenRecorder` 与 `CameraManager` 由 `@MainActor` 管理，摄像头 sample 在回调后进入主线程处理；屏幕首帧被当作时间基准，摄像头则在另一条路径计算相对时间。ASR 已使用内置 sherpa-onnx Paraformer，但识别、匹配和提词器进度仍由 `SpeechRecognizer` 以字符偏移耦合处理。工程还启用了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，因此任何媒体写入和解码路径都必须显式离开主线程。

约束：保持 macOS 14.1+、Intel/Apple Silicon、现有 raw_data 资产和项目格式兼容；先复用既有模型与框架；不引入云端服务、不要求重新下载模型、不大范围重写 UI。

## Goals / Non-Goals

**Goals:**

- 用真实媒体 PTS 建立 session master timeline，并保留跨来源单调性。
- 将摄像头原始写入移出 MainActor，明确回压和丢帧原因。
- 让导出时长由 session 范围决定，不由 camera 最短轨道决定。
- 提供可读的 metrics/日志和纯 Swift 可运行的时间轴、导出时长、token 对齐测试。
- 将 ASR decode 与录音 writer 解耦，保留 sherpa 默认实现。
- 提供可容错的中英混合脚本对齐和稳定的提词器进度状态。

**Non-Goals:**

- 本 change 不替换为 Whisper、不接入云 ASR、不下载或复制用户模型。
- 本 change 不改变已有项目文件格式和默认录制入口。
- 本 change 不把 UI 动画作为录制正确性的补偿手段。
- 无法在当前机器完成的 30/60 分钟人工压力测试只记录为待执行验收，不伪造通过结论。

## Decisions

### 1. 统一使用媒体 PTS，不使用帧序号或墙上时钟

新增线程安全的 `RecordingTimeline`，以首个有效屏幕 sample 的 host/媒体时钟为 origin；屏幕、摄像头、音频各自的 sample PTS 先映射到同一相对时间轴。负时间和逆序 sample 丢弃并计数。选择 PTS 而非 `Date()`/`frameIndex / fps`，因为掉帧后帧序号无法表达真实经过时间。

### 2. 摄像头采用 capture → bounded writer queue → AVAssetWriter

`CameraManager` 只在 capture queue 创建轻量 `CameraFrameSample`，原始写入由后台串行 writer 负责；预览仍可异步丢帧。队列满时丢弃并记录原因，不重新编造 PTS。相比在 MainActor 上同步渲染，这能避免 UI 或 ASR 阻塞媒体写入。

### 3. Export master range 来自 session

保存 session stop PTS 和各 raw track duration。合成时使用 session master duration；camera 轨道不足时复用最后一帧或隐藏 overlay，不把整个输出裁短。保留现有编辑 cut 逻辑，但所有 cut 先投影到同一 master 时间轴。

### 4. ASR 继续 sherpa，抽象输入边界

保留现有 `SherpaOnnxStreamingASR` 作为实现，抽出 `StreamingASRProvider`/音频分叉边界；48 kHz 录音和 16 kHz mono 推理流独立。decode queue 使用固定并发，partial 以节流后的事件送给匹配层。这样能先修正确性，再替换模型。

### 5. 对齐采用 token + 局部窗口 + committed/speculative

复用现有 CJK token 化基础，补充统一 normalizer、英文连续词 token、舞台提示过滤和局部 weighted edit distance。小步前进可直接提交；大跳转需要最近 3 次中至少 2 次一致；1.5 秒无可信匹配进入 lost，连续高分 token 后恢复。UI 只消费进度状态，不执行 ASR 或匹配计算。

### 6. 以可测试纯值对象承载核心规则

时间映射、duration 选择、tokenization、alignment candidate 和 state transition 优先做成无 UI 依赖的 Swift 类型，接入现有 `Tests/RecordingCoreTests` 命令行 harness。这样无需真实摄像头也能覆盖主要回归。

### 7. 累计 partial 使用短尾匹配，lost 后分级扩大搜索

流式 ASR 可能反复返回从当前 endpoint 开始的累计文本，也可能改写较早的几个 token。对齐器只使用最近一段有效 token 参与打分，避免已经提交的前缀继续拖低当前位置的相似度。正常 tracking 仍使用小范围局部搜索；持续 1.5 秒无可信匹配后进入 lost，并将向前搜索范围扩大到受限 recovery window。远距离候选仍需高分和连续两次一致才提交，且 committed 进度保持单调向前。

这一方案借鉴 Textream 的累计识别前缀隔离/双策略快读追赶，以及 Open Prompter 的短尾缓冲/超时扩大范围；不引入离线 forced-alignment 模型或新的运行时依赖。

## Risks / Trade-offs

- [硬件时钟差异] 不同采集设备可能仍有固定起始 offset → 记录各来源首 PTS 和 drift，验收区分固定 offset 与累计 drift。
- [writer 回压] 后台编码速度不足会丢帧 → 使用 bounded queue 和指标；不通过扩大内存缓存掩盖问题。
- [主线程隔离编译变化] 新的 `nonisolated` 入口可能暴露现有共享状态 → 先将 sample 与 metrics 设计为值类型，再逐点切换调用边界。
- [模型资源缺失] Git LFS 指针会阻止完整构建 → 先运行不依赖模型的 RecordingCore 测试；构建结论明确标记资源门禁。
- [对齐误跳] 模糊匹配可能选错远处重复句 → 限制搜索窗口、增加位置先验和 2-of-3 consensus，保留 uncertain/lost 状态。

## Migration Plan

1. 先加入时间轴、metrics、纯值对象和回归测试，不改变默认 UI 行为。
2. 将摄像头写入替换为后台 writer，并保留旧路径可回滚到同一 session 分支。
3. 修正 export master range，生成 10/30/60 分钟合成测试夹具。
4. 抽出 ASR provider 与独立输入队列，默认 provider 仍为 sherpa。
5. 切换脚本对齐和提词器状态机，先保留旧 matcher 作为失败回退。
6. 完成 build、RecordingCore、短时人工 smoke；具备硬件后再执行 30 分钟 soak。若任一阶段破坏现有无摄像头录制，回退该阶段而不回退前序诊断产物。

## Open Questions

- 当前三分钟截断究竟来自显式常量、缓存容量还是合成 duration，需要在实现阶段以源码和资产 duration 证实。
- `AVCaptureSession.synchronizationClock` 在当前最低系统和设备组合上的可用性需要编译验证；不可用时保留现有 PTS 作为受限 fallback。
- 是否能在本机获得真实 30/60 分钟摄像头压力测试条件，决定最终验收是完整通过还是保留待执行项。
