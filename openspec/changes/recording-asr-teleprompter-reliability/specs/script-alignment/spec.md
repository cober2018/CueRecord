## ADDED Requirements

### Requirement: Mixed-script tokenization and normalization
Script alignment SHALL tokenize CJK characters individually, contiguous Latin/digit runs as words, ignore punctuation for matching, normalize case and full-width variants, and mark stage annotations as non-spoken.

#### Scenario: Chinese without spaces
- **WHEN** the script is `今天我们介绍AI`
- **THEN** the aligner SHALL expose CJK tokens and an `AI` word token without requiring spaces

### Requirement: Local tolerant alignment
The aligner SHALL compare recent ASR tokens against a bounded window around the current anchor and SHALL tolerate punctuation differences, small insertions, and omissions.

#### Scenario: Filler word
- **WHEN** ASR reports `大家好嗯今天我们来介绍`
- **THEN** the committed progress SHALL continue through the matching script region instead of becoming permanently stuck

### Requirement: Safe recovery
The aligner SHALL require consensus for large forward jumps and SHALL enter lost mode after sustained low-confidence matching instead of jumping arbitrarily.

#### Scenario: Skipped sentence
- **WHEN** the speaker skips one scripted sentence and then speaks a later sentence
- **THEN** the aligner SHALL re-anchor only after a high-confidence consecutive match and SHALL report a recoverable state transition

#### Scenario: Cumulative partial after committed progress
- **WHEN** successive ASR partials repeat already committed text and append newly spoken tokens
- **THEN** the aligner SHALL match the recent uncommitted tail and continue advancing instead of comparing the entire repeated prefix at the new anchor

#### Scenario: Fast speech outruns the local window
- **WHEN** live ASR continues updating with a distinctive later phrase beyond the normal local look-ahead
- **THEN** the aligner SHALL enter recovery, widen the bounded forward search, and commit the later phrase only after high-confidence consecutive agreement

#### Scenario: Recently spoken phrase repeats near the end
- **WHEN** the current ASR tail matches text immediately behind the committed position and an identical phrase appears much later or at the end of the script
- **THEN** the aligner SHALL keep the nearer position and SHALL NOT mark the distant duplicate or the whole script as completed

### Requirement: Exact display-coordinate projection
Committed token progress SHALL project to the same character coordinate space used by the rendered teleprompter text, including inserted token separators and skipped stage annotations.

#### Scenario: CJK display separators
- **WHEN** the rendered script is produced by joining CJK display tokens with spaces
- **THEN** a committed alignment SHALL end at the matching rendered token boundary rather than a raw-token character count

#### Scenario: Explicit user anchor
- **WHEN** the user taps a rendered word to continue from that location
- **THEN** both the visible highlight and the aligner's committed token anchor SHALL move to the tapped location before later ASR partials are processed

### Requirement: Delivered partial integration
Alignment recovery SHALL work with the actual partial-result delivery rules, including duplicate suppression and throttling.

#### Scenario: Fast speech recovery through the partial gate
- **WHEN** a later cumulative partial changes after the throttle interval and points beyond the normal look-ahead window
- **THEN** the delivered partials SHALL still establish guarded consensus and re-anchor without requiring an identical duplicate result

#### Scenario: Unconfirmed large jump reaches legacy fallback
- **WHEN** the token aligner produces a large forward candidate that has not passed consensus
- **THEN** the legacy matcher SHALL NOT bypass that guard before the aligner enters lost mode
