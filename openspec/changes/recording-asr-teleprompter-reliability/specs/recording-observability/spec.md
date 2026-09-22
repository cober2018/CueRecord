## ADDED Requirements

### Requirement: Persisted diagnostic metrics
Each completed recording SHALL persist source durations, source PTS samples, camera FPS/drop counts, writer backpressure, audio/video drift, session duration, composition duration, and output duration under the existing raw-data metrics artifact.

#### Scenario: Completed recording
- **WHEN** recording and export finish
- **THEN** the metrics artifact SHALL contain enough values to distinguish fixed start offset, cumulative drift, and a truncated track

### Requirement: Recording preflight state
Before recording, the UI SHALL show whether the selected screen, enabled microphone, and enabled camera are ready; disabled optional sources SHALL be reported as off rather than failed.

#### Scenario: Enabled camera has no first frame
- **WHEN** camera overlay is enabled but the preview has not delivered a frame
- **THEN** the preflight state SHALL remain not ready and recording startup SHALL surface a clear camera error instead of silently producing a missing camera track

#### Scenario: Optional source is disabled
- **WHEN** microphone or camera is disabled by the user
- **THEN** that source SHALL not block recording readiness

### Requirement: Completed permission setup stays silent
After the required permissions have been granted and a workspace already exists, subsequent launches SHALL complete setup silently without showing the permission/setup wizard or reopening System Settings.

#### Scenario: Relaunch after granting permissions
- **WHEN** all required permissions are authorized, the workspace is already configured, and the persisted setup-complete flag is missing or stale
- **THEN** CueRecord SHALL persist setup completion and enter the main workspace without asking the user to grant permissions again
