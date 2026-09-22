## 1. Baseline and observability

- [x] 1.1 Confirm current three-minute behavior by tracing duration constants, camera buffering, and composition range; record evidence in findings.md
- [x] 1.2 Add RecordingTimeline value types and RecordingCore tests for origin, elapsed time, pre-origin, and backward PTS handling
- [x] 1.3 Extend recording metrics with source durations, PTS/drift, camera drop reasons, queue depth, and export duration

## 2. Recording timeline and camera writer

- [x] 2.1 Integrate the shared timeline into ScreenRecorder screen/audio/camera sample mapping without fabricating timestamps
- [x] 2.2 Move camera raw-track rendering and AVAssetWriter append behind a dedicated bounded serial writer queue
- [x] 2.3 Preserve the existing preview path while routing recording samples directly to the writer and finishing writers in a deterministic order
- [x] 2.4 Add regression coverage for camera gaps, monotonic timestamps, and no-camera/microphone/system-audio modes

## 3. Export duration

- [x] 3.1 Make composition master range derive from session duration and hold/hide a camera overlay that ends early
- [x] 3.2 Remove or constrain any explicit 180-second/ring-buffer/minimum-duration behavior found in task 1.1
- [x] 3.3 Add synthetic 5/10/30/60-minute duration tests and validate output duration against the master range

## 4. ASR isolation

- [x] 4.1 Introduce a StreamingASRProvider boundary while keeping sherpa-onnx as the default implementation
- [x] 4.2 Separate recording-quality microphone samples from a 16 kHz mono ASR stream and move decode to a dedicated queue
- [x] 4.3 Add partial-result throttling and ASR latency/RTF metrics without changing the existing model bundle

## 5. Script alignment and progress

- [x] 5.1 Add mixed CJK/Latin token and normalization types while preserving existing teleprompter cue tokens
- [x] 5.2 Implement bounded local fuzzy alignment, confidence scoring, omission/insertion tolerance, and large-jump consensus
- [x] 5.3 Add lost/re-anchor and speculative/committed progress state transitions with unit tests for Chinese, filler words, and skipped sentences
- [x] 5.4 Connect the progress controller to the existing teleprompter UI without moving decode/alignment work onto MainActor
- [x] 5.5 Handle cumulative partials and fast-speech recovery with a recent-token tail, adaptive bounded search, and consecutive high-confidence re-anchor tests
- [x] 5.6 Project committed token progress into the exact rendered-character coordinate space and re-anchor the aligner on explicit word taps
- [x] 5.7 Expose tracking/uncertain/lost state to the teleprompter UI with compact recovery guidance
- [x] 5.8 Add partial-gate integration coverage proving fast-speech recovery does not depend on duplicate ASR results
- [x] 5.9 Show recording preflight readiness for the screen and enabled microphone/camera, including camera first-frame readiness
- [x] 5.10 Prevent repeated recent speech and unconfirmed legacy fallback from committing a distant duplicate or the end of the script
- [x] 5.11 Skip the setup wizard on relaunch when required permissions are already authorized and the workspace already exists

## 6. Verification and handoff

- [x] 6.1 Run focused RecordingCore tests and a Debug Xcode build; document Git LFS/model blockers separately
- [x] 6.2 Run available short recording/export smoke checks and verify no-camera, system-audio, microphone, and area-recording regressions
- [ ] 6.3 Run 30-minute A/V and 10/30/60-minute export acceptance when hardware/assets are available; update README and archive the OpenSpec change
