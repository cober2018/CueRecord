## ADDED Requirements

### Requirement: Persisted diagnostic metrics
Each completed recording SHALL persist source durations, source PTS samples, camera FPS/drop counts, writer backpressure, audio/video drift, session duration, composition duration, and output duration under the existing raw-data metrics artifact.

#### Scenario: Completed recording
- **WHEN** recording and export finish
- **THEN** the metrics artifact SHALL contain enough values to distinguish fixed start offset, cumulative drift, and a truncated track
