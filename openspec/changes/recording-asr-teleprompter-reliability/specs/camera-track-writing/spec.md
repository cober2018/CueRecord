## ADDED Requirements

### Requirement: Non-blocking camera writing
Camera capture SHALL deliver raw samples to a bounded background writer queue without synchronously rendering or writing on MainActor.

#### Scenario: UI is busy
- **WHEN** the MainActor is busy rendering the preview or teleprompter
- **THEN** camera raw writing SHALL continue on its dedicated queue unless the writer itself is backpressured

### Requirement: Explicit drop accounting
The camera pipeline SHALL distinguish capture, queue-overflow, writer-not-ready, and non-monotonic-PTS drops in metrics.

#### Scenario: Writer backpressure
- **WHEN** the camera writer is not ready for another sample
- **THEN** the sample SHALL be dropped without changing later sample PTS and the writer-not-ready metric SHALL increase
