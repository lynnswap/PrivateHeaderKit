# Issue remediation progress

Base: `main` at `0d109cda22193020914a70069c3e0b5c07c31e8b`

## Delivery order

1. #80 bounded MachOKit chained-fixup reads
2. #81 actionable bounded raw-helper crash diagnostics
3. #83 bounded Objective-C table and loaded-image reads

Each issue is delivered as an independent Ready PR targeting `main`. A later
issue starts only after the earlier PR is review-clean and merged.

## Current issue: #80

Branch: `codex/issue-80-bounded-chained-fixups`

Dependency base:

- MachOKit: `fec9503cdf3d595ef8cf4abac1602e299a8c3be4` (`0.52.101`)

Verified evidence:

- PosterBoardUI, PrivateSearchProtocols, and UserManagementUI terminate with
  `SIGSEGV` while building or walking file-backed chained-fixup tables.
- The common owner is `MachOFile.DyldChainedFixups.pages(of:)` and
  `pointers(of:in:)`, before the Objective-C/Swift metadata-specific caller.
- Current code forms metadata-sized unsafe buffers and contains an
  unconditional file-slice acquisition.
- Per-target process isolation contains the crash, but all three targets have
  zero artifacts and are absent from the committed generation.

Design gate pending:

- Map every external offset/count boundary in starts-in-image,
  starts-in-segment, page-start, multi-start, and chain walking.
- Define one checked table/range owner and typed failure semantics without
  constructing an invalid pointer or indexing before validation.
- Preserve compatibility for existing public query APIs while making raw
  helper traversal fail normally instead of signaling.

Required runtime gate:

- Re-run PosterBoardUI, PrivateSearchProtocols, and UserManagementUI on iOS
  27.0 build `24A5390f` with zero helper signals.
- Preserve readable metadata/artifacts, or produce a normal bounded target
  failure when a target cannot be decoded.
