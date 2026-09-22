## ADDED Requirements

### Requirement: Stable progress state
Teleprompter UI state SHALL distinguish speculative progress from committed progress; cross-line scrolling SHALL use committed progress and SHALL not perform ASR or alignment work on MainActor.

#### Scenario: Changing partial result
- **WHEN** successive partial results revise the last few words
- **THEN** speculative progress MAY move locally, but committed cross-line progress SHALL not oscillate backward and forward

### Requirement: Lost and manual recovery
The progress controller SHALL expose tracking, uncertain, and lost states and SHALL allow a later high-confidence match or explicit user anchor to recover tracking.

#### Scenario: No match for 1.5 seconds
- **WHEN** speech is present but no trusted alignment exists for at least 1.5 seconds
- **THEN** the controller SHALL freeze the current committed position and enter lost/uncertain recovery rather than auto-scrolling blindly
