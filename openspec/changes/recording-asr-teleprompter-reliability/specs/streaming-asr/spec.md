## ADDED Requirements

### Requirement: Independent ASR audio path
The system SHALL keep the recording audio path at its configured recording quality while feeding ASR an independent 16 kHz mono stream, and ASR decode SHALL run off MainActor and off the media writer queue.

#### Scenario: Recording with live recognition
- **WHEN** microphone capture is active and the user is recording
- **THEN** the writer SHALL receive the recording-quality samples while the recognizer receives resampled 16 kHz mono chunks without blocking either path

### Requirement: Sherpa provider compatibility
The existing sherpa-onnx streaming recognizer SHALL remain the default provider and SHALL publish partial and endpoint results through a provider boundary.

#### Scenario: Model is available
- **WHEN** the bundled sherpa model initializes successfully
- **THEN** the existing recognition workflow SHALL continue to produce partial text and endpoint events through the provider interface
