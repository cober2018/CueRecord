## ADDED Requirements

### Requirement: Shared recording timeline
The recording system SHALL map screen, camera, microphone, and system-audio samples onto one session-relative timeline using their presentation timestamps, and SHALL NOT derive media time from frame count or wall-clock `Date` values.

#### Scenario: Dropped camera frame
- **WHEN** camera sample PTS advances from 0.066 seconds to 0.133 seconds because an intermediate frame is absent
- **THEN** the mapped timestamp SHALL remain 0.133 seconds and SHALL NOT be rewritten as 0.099 seconds

### Requirement: Monotonic source mapping
The timeline SHALL reject samples before the session origin and samples whose mapped PTS is earlier than the previous accepted PTS for the same source.

#### Scenario: Backward sample
- **WHEN** a camera sample arrives with a PTS earlier than the last accepted camera sample
- **THEN** the sample SHALL be dropped and a diagnostic counter SHALL increase
