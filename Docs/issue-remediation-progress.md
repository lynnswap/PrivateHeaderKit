# Issue remediation progress

Base: `main` at `3d31a8b70d656c1ebcf5299d71b33f7409047f54`

Delivery order:

1. #88 bounded file-backed Objective-C root sections
2. #87 bounded loaded Objective-C RW extension arrays

## Current issue: #88

Branch: `codex/issue-88-bounded-file-objc-roots`

Goal:

- Make file-backed class, nonlazy-class, protocol, category, nonlazy-category,
  and category2 root sections reject malformed raw coordinates, pointer tables,
  and referenced layouts without overflow, trapping I/O, or narrowing.
- Preserve readable root order and other root kinds while emitting typed
  degradation through the diagnostic owner introduced by #83.

Confirmed scope:

- Raw 32/64-bit file section and containing-segment coordinates.
- Regular Mach-O, dyld concatenated-file, and cache subfile/local offset
  semantics.
- Whole pointer-table and per-entry referenced-layout validation.
- Additive Diagnostics SPI file-root aggregate and legacy property parity.
- PrivateHeaderKit file-mode root diagnostic ingestion through the existing
  bounded member channel.

Required invariants:

- Reuse #83's neutral table reader, checked coordinate owner, entry/byte
  budgets, and `ObjCMetadataTableDiagnostic`; add no parallel budget or report.
- Absent/wrong-bitness is `nil` without a diagnostic; a legal empty section is
  `[]`; a malformed table is empty plus one table diagnostic; a malformed entry
  is omitted with an indexed diagnostic while later siblings remain ordered.
- Existing twelve file root properties keep their signatures and project the
  checked result; `ObjCSectionRepresentable` gains no requirement.
- Loaded roots, regular member tables, RW-extension arrays, loaded image-info,
  and C-string hardening are outside #88.

Validation gate:

- Deterministic 32/64 regular-file boundary, truncation, coordinate overflow,
  budget/remainder, and good/bad/good fixtures.
- Deterministic cache/subfile coordinate fixture or an equivalent targeted
  contract test at the offset owner.
- #60, #65, #79, #83 regressions; Debug/Release and Apple cross-builds.
- Exact MachOObjCSection → MachOSwiftSection → PrivateHeaderKit pin coherence.
- PrivateHeaderKit full tests, release-script tests, codex-review, Ready PR,
  GitHub review/CI, then merge to `main`.

Status:

- Implementation owner and cache/subfile semantics are under parallel audit.
