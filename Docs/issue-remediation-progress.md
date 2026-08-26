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

- Design gate approved:
  - add Diagnostics SPI `ObjCFileRootReadResult` and
    `MachOFile.ObjectiveC.readRoots()` with the twelve existing root values and
    ordered table diagnostics;
  - use neutral `ObjCMetadataTableDiagnostic.RootSection` as the vocabulary,
    preserving `LoadedImageRootSection` and `FileRootSection` as source aliases;
  - add `.fileRoot(section:pointerWidth:)` without changing the loaded owner;
  - find raw `Section64`/`SegmentCommand64` or 32-bit equivalents together and
    validate coordinates without existential getters;
  - derive one canonical logical field offset: ordinary section file offset, or
    cache section address minus main-cache shared-region start;
  - resolve physical backing only through `fileHandleAndOffset(forOffset:)`,
    which adds an ordinary fat-slice header offset or maps to the correct cache
    subfile-local offset;
  - for every nonempty file-backed section, including cache images, require raw
    section file offset to equal the segment-mapped offset; allow a legal
    zero-size coalesced section to succeed before that equality or any backing
    lookup;
  - retain the shared count/byte budgets and per-entry checked resolver, and
    make all legacy root properties projections of their targeted checked read.
- A read-only survey of 6,288 Objective-C root sections in the current macOS
  shared cache found zero nonempty file/VM offset mismatches. General Mach-O and
  dyld-cache address conversion owners remain unchanged; #88 is isolated to the
  file-root boundary.
