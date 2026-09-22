#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/cuerecord-recording-core-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/cuerecord-swift-module-cache"
mkdir -p "$MODULE_CACHE"

xcrun swiftc \
  "$ROOT/CueRecord/Storage/CueRecordPathPolicy.swift" \
  "$ROOT/CueRecord/Storage/CueRecordProjectManifest.swift" \
  "$ROOT/CueRecord/Storage/CueRecordProjectStore.swift" \
  "$ROOT/CueRecord/Storage/CueRecordVaultRepairer.swift" \
  "$ROOT/CueRecord/Teleprompter/CueTextTokenizer.swift" \
  "$ROOT/CueRecord/Teleprompter/ScriptAlignment.swift" \
  "$ROOT/CueRecord/Teleprompter/SpeechTrackingMatcher.swift" \
  "$ROOT/CueRecord/Recording/Models/RecordingEditDecision.swift" \
  "$ROOT/CueRecord/Recording/Models/RecordingState.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/ResolvedRecordingTarget.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingSync.swift" \
  "$ROOT/CueRecord/Recording/Core/Camera/CameraFrameBuffer.swift" \
  "$ROOT/CueRecord/Recording/Core/Camera/CameraWriterIngress.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingTimeline.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingMasterRange.swift" \
  "$ROOT/CueRecord/ASRPartialResultGate.swift" \
  "$ROOT/CueRecord/ASRRuntimeMetrics.swift" \
  "$ROOT/CueRecord/ASRAudioInputBridge.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingPixelFormatPolicy.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingMetrics.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingArtifactOrganizer.swift" \
  "$ROOT/CueRecord/Recording/Core/Recording/RecordingOutputValidator.swift" \
  "$ROOT/Tests/RecordingCoreTests/main.swift" \
  -module-cache-path "$MODULE_CACHE" \
  -o "$OUTPUT"

"$OUTPUT"
