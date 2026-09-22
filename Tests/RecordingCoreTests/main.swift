import CoreGraphics
import CoreMedia
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

func testAudioStartGate() throws {
    let gate = AudioStartGate(holdLimit: seconds(0.5))
    let firstVideo = seconds(1.0)

    try expect(
        gate.decision(audioStart: seconds(0.9), audioDuration: seconds(0.05), firstVideoStart: nil) == .waitForVideo,
        "Audio should wait while video start is unknown"
    )

    switch gate.decision(audioStart: seconds(0.2), audioDuration: seconds(0.2), firstVideoStart: firstVideo) {
    case .dropBeforeVideo:
        break
    default:
        throw TestFailure.failed("Audio that ends before first video should be dropped")
    }

    switch gate.decision(audioStart: seconds(0.95), audioDuration: seconds(0.1), firstVideoStart: firstVideo) {
    case .append(let relativeTo, let partialOverlap):
        try expect(relativeTo == firstVideo, "Overlapping audio should stay on the video time base")
        try expect(partialOverlap == seconds(0.05), "Overlap duration should be measured")
    default:
        throw TestFailure.failed("Overlapping audio should be appended")
    }

    switch gate.decision(audioStart: seconds(1.2), audioDuration: seconds(0.1), firstVideoStart: firstVideo) {
    case .append(let relativeTo, let partialOverlap):
        try expect(relativeTo == firstVideo, "Post-video audio should use first video as offset")
        try expect(partialOverlap == .zero, "Post-video audio should have no partial overlap")
    default:
        throw TestFailure.failed("Post-video audio should be appended")
    }

    try expect(
        gate.shouldKeepPendingAudio(newestAudioStart: seconds(1.0), oldestAudioStart: seconds(0.55)),
        "Pending audio within hold limit should be kept"
    )
    try expect(
        !gate.shouldKeepPendingAudio(newestAudioStart: seconds(1.0), oldestAudioStart: seconds(0.4)),
        "Pending audio beyond hold limit should be trimmed"
    )
}

func testRecordingTimeline() throws {
    let timeline = RecordingTimeline()
    let origin = seconds(100)
    timeline.start(at: origin)

    try expect(timeline.map(origin, source: .screen) == .zero, "Timeline origin should map to zero")
    try expect(timeline.map(seconds(100.066), source: .camera) == seconds(0.066), "Timeline should preserve elapsed PTS")
    try expect(timeline.map(seconds(100.133), source: .camera) == seconds(0.133), "Dropped frames must not compress elapsed time")
    try expect(timeline.map(seconds(99.9), source: .camera) == nil, "Pre-origin samples should be dropped")
    try expect(timeline.map(seconds(100.120), source: .camera) == nil, "Backward source PTS should be dropped")
    try expect(timeline.map(seconds(100.020), source: .microphone) == seconds(0.020), "Microphone-only recordings should map on the shared timeline")
    try expect(timeline.map(seconds(100.040), source: .systemAudio) == seconds(0.040), "System-audio recordings should map on the shared timeline")
}

func testRecordingReadiness() throws {
    let ready = RecordingReadiness(
        screenAuthorized: true,
        microphoneEnabled: true,
        microphoneAuthorized: true,
        microphoneAvailable: true,
        cameraEnabled: true,
        cameraAuthorized: true,
        cameraAvailable: true,
        cameraFrameReady: true
    )
    try expect(ready.isReady, "All enabled recording sources should be ready")

    let optionalSourcesOff = RecordingReadiness(
        screenAuthorized: true,
        microphoneEnabled: false,
        microphoneAuthorized: false,
        microphoneAvailable: false,
        cameraEnabled: false,
        cameraAuthorized: false,
        cameraAvailable: false,
        cameraFrameReady: false
    )
    try expect(optionalSourcesOff.isReady, "Disabled optional sources must not block recording")

    let cameraWaiting = RecordingReadiness(
        screenAuthorized: true,
        microphoneEnabled: false,
        microphoneAuthorized: false,
        microphoneAvailable: false,
        cameraEnabled: true,
        cameraAuthorized: true,
        cameraAvailable: true,
        cameraFrameReady: false
    )
    try expect(!cameraWaiting.isReady, "An enabled camera should not be ready before its first frame")
    try expect(cameraWaiting.blockers == [.cameraFrame], "Camera first-frame wait should be explicit")
}

func testScriptAlignment() throws {
    let aligner = ScriptAligner(script: "大家好，今天介绍 AI【看镜头】然后导出")
    let tokens = aligner.tokens
    try expect(tokens.contains(where: { $0.raw == "AI" }), "Latin runs should remain one token")
    try expect(!tokens.contains(where: { $0.raw == "看镜头" }), "Stage annotations should not become spoken tokens")

    let exact = aligner.consume("大家好今天介绍AI", now: 0)
    try expect(exact?.committed == true, "Exact mixed-script speech should commit")
    let filler = aligner.consume("然后嗯导出", now: 0.2)
    try expect(filler != nil, "Filler words should still produce an alignment result")
}

func testScriptAlignmentCumulativePartialsKeepAdvancing() throws {
    let script = "今天我们先介绍产品背景然后说明核心方法最后总结执行步骤"
    let aligner = ScriptAligner(script: script)

    let first = aligner.consume("今天我们先介绍产品背景", now: 0)
    try expect(first?.committed == true, "Initial partial should establish progress")
    let firstIndex = aligner.state.committedTokenIndex

    let cumulative = aligner.consume("今天我们先介绍产品背景然后说明核心方法", now: 0.2)
    try expect(cumulative?.committed == true, "A cumulative partial should commit its newly spoken tail")
    try expect(
        aligner.state.committedTokenIndex > firstIndex,
        "Repeated committed prefix must not stall later speech"
    )
}

func testScriptAlignmentReanchorsAfterFastSpeechOutrunsWindow() throws {
    let words = (0..<180).map { "term\($0)" }
    let aligner = ScriptAligner(script: words.joined(separator: " "))

    let initial = aligner.consume(words[0..<6].joined(separator: " "), now: 0)
    try expect(initial?.committed == true, "Initial phrase should establish the anchor")
    let initialIndex = aligner.state.committedTokenIndex

    let laterPhrase = words[120..<126].joined(separator: " ")
    let firstRecovery = aligner.consume(laterPhrase, now: 1.6)
    try expect(firstRecovery?.mode == .lost, "The first far match should enter guarded recovery")
    try expect(
        firstRecovery?.allowsLegacyFallback == false,
        "Lost recovery must not let the legacy matcher bypass large-jump consensus"
    )
    try expect(
        aligner.state.committedTokenIndex == initialIndex,
        "A single far candidate must not jump the script"
    )

    let confirmedRecovery = aligner.consume(laterPhrase, now: 1.8)
    try expect(confirmedRecovery?.committed == true, "A repeated distinctive far match should re-anchor")
    try expect(
        aligner.state.committedTokenIndex >= 126,
        "Confirmed recovery should catch up beyond the normal local window"
    )
}

func testScriptAlignmentDoesNotJumpToRepeatedTail() throws {
    let repeatedPhrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    let filler = (0..<80).map { "filler\($0)" }
    let script = (repeatedPhrase + filler + repeatedPhrase).joined(separator: " ")
    let aligner = ScriptAligner(script: script)

    let initial = aligner.consume(repeatedPhrase.joined(separator: " "), now: 0)
    try expect(initial?.committed == true, "The first occurrence should establish progress")
    let initialIndex = aligner.state.committedTokenIndex

    _ = aligner.consume(repeatedPhrase.joined(separator: " "), now: 1.6)
    _ = aligner.consume(repeatedPhrase.joined(separator: " "), now: 1.8)

    try expect(
        aligner.state.committedTokenIndex == initialIndex,
        "Repeated recent speech must not re-anchor to an identical phrase at the end"
    )
}

func testUnconfirmedLargeAlignmentBlocksLegacyFallback() throws {
    let words = (0..<90).map { "segment\($0)marker" }
    let aligner = ScriptAligner(script: words.joined(separator: " "))

    _ = aligner.consume(words[0..<6].joined(separator: " "), now: 0)
    guard let candidate = aligner.consume(words[30..<36].joined(separator: " "), now: 0.2) else {
        throw TestFailure.failed("Fixture should produce a distant candidate")
    }

    try expect(!candidate.committed, "A first large candidate must wait for consensus")
    try expect(
        !candidate.allowsLegacyFallback,
        "An unconfirmed large candidate must not let the legacy matcher bypass consensus"
    )
}

func testScriptAlignmentUsesRenderedCharacterOffsets() throws {
    let displayedScript = splitTextIntoWords("今天我们介绍AI【看镜头】然后开始").joined(separator: " ")
    let aligner = ScriptAligner(script: displayedScript)

    guard let result = aligner.consume("今天我们", now: 0), result.committed else {
        throw TestFailure.failed("Fixture should establish committed CJK progress")
    }
    guard let spokenRange = displayedScript.range(of: "们") else {
        throw TestFailure.failed("Fixture should contain the committed display token")
    }

    let expectedOffset = displayedScript.distance(from: displayedScript.startIndex, to: spokenRange.upperBound)
    try expect(
        aligner.displayOffset(afterTokenIndex: result.candidateTokenIndex) == expectedOffset,
        "Committed progress must include rendered separators in its character offset"
    )
}

func testScriptAlignmentManualDisplayReanchor() throws {
    let displayedScript = splitTextIntoWords("第一句结束。第二句从这里继续。第三句收尾。").joined(separator: " ")
    let aligner = ScriptAligner(script: displayedScript)
    guard let anchorRange = displayedScript.range(of: "这") else {
        throw TestFailure.failed("Fixture should contain the manual anchor token")
    }
    let anchorOffset = displayedScript.distance(from: displayedScript.startIndex, to: anchorRange.lowerBound)

    aligner.reanchor(displayOffset: anchorOffset)

    try expect(
        aligner.tokens[aligner.state.committedTokenIndex].raw == "这",
        "Manual display anchor must move the token aligner to the tapped word"
    )
    let continued = aligner.consume("这里继续", now: 0.2)
    try expect(continued?.committed == true, "Speech after a manual anchor should continue from the tapped location")
}

func testFastSpeechRecoveryThroughPartialGate() throws {
    let words = (0..<180).map { "term\($0)" }
    let aligner = ScriptAligner(script: words.joined(separator: " "))
    var gate = ASRPartialResultGate(minimumInterval: 0.12)

    let initial = words[0..<6].joined(separator: " ")
    if gate.accepts(initial, at: 0) {
        _ = aligner.consume(initial, now: 0)
    }
    let initialIndex = aligner.state.committedTokenIndex

    let firstLaterPartial = words[120..<126].joined(separator: " ")
    let expandedLaterPartial = words[120..<127].joined(separator: " ")
    if gate.accepts(firstLaterPartial, at: 1.6) {
        _ = aligner.consume(firstLaterPartial, now: 1.6)
    }
    if gate.accepts(expandedLaterPartial, at: 1.8) {
        _ = aligner.consume(expandedLaterPartial, now: 1.8)
    }

    try expect(initialIndex > 0, "Initial delivered partial should establish progress")
    try expect(
        aligner.state.committedTokenIndex >= 126,
        "Changed delivered partials should safely recover beyond the normal look-ahead"
    )
}

func testBoundedDropOldestBuffer() throws {
    var buffer = BoundedDropOldestBuffer<Int>(capacity: 2)
    buffer.append(1)
    buffer.append(2)
    buffer.append(3)

    try expect(buffer.droppedCount == 1, "Buffer should count dropped oldest entries")
    try expect(buffer.removeAll() == [2, 3], "Buffer should keep newest entries")
    try expect(buffer.isEmpty, "removeAll should empty the buffer")
}

func testCameraWriterIngress() throws {
    let ingress = CameraWriterIngress<Int>(capacity: 2)

    try expect(ingress.submit(1) == .scheduled, "First camera frame should schedule the serial writer")
    try expect(ingress.submit(2) == .enqueued, "Pending camera frames should not schedule duplicate drains")
    try expect(ingress.submit(3) == .droppedOldest, "A full camera queue should drop only its oldest frame")
    try expect(ingress.takeNext() == 2, "Writer should retain the newer frame after overflow")
    try expect(ingress.takeNext() == 3, "Writer should preserve FIFO order for retained frames")
    try expect(ingress.takeNext() == nil, "An empty writer queue should finish its drain")
    try expect(ingress.submit(4) == .scheduled, "A later frame should schedule a new drain")

    ingress.close()
    try expect(ingress.submit(5) == .rejected, "A stopped writer must reject late camera frames")
    try expect(ingress.snapshot.droppedQueueOverflow == 1, "Queue overflow should be counted separately")
    try expect(ingress.snapshot.maxPendingDepth == 2, "Writer queue depth should be observable")
}

func testRecordingMasterRange() throws {
    let master = RecordingMasterRange.resolve(
        sessionDuration: seconds(600),
        screenDuration: seconds(600),
        cameraDuration: seconds(599.8),
        audioDuration: seconds(600)
    )
    try expect(master.duration == seconds(600), "Session duration must remain the export master range")
    try expect(master.cameraTail == .holdLastFrame, "A short camera track should hold its last frame")

    for duration in [300.0, 600.0, 1800.0, 3600.0] {
        let range = RecordingMasterRange.resolve(
            sessionDuration: seconds(duration),
            screenDuration: seconds(duration),
            cameraDuration: nil,
            audioDuration: nil
        )
        try expect(range.duration == seconds(duration), "Long sessions must not be capped at three minutes")
        try expect(range.cameraTail == .hidden, "No camera track should not affect the master range")
        try expect(
            range.matchesOutputDuration(seconds(duration) + seconds(0.05), tolerance: seconds(0.1)),
            "Synthetic export duration should match its master range within tolerance"
        )
        try expect(
            !range.matchesOutputDuration(seconds(180), tolerance: seconds(0.1)),
            "A three-minute export must not validate against a longer session master range"
        )
    }
}

func testASRPartialResultGate() throws {
    var gate = ASRPartialResultGate(minimumInterval: 0.12)
    try expect(gate.accepts("你好", at: 0), "First ASR partial should be delivered")
    try expect(!gate.accepts("你好", at: 0.2), "Duplicate ASR partial should be suppressed")
    try expect(!gate.accepts("你好世界", at: 0.05), "Fast partial updates should be throttled")
    try expect(gate.accepts("你好世界", at: 0.12), "Changed partial should pass after the throttle interval")
}

func testASRRuntimeMetrics() throws {
    var metrics = ASRRuntimeMetrics()
    metrics.record(audioSeconds: 1.6, decodeSeconds: 0.4)
    try expect(metrics.snapshot.audioSeconds == 1.6, "ASR metrics should retain processed audio duration")
    try expect(metrics.snapshot.realTimeFactor == 0.25, "ASR RTF should be decode time divided by audio duration")
}

func testASRAudioInputBridge() throws {
    let bridge = ASRAudioInputBridge()
    try expect(!bridge.isRecordingInputActive, "Recognition should use its own input before recording starts")

    bridge.beginRecordingInput()
    try expect(bridge.isRecordingInputActive, "Recording should make its microphone input available to ASR")

    bridge.endRecordingInput()
    try expect(!bridge.isRecordingInputActive, "Stopping recording should release the shared microphone input")
}

func testResolvedRecordingTarget() throws {
    let displayOne = RecordingDisplayGeometry(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        name: "Internal",
        index: 0
    )
    let displayTwo = RecordingDisplayGeometry(
        id: 2,
        frame: CGRect(x: 100, y: 0, width: 200, height: 100),
        name: "External",
        index: 1
    )
    let displays = [displayOne, displayTwo]

    let fullScreen = ResolvedRecordingTarget.resolve(
        mode: .fullScreen,
        selectedDisplayID: 2,
        displays: displays
    )
    try expect(fullScreen?.displayID == 2, "Full-screen target should honor selected display")
    try expect(fullScreen?.interfaceFrame == displayTwo.frame, "Full-screen interface frame should be selected display")

    let area = ResolvedRecordingTarget.resolve(
        mode: .selectedArea(CGRect(x: 140, y: 20, width: 60, height: 60)),
        selectedDisplayID: 1,
        displays: displays
    )
    try expect(area?.displayID == 2, "Area target should use the display with the largest intersection")
    try expect(area?.overlayFrame == CGRect(x: 140, y: 20, width: 60, height: 60), "Area overlay should be the capture rect")

    let windowTarget = WindowRecordingTarget(
        windowID: 42,
        frame: CGRect(x: 20, y: 10, width: 50, height: 50),
        title: "Doc",
        ownerName: "App"
    )
    let window = ResolvedRecordingTarget.resolve(
        mode: .selectedWindow(windowTarget),
        selectedDisplayID: 2,
        displays: displays
    )
    try expect(window?.displayID == 1, "Window target should follow the window display")
    try expect(window?.modeName == "selectedWindow", "Window target should expose mode name")
}

func testMetricsURLAndMissingOutputValidation() throws {
    let outputURL = URL(fileURLWithPath: "/tmp/CueRecord Sample.mov")
    let metricsURL = RecordingMetricsRecorder.metricsURL(for: outputURL)
    try expect(metricsURL.lastPathComponent == "CueRecord Sample_metrics.json", "Metrics URL should use output base name")

    let missingURL = URL(fileURLWithPath: "/tmp/cuerecord-missing-\(UUID().uuidString).mov")
    let validation = RecordingOutputValidator.validate(outputURL: missingURL)
    try expect(validation.health == .damaged, "Missing output should be damaged")
    try expect(validation.issues.contains("Output file does not exist"), "Missing output should report a clear issue")
}

func testRecordingPixelFormatPolicy() throws {
    try expect(
        RecordingPixelFormatPolicy.format(from: "bgra") == .bgra,
        "BGRA alias should resolve"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "420v") == .yuv420VideoRange,
        "420v alias should resolve"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "NV12") == .yuv420VideoRange,
        "NV12 alias should map to video-range 420"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "420f") == .yuv420FullRange,
        "420f alias should resolve"
    )

    let suiteName = "CueRecordRecordingPixelFormatPolicyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try expect(
        RecordingPixelFormatPolicy.selectedFormat(defaults: defaults, environment: [:]) == .bgra,
        "Default capture pixel format should stay BGRA until a quality path is explicitly enabled"
    )

    defaults.set("420v", forKey: RecordingPixelFormatPolicy.userDefaultsKey)
    try expect(
        RecordingPixelFormatPolicy.selectedFormat(defaults: defaults, environment: [:]) == .yuv420VideoRange,
        "Stored 420v preference should select video-range 420"
    )

    try expect(
        RecordingPixelFormatPolicy.selectedFormat(
            defaults: defaults,
            environment: [RecordingPixelFormatPolicy.environmentKey: "420f"]
        ) == .yuv420FullRange,
        "Environment override should take precedence over stored preference"
    )
}

func testRecordingExportSettings() throws {
    let defaultSettings = RecordingExportSettings.default
    try expect(defaultSettings.resolutionPreset == .p4K, "Default export resolution should be 4K")
    try expect(defaultSettings.bitRatePreset == .medium, "Default export bitrate should be medium")

    let fiveKSize = CGSize(width: 5120, height: 2880)
    let defaultOutputSize = defaultSettings.outputSize(for: fiveKSize)
    try expect(defaultOutputSize == CGSize(width: 3840, height: 2160), "4K export should cap 5K landscape sources at 3840 x 2160")
    try expect(defaultSettings.outputDimensionsText(for: fiveKSize) == "3840 x 2160", "Expected dimensions text should match the 4K output size")

    let portraitOutputSize = defaultSettings.outputSize(for: CGSize(width: 2880, height: 5120))
    try expect(portraitOutputSize == CGSize(width: 2160, height: 3840), "4K export should preserve portrait aspect ratio")

    let smallSourceSize = CGSize(width: 1280, height: 720)
    try expect(defaultSettings.outputSize(for: smallSourceSize) == smallSourceSize, "4K export should not upscale smaller sources")

    let hdSettings = RecordingExportSettings(resolutionPreset: .p1080, bitRatePreset: .low)
    try expect(hdSettings.outputSize(for: fiveKSize) == CGSize(width: 1920, height: 1080), "1080p export should cap landscape sources at 1920 x 1080")
    try expect(hdSettings.averageBitRate(for: CGSize(width: 1920, height: 1080)) == 4_147_200, "Low bitrate should scale from output pixels")
}

func testRecordingArtifactOrganizer() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordArtifactOrganizer-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let finalURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_composited.mov")
    let rawScreenURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36.mov")
    let cameraURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_camera.mov")
    let overlayURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_overlay.json")
    let metricsURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_metrics.json")

    for url in [finalURL, rawScreenURL, cameraURL, overlayURL, metricsURL] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }

    let movedURLs = try RecordingArtifactOrganizer.moveRawArtifacts(in: root, keeping: finalURL)
    let rawDataURL = root.appendingPathComponent(RecordingArtifactOrganizer.rawDataDirectoryName, isDirectory: true)

    try expect(fileManager.fileExists(atPath: finalURL.path), "Final composited export should stay in the session folder")
    try expect(!fileManager.fileExists(atPath: rawScreenURL.path), "Raw screen recording should leave the session folder")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(rawScreenURL.lastPathComponent).path), "Raw screen recording should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(cameraURL.lastPathComponent).path), "Camera recording should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(overlayURL.lastPathComponent).path), "Overlay metadata should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(metricsURL.lastPathComponent).path), "Metrics should move into raw_data")
    try expect(movedURLs.count == 4, "Only non-final root artifacts should move into raw_data")
}

func testRecordingArtifactDeletion() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordArtifactDeletion-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let screenURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36.mov")
    let cameraURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_camera.mov")
    let overlayURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_overlay.json")
    let unrelatedURL = root.appendingPathComponent("notes.md")

    for url in [screenURL, cameraURL, overlayURL, unrelatedURL] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }

    let capturedOutput = CapturedRecordingOutput(
        outputURL: screenURL,
        cameraURL: cameraURL,
        overlayMetadataURL: overlayURL
    )
    let deletedURLs = try RecordingArtifactOrganizer.deleteArtifacts(for: capturedOutput)

    try expect(!fileManager.fileExists(atPath: screenURL.path), "Delete should remove the raw screen recording")
    try expect(!fileManager.fileExists(atPath: cameraURL.path), "Delete should remove the camera recording")
    try expect(!fileManager.fileExists(atPath: overlayURL.path), "Delete should remove overlay metadata")
    try expect(fileManager.fileExists(atPath: unrelatedURL.path), "Delete should keep unrelated project files")
    try expect(deletedURLs.count == 3, "Delete should report only the removed recording files")
}

func testCueRecordPathPolicy() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordPathPolicy-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    try expect(
        CueRecordPathPolicy.sanitizedPathComponent("CON") == "_CON",
        "Windows reserved names should be prefixed"
    )

    let sanitized = CueRecordPathPolicy.sanitizedPathComponent("  ../Deck: intro?/  ")
    try expect(!sanitized.contains("/"), "Sanitized names should not contain path separators")
    try expect(!sanitized.contains(":"), "Sanitized names should not contain colon characters")
    try expect(!sanitized.isEmpty, "Sanitized names should not be empty")

    let existing = root.appendingPathComponent("Clip.md")
    try Data().write(to: existing)

    let unique = CueRecordPathPolicy.uniqueFileURL(in: root, title: "Clip", pathExtension: "md")
    try expect(unique.lastPathComponent == "Clip 2.md", "Unique file URLs should avoid existing files")

    let excluded = CueRecordPathPolicy.uniqueFileURL(
        in: root,
        title: "Clip",
        pathExtension: "md",
        excluding: existing
    )
    try expect(excluded.lastPathComponent == "Clip.md", "Excluded URLs should be reusable for renames")
}

func testCueRecordProjectManifestAndConflictDetection() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordProjectStore-\(UUID().uuidString)", isDirectory: true)
    let projectURL = root.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)
    let firstURL = projectURL.appendingPathComponent("First.md")
    try "one".write(to: firstURL, atomically: true, encoding: .utf8)

    let manifest = try store.syncManifest(
        markdownURLs: [firstURL],
        titles: ["First"],
        pages: ["one"],
        selectedURL: firstURL
    )
    try expect(manifest.files.count == 1, "Manifest should track markdown files")
    try expect(manifest.selectedFileID == manifest.files.first?.id, "Manifest should track selected file ID")

    let originalFileID = manifest.files[0].id
    let renamedURL = projectURL.appendingPathComponent("Renamed.md")
    try fileManager.moveItem(at: firstURL, to: renamedURL)
    try store.recordMarkdownRename(
        from: firstURL,
        to: renamedURL,
        title: "Renamed",
        contentHash: CueRecordPathPolicy.contentHash("one")
    )
    let renamedManifest = try store.syncManifest(
        markdownURLs: [renamedURL],
        titles: ["Renamed"],
        pages: ["one"],
        selectedURL: renamedURL
    )
    try expect(renamedManifest.files.first?.id == originalFileID, "Renamed markdown should keep its stable file ID")
    try expect(store.selectedMarkdownURL(from: [renamedURL]) == renamedURL, "Selected markdown should resolve from manifest")

    let snapshot = CueRecordFileSnapshot.current(for: renamedURL, cachedText: "one")
    try "outside".write(to: renamedURL, atomically: true, encoding: .utf8)

    do {
        _ = try store.writeMarkdown("inside", to: renamedURL, expectedSnapshot: snapshot)
        throw TestFailure.failed("Stale snapshots should reject writes")
    } catch is CueRecordFileConflictError {
        let diskText = try String(contentsOf: renamedURL, encoding: .utf8)
        try expect(diskText == "outside", "Conflict detection should not overwrite disk changes")
    }

    let freshSnapshot = CueRecordFileSnapshot.current(for: renamedURL, cachedText: "outside")
    _ = try store.writeMarkdown("inside", to: renamedURL, expectedSnapshot: freshSnapshot)
    let updatedText = try String(contentsOf: renamedURL, encoding: .utf8)
    try expect(updatedText == "inside", "Fresh snapshots should allow writes")
}

func testCueRecordTempVaultWorkflow() throws {
    let fileManager = FileManager.default
    let vaultURL = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordTempVaultWorkflow-\(UUID().uuidString)", isDirectory: true)
    let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: vaultURL) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)

    let firstURL = store.uniqueMarkdownURL(title: "Script/Intro")
    let firstSnapshot = try store.writeMarkdown("intro", to: firstURL, expectedSnapshot: nil)
    try expect(firstURL.lastPathComponent == "Script-Intro.md", "Temp-vault workflow should sanitize markdown names")

    let secondURL = store.uniqueMarkdownURL(title: "Script/Intro")
    _ = try store.writeMarkdown("second", to: secondURL, expectedSnapshot: nil)
    try expect(secondURL.lastPathComponent == "Script-Intro 2.md", "Temp-vault workflow should allocate duplicate names")

    let manifest = try store.syncManifest(
        markdownURLs: [firstURL, secondURL],
        titles: ["Script Intro", "Script Intro 2"],
        pages: ["intro", "second"],
        selectedURL: secondURL
    )
    try expect(manifest.files.count == 2, "Temp-vault workflow should create two manifest file records")
    try expect(store.selectedMarkdownURL(from: [firstURL, secondURL]) == secondURL, "Temp-vault workflow should persist selected markdown")

    let renamedURL = store.uniqueMarkdownURL(title: "Final Intro", excluding: firstURL)
    try fileManager.moveItem(at: firstURL, to: renamedURL)
    try store.recordMarkdownRename(
        from: firstURL,
        to: renamedURL,
        title: "Final Intro",
        contentHash: CueRecordPathPolicy.contentHash("intro")
    )
    let renamedManifest = try store.syncManifest(
        markdownURLs: [renamedURL, secondURL],
        titles: ["Final Intro", "Script Intro 2"],
        pages: ["intro", "second"],
        selectedURL: secondURL
    )
    try expect(renamedManifest.files.first?.id == manifest.files.first?.id, "Temp-vault workflow should preserve IDs across rename")

    try "external".write(to: renamedURL, atomically: true, encoding: .utf8)
    do {
        _ = try store.writeMarkdown("stale write", to: renamedURL, expectedSnapshot: firstSnapshot)
        throw TestFailure.failed("External changes after rename should make the old snapshot stale")
    } catch is CueRecordFileConflictError {
        try expect(true, "Temp-vault workflow should reject stale snapshots")
    }
}

func testCueRecordVaultRepairer() throws {
    let fileManager = FileManager.default
    let vaultURL = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordVaultRepairer-\(UUID().uuidString)", isDirectory: true)
    let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: vaultURL) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)
    let firstURL = projectURL.appendingPathComponent("First.md")
    let secondURL = projectURL.appendingPathComponent("Second.md")
    try "one".write(to: firstURL, atomically: true, encoding: .utf8)
    try "two".write(to: secondURL, atomically: true, encoding: .utf8)

    let firstReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(firstReport.scannedProjects == 1, "Repair should scan projects with markdown files")
    try expect(firstReport.createdManifests == 1, "Repair should create a missing manifest")
    try expect(store.loadManifest()?.files.count == 2, "Repair should include existing markdown files")

    let missingURL = projectURL.appendingPathComponent("Missing.md")
    try "missing".write(to: missingURL, atomically: true, encoding: .utf8)
    _ = try store.syncManifest(
        markdownURLs: [firstURL, secondURL, missingURL],
        titles: ["First", "Second", "Missing"],
        pages: ["one", "two", ""],
        selectedURL: missingURL
    )
    try fileManager.removeItem(at: missingURL)

    let staleReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(staleReport.repairedManifests == 1, "Repair should update manifests with stale records")
    try expect(staleReport.removedMissingFileRecords == 1, "Repair should report removed stale records")
    try expect(store.loadManifest()?.files.count == 2, "Repair should remove missing markdown records")

    try Data("{ broken json".utf8).write(to: store.manifestURL)
    let corruptReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(corruptReport.repairedManifests == 1, "Repair should replace corrupt manifests")
    try expect(store.loadManifest()?.files.count == 2, "Repair should recover corrupt manifests")
}

func testTeleprompterLineBreakTokenization() throws {
    let words = splitTextIntoWords("先讲开头|再讲重点｜最后\n收尾")
    let breakCount = words.filter(TeleprompterLineBreak.isBreakToken).count
    let markerBreakCount = words.filter(TeleprompterLineBreak.isMarkerBreakToken).count
    let newlineBreakCount = words.filter { $0 == TeleprompterLineBreak.newlineToken }.count

    try expect(breakCount == 3, "Pipe, full-width pipe, and newline should become teleprompter breaks")
    try expect(markerBreakCount == 2, "Pipe and full-width pipe should become marked breath breaks")
    try expect(newlineBreakCount == 1, "Newlines should remain ordinary line breaks")
    try expect(!words.contains("|"), "ASCII pipe should not be displayed as a word")
    try expect(!words.contains("｜"), "Full-width pipe should not be displayed as a word")
    try expect(words.first == "先", "CJK words should still split into display characters")
    try expect(words.last == "尾", "Trailing text should be preserved after line breaks")
}

func testTeleprompterLineBreakDeduplication() throws {
    let words = splitTextIntoWords("hello||｜\nworld")

    try expect(
        words == ["hello", TeleprompterLineBreak.markerToken, "world"],
        "Consecutive explicit breaks should collapse to one marked visual break"
    )
}

func testTeleprompterPaceCueTokenization() throws {
    let words = splitTextIntoWords("›› 快速带过｜--关键概念\n正常")

    try expect(words.contains(TeleprompterPaceCue.fastToken), "Fast cue should become an internal token")
    try expect(words.contains(TeleprompterPaceCue.slowToken), "Slow cue should become an internal token")
    try expect(words.contains(TeleprompterLineBreak.markerToken), "Breath marker should remain a marked line break")
    try expect(words.contains(TeleprompterLineBreak.newlineToken), "Newline should remain an ordinary line break")
    try expect(!words.contains("››"), "Fast cue marker should not be displayed as a word")
    try expect(!words.contains("--"), "Slow cue marker should not be displayed as a word")
    try expect(Array(words.suffix(2)) == ["正", "常"], "Text after pace cues should be preserved")
}

func testTeleprompterLegacySlowCueTokenization() throws {
    let words = splitTextIntoWords("--(慢)旧稿兼容")

    try expect(words.first == TeleprompterPaceCue.slowToken, "Legacy slow cue should still become an internal token")
    try expect(!words.contains("--(慢)"), "Legacy slow cue marker should not be displayed as a word")
}

func testSpeechTrackingThreeWordAnchorCrossesLineBreaks() throws {
    let words = splitTextIntoWords("alpha beta\ngamma\ndelta epsilon")
    let sourceText = words.joined(separator: " ")
    let match = SpeechTrackingMatcher.immediateThreeWordAnchor(in: sourceText, spoken: "beta gamma delta")

    guard let match else {
        throw TestFailure.failed("Three consecutive spoken words should anchor across line breaks")
    }

    guard let deltaRange = sourceText.range(of: "delta") else {
        throw TestFailure.failed("Fixture should contain delta")
    }

    let expectedEndOffset = sourceText.distance(from: sourceText.startIndex, to: deltaRange.upperBound)
    try expect(match.matchedWordCount == 3, "Anchor should require and report three matched words")
    try expect(match.endOffset == expectedEndOffset, "Anchor should advance through the third matched word")
}

func testSpeechTrackingThreeCJKAnchorCrossesBreakTokens() throws {
    let words = splitTextIntoWords("甲|乙\n丙丁")
    let sourceText = words.joined(separator: " ")
    let match = SpeechTrackingMatcher.immediateThreeWordAnchor(in: sourceText, spoken: "甲乙丙")

    guard let match else {
        throw TestFailure.failed("Three consecutive CJK tokens should anchor across break tokens")
    }

    guard let thirdRange = sourceText.range(of: "丙") else {
        throw TestFailure.failed("Fixture should contain the third CJK token")
    }

    let expectedEndOffset = sourceText.distance(from: sourceText.startIndex, to: thirdRange.upperBound)
    try expect(match.matchedWordCount == 3, "CJK anchor should report three matched tokens")
    try expect(match.endOffset == expectedEndOffset, "CJK anchor should preserve source offsets across breaks")
}

let tests: [(String, () throws -> Void)] = [
    ("AudioStartGate", testAudioStartGate),
    ("RecordingTimeline", testRecordingTimeline),
    ("RecordingReadiness", testRecordingReadiness),
    ("ScriptAlignment", testScriptAlignment),
    ("ScriptAlignmentCumulativePartialsKeepAdvancing", testScriptAlignmentCumulativePartialsKeepAdvancing),
    ("ScriptAlignmentReanchorsAfterFastSpeechOutrunsWindow", testScriptAlignmentReanchorsAfterFastSpeechOutrunsWindow),
    ("UnconfirmedLargeAlignmentBlocksLegacyFallback", testUnconfirmedLargeAlignmentBlocksLegacyFallback),
    ("ScriptAlignmentDoesNotJumpToRepeatedTail", testScriptAlignmentDoesNotJumpToRepeatedTail),
    ("ScriptAlignmentUsesRenderedCharacterOffsets", testScriptAlignmentUsesRenderedCharacterOffsets),
    ("ScriptAlignmentManualDisplayReanchor", testScriptAlignmentManualDisplayReanchor),
    ("FastSpeechRecoveryThroughPartialGate", testFastSpeechRecoveryThroughPartialGate),
    ("BoundedDropOldestBuffer", testBoundedDropOldestBuffer),
    ("CameraWriterIngress", testCameraWriterIngress),
    ("RecordingMasterRange", testRecordingMasterRange),
    ("ASRPartialResultGate", testASRPartialResultGate),
    ("ASRRuntimeMetrics", testASRRuntimeMetrics),
    ("ASRAudioInputBridge", testASRAudioInputBridge),
    ("ResolvedRecordingTarget", testResolvedRecordingTarget),
    ("MetricsAndValidator", testMetricsURLAndMissingOutputValidation),
    ("RecordingPixelFormatPolicy", testRecordingPixelFormatPolicy),
    ("RecordingExportSettings", testRecordingExportSettings),
    ("RecordingArtifactOrganizer", testRecordingArtifactOrganizer),
    ("RecordingArtifactDeletion", testRecordingArtifactDeletion),
    ("CueRecordPathPolicy", testCueRecordPathPolicy),
    ("CueRecordProjectManifestAndConflictDetection", testCueRecordProjectManifestAndConflictDetection),
    ("CueRecordTempVaultWorkflow", testCueRecordTempVaultWorkflow),
    ("CueRecordVaultRepairer", testCueRecordVaultRepairer),
    ("TeleprompterLineBreakTokenization", testTeleprompterLineBreakTokenization),
    ("TeleprompterLineBreakDeduplication", testTeleprompterLineBreakDeduplication),
    ("TeleprompterPaceCueTokenization", testTeleprompterPaceCueTokenization),
    ("TeleprompterLegacySlowCueTokenization", testTeleprompterLegacySlowCueTokenization),
    ("SpeechTrackingThreeWordAnchorCrossesLineBreaks", testSpeechTrackingThreeWordAnchorCrossesLineBreaks),
    ("SpeechTrackingThreeCJKAnchorCrossesBreakTokens", testSpeechTrackingThreeCJKAnchorCrossesBreakTokens)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("PASS recording core tests")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
