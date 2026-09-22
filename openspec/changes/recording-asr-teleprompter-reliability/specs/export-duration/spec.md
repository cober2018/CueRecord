## ADDED Requirements

### Requirement: Session-driven export duration
The final composition SHALL use the recording session master duration and SHALL NOT use the shortest camera, screen, or audio track as the output duration.

#### Scenario: Camera ends slightly early
- **WHEN** the screen and audio duration is 600 seconds and the camera duration is 599.8 seconds
- **THEN** the exported duration SHALL be 600 seconds within the configured tolerance, with the camera overlay held or hidden for the remaining interval

### Requirement: No implicit short cap
The recording and export pipeline SHALL not impose a hard-coded 180-second or equivalent three-minute limit.

#### Scenario: Long export
- **WHEN** a session lasts 10, 30, or 60 minutes
- **THEN** export SHALL attempt the full session range rather than truncating at 180 seconds
