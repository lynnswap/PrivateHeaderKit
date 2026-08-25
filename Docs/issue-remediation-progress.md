# Issue remediation progress

Base: `main` at `88f36e65223f874e8ce13fa4846ef517f1203146`

## Delivery order

1. #81 actionable bounded raw-helper crash diagnostics
2. #83 bounded Objective-C table and loaded-image reads

Each issue is delivered as an independent Ready PR targeting `main`. The next
issue starts only after the current PR is review-clean and merged.

## Current issue: #81

Branch: `codex/issue-81-actionable-crash-diagnostics`

Verified evidence:

- Signal-only helper failures currently persist only a generic termination
  sentence, without the child process identity needed to correlate an OS
  incident report.
- Long uncaught-exception output retains only the final eight nonempty lines,
  which discards the exception name/reason and first relevant frames.
- Successful helper diagnostics already use a typed report and must remain
  separate from arbitrary process output.

Design gate approved:

- No one process can observe every correlation fact for Simulator execution:
  `ProcessRunner` owns the `xcrun simctl spawn` wrapper transcript and terminal
  observation, while the raw helper owns its actual PID and loaded image.
- The helper writes a separate, invocation-authenticated startup handshake
  before loading target metadata. It contains only schema/invocation identity,
  actual PID, executable name and LC_UUID, and Unix epoch start microseconds.
  It is atomic, at most 2 KiB, and contains no path, producer text, device
  UDID, command, environment, or runtime root.
- The diagnostics report remains a completed typed-diagnostics contract. It is
  not converted into a two-phase process-state file.
- One bounded process-output value owns combined-stream ordering, head/tail
  retention, line and byte omission counts, terminal-safe rendering, and the
  inclusive output ceiling. Synthetic termination text is not classified as
  process-emitted output.
- `runPrivateHeaderKitRawDump` is the only failure-capsule builder because it
  knows execution mode and receives the helper handshake, bounded transcript,
  and wrapper termination. The capsule has at most 18 lines and 24 KiB, keeps
  the first and last eight diagnostic lines, and ends with one canonical
  concise headline.
- The capsule is persisted unchanged in the existing
  `runTargets.failureSummary`; no DB column or migration is added. Existing
  executor, resume, store, and final-summary paths remain the single transport.
- The current-process LC_UUID primitive moves to
  `PrivateHeaderKitExecutableResolution`, which is already shared by Tooling
  and RawDumpCore; the Mach-O walk is not duplicated.
- Crash Reporter correlation uses PID, executable UUID/name, helper start,
  capture time, termination observation, and signal when available. Incident
  ID is assigned after a crash and is therefore not guessed at run time.

Required validation:

- Long exception fixture retains the exception name/reason and first relevant
  frame plus the terminal tail.
- Signal-only fixture explicitly states that no process diagnostic was emitted
  and records the exact child identity/timing needed for correlation.
- Bounds hold for long lines, invalid UTF-8, interleaved streams, and high
  output volume.
- The capsule survives through `runTargets.failureSummary` and both terminal
  and nonterminal failed-target rendering.
