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

Implementation completed:

- `BoundedProcessOutput` now owns terminal-safe combined-stream head/tail
  retention and raw-source omission lower bounds. `StreamingCommandResult`
  carries that value plus the wrapper termination-observation timestamp.
- Every raw helper invocation has a distinct process-handshake report. The
  helper writes its validated PID, executable name, LC_UUID, invocation ID,
  and start timestamp before loading the requested target.
- `runPrivateHeaderKitRawDump` consumes and removes both reports on every
  success/failure/throw path and builds one bounded failure capsule on a
  nonzero helper result.
- Simulator child termination is recognized only from the exact final
  `simctl` line when the wrapper's normal exit status corroborates the POSIX
  `128 + signal` convention. The wrapper line is then replaced by the typed
  child-signal field instead of being duplicated as arbitrary output.
- Executor/store/rendering tests confirm that the exact capsule is the existing
  `runTargets.failureSummary`; no persistence schema changed.

Validation completed:

- `swift test --force-resolved-versions` passed after integration.
- The focused capsule suite passed with 8 tests after the measured `simctl`
  exit-status correction.
- A release-mode run against the exact iOS 27.0 beta `24A5390f` runtime and
  `AXSpringBoardServerInstance` reproduced its expected uncaught exception as
  run `run-d455b470-6ec7-4955-9157-7bc90c082a47`.
- SQLite retained the exception name/reason, first frames, omission marker,
  terminal frames, and canonical headline in 17 lines / 1,725 bytes. Database
  integrity was `ok` with no foreign-key violations.
- The headline reported `child_signal(6)`, wrapper status `134`, helper PID
  `28709`, LC_UUID `31c43965-06ab-3d01-b413-8db66023c8d9`, start microseconds,
  and termination-observation microseconds.
- Crash Reporter independently recorded the same PID, LC_UUID, helper name,
  and `SIGABRT`/code 6, with capture time between helper start and observed
  termination.
- The run-owned Simulator was deleted and the SDK-runtime override was restored
  to its default. The isolated output was moved recoverably to
  `/Users/kn/.Trash/privateheaderkit-issue81-runtime-MTbctA`.
