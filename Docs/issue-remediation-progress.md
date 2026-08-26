# Issue remediation progress

Base: `main` at `600a3c275621dde24ac6d9b72d5cfec7fedb0f00`

## Current issue: #87

Branch: `codex/issue-87-bounded-loaded-objc-rw-arrays`

Goal:

- Make loaded `class_rw_ext_t` method, property, and protocol list fields
  validate their tagged representation, table ranges, and referenced lists
  before dereferencing runtime memory.
- Preserve existing public query signatures as compatibility projections while
  exposing typed recoverable diagnostics from one checked owner.

Confirmed scope:

- Single-list, pointer-array, and relative-list tagged representations.
- 32/64-bit pointer width, exact address arithmetic, complete readable ranges,
  shared count/byte budgets, and ordered good/bad/good preservation.
- MachOObjCSection implementation, its direct tests, coherent downstream pins,
  and contract documentation required by the final consumer diff.

Non-goals:

- Referenced C-string payload hardening.
- Reworking regular member tables or loaded/file root sections completed by
  #83 and #88.
- Attributing the original iOS 27 failures to this currently unobserved surface.

Design gate: pending evidence-first owner and runtime-ABI audits.

Validation gate:

- Deterministic 32/64 loaded-image fixtures for every tagged representation,
  exact boundaries, truncation, excessive counts, unreadable pointers, and
  good/bad/good ordering.
- #60, #65, #79, #83, and #88 regressions; Debug/Release and Apple
  cross-builds.
- Exact MachOObjCSection → MachOSwiftSection → PrivateHeaderKit cohort pins.
- PrivateHeaderKit full tests, release-script tests, codex-review, Ready PR,
  GitHub review/CI, and merge to `main`.
