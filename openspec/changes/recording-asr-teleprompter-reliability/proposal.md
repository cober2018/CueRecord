## Why

CueRecord 的长时间摄像头录制存在持续音画漂移和约三分钟截断风险；现有流式识别与提词器跟踪也把“识别文字”和“稿件进度”耦合在一起，导致延迟、卡住和错误跳转。需要在保持现有项目数据、UI 和 sherpa-onnx 模型兼容的前提下，先建立可观测、可验证的录制时间轴，再分离 ASR、脚本对齐和提词器状态。

## What Changes

- 增加统一的录制主时间轴，所有屏幕、摄像头、麦克风和系统音频均以真实 sample PTS 映射，禁止用帧序号或 `Date()` 推算媒体时间。
- 将摄像头采集、预览和原始写入解耦；写入放到专用串行队列，保留丢帧、回压、PTS 单调性和 FPS 指标。
- 让最终导出由录制 session master duration 驱动，消除硬编码 180 秒、固定 ring buffer 或 camera 最短时长裁剪造成的截断。
- 增加录制、导出和 ASR 的诊断指标与结构化日志，支持长时间录制和导出回归验证。
- 将麦克风录音与 ASR 输入分叉：原始录音保持 48 kHz，识别使用独立的 16 kHz mono 流；decode 不运行在 MainActor，也不阻塞 writer。
- 抽象流式 ASR provider，保留现有 sherpa-onnx 为默认/回退实现，并为后续本地或其他 provider 保留配置边界；不在本变更中强制替换为 Whisper。
- 重写中文和中英混合稿件的 tokenizer、normalizer 和局部模糊对齐，支持漏词、口头语、标点差异、跳句恢复、置信度门控和 2-of-3 大跳转确认。
- 将提词器进度拆为 speculative 与 committed 状态，增加 lost/re-anchor 状态和稳定的平滑滚动，避免 partial result 导致来回抖动。
- 补齐 RecordingCore、导出时长、时间戳间隙、ASR 延迟和脚本对齐测试，并保留无摄像头、系统音频、麦克风和区域录制的回归门禁。

## Capabilities

### New Capabilities

- `recording-timeline`: 统一录制时钟、来源 PTS 映射、单调性和跨来源同步。
- `camera-track-writing`: 摄像头采集、预览、后台写入、回压和丢帧指标。
- `export-duration`: 以 session master timeline 生成完整时长的合成视频。
- `recording-observability`: 录制、导出和 ASR 的 metrics、日志和诊断产物。
- `streaming-asr`: 独立音频分叉、16 kHz 流式识别、provider 抽象和 sherpa 默认实现。
- `script-alignment`: 混合文本 token、normalization、局部模糊匹配、置信度和 recovery。
- `teleprompter-progress`: speculative/committed 进度、lost/re-anchor 和稳定滚动状态机。

### Modified Capabilities

- 无。当前 `openspec/specs/` 没有既有能力规范；本变更以新增可测试能力建立契约。

## Impact

- 主要影响 `CueRecord/Recording/Core/Camera`、`CueRecord/Recording/Core/Recording`、`CueRecord/SherpaOnnxStreamingASR.swift`、`CueRecord/SpeechRecognizer.swift`、`CueRecord/Teleprompter`、相关设置/控制器和 `Tests/RecordingCoreTests`。
- 可能需要调整 Swift concurrency isolation、AVAssetWriter 生命周期、ScreenCaptureKit/AVCaptureSession 时间戳转换和 Xcode 同步目录中的新 Swift 文件。
- 保持现有 raw_data 项目资产格式、已发布项目可打开性、默认 sherpa-onnx 模型和现有录制入口兼容；不引入云端 ASR、强制模型下载或大范围 UI 重写。
- 完成标准包括 10/30/60 分钟导出无 180 秒截断、30 分钟音画漂移门禁、ASR 延迟/RTF 指标以及中文脚本对齐场景通过。
