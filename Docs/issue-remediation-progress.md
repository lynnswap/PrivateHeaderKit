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

Design gate pending:

- Identify the single owner that observes ordered helper output, process
  identity, termination reason, and terminal time.
- Define a strict byte/line bound that preserves an actionable prefix and the
  termination tail without retaining unbounded output.
- Carry one failure capsule through raw dumping, persistence, and rendering
  without introducing mirror state or a second source of truth.
- Prove correlation fields against real Crash Reporter metadata without
  persisting user-private paths.

Required validation:

- Long exception fixture retains the exception name/reason and first relevant
  frame plus the terminal tail.
- Signal-only fixture explicitly states that no process diagnostic was emitted
  and records the exact child identity/timing needed for correlation.
- Bounds hold for long lines, invalid UTF-8, interleaved streams, and high
  output volume.
- The capsule survives through `runTargets.failureSummary` and both terminal
  and nonterminal failed-target rendering.
