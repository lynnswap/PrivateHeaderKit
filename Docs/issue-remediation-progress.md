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

Confirmed root cause:

- All three binaries contain a valid sparse `starts_in_image` table with
  `seg_info_offset = [0, 0x10, 0]`. Apple dyld treats a zero entry as the
  normal absence of fixups for that segment.
- MachOKit instead reads each zero entry as a `starts_in_segment` record at
  the start of `starts_in_image`. That aliases the real record's page size as
  a bogus `page_count` of `0x4000`, and `pages(of:)` walks past the 64 KiB
  mapping before any page-size guard runs.
- `fixupPointersCache` exposed the older parser defect by eagerly traversing
  every returned segment. The metadata readers are downstream observers, not
  the owner of this failure.

Design gate approved:

- A shared internal bounded byte reader owns all fixup-blob ranges for both
  file-backed and loaded-image table parsing. It performs exact integer
  conversion, checked arithmetic, unaligned scalar loads, bounded arrays, and
  bounded NUL-terminated strings before forming a pointer or collection.
- The starts-table parser treats a zero segment offset as normal absence,
  preserves the original Mach-O segment index for nonzero records, and
  validates each record's declared size, page prefix, and complete flexible
  start-entry storage.
- The file chain walker maps a parsed record through its Mach-O segment index;
  segment file offset/size owns disk reads. Page starts, multi-start indices
  and termination, pointer width, and every `next * stride` advance must stay
  inside the current page and file-backed segment.
- Existing public nonthrowing APIs retain their signatures and project checked
  results as `nil` or empty collections. Internal typed failures retain the
  distinction between absence and invalid input; an additive support SPI may
  expose preflight validation without adding a protocol requirement.
- A malformed segment/page/chain cannot discard validated siblings in the
  compatibility projection. Imports remain all-or-nothing because a partial
  table would shift ordinal identity.
- `pointers(of:in:)` and `pointer(for:in:)` share one checked walker. The
  unconditional file-slice/read traps in that path and optional rebase
  resolution are removed.

Deterministic validation gate:

- Exact sparse-table regression `[0, 0x10, 0]`, retaining segment index 1 and
  its valid pointer chain.
- Truncated header/segment-offset/page tables and out-of-range declared sizes.
- Valid and invalid multi-start tables, including bad indices and missing
  `START_LAST`.
- Segment slice overflow, chain starts outside a page, pointer-width crossing,
  and `next` crossing a page.
- File/image parity for checked table parsing and compatibility projections.
- Existing public API clients compile without source changes.

Dependency delivery gate approved:

- Publish the MachOKit fix from the exact pinned base to the `lynnswap` fork.
- Keep the direct dependency's original MxIris URL but change its requirement
  to the fork commit's exact revision. A tracked repo-local SwiftPM mirror maps
  both MxIris URL spellings (with and without `.git`) to the `lynnswap` fork.
- SwiftPM 6.3.3 probes confirmed that the revision requirement unifies the
  existing MachOKitExtensions, MachOObjCSection, MachOSwiftSection, and
  swift-demangling ranges to one checkout without an identity-conflict warning.
- `Package.resolved` retains the original URL and an unversioned exact revision;
  the existing #79 Objective-C/Swift reader cohort remains unchanged.
- The mirror is intentionally a root-package build contract. PrivateHeaderKit
  is an executable package; supporting it as a transitive library dependency
  is outside this issue's distribution scope.

Required runtime gate:

- Re-run PosterBoardUI, PrivateSearchProtocols, and UserManagementUI on iOS
  27.0 build `24A5390f` with zero helper signals.
- Preserve readable metadata/artifacts, or produce a normal bounded target
  failure when a target cannot be decoded.

Implemented dependency:

- MachOKit revision: `e0e0b30187ae74f2088d932845c8ddac2c79f36c`
- Dependency branch: `codex/issue-80-bounded-chained-fixups`
- Synthetic safety suite: 28 tests pass.
- Exact binary oracle: 108 / 57 / 34 fixup pointers for PosterBoardUI,
  PrivateSearchProtocols, and UserManagementUI, matching Apple `dyld_info`.
- Branch-wide codex-review against `fec9503` completed with no findings after
  fixing graph-level header, segment, multi-start, duplicate, bind-ordinal,
  and pointer-format invariants.

PrivateHeaderKit integration:

- The raw helper preflights file-backed chained fixups before Objective-C or
  Swift metadata readers can consume resolver projections.
- The direct revision pin and tracked two-spelling SwiftPM mirror resolve to
  one MachOKit checkout without an identity-conflict warning.
- HelperProtocol tests: 13 passed.
- RawDump tests: 89 passed.

Runtime gate completed:

- Run: `run-d777ff0f-8964-4129-bc2c-accdd472fad6`
- Generation: `generation-6f89aee6-9a2d-4a3c-8ed1-7d2c2004da91`
- All three targets completed with 6 / 1 / 3 artifacts and no failure summary.
- SQLite integrity: `ok`; run warnings: 0; new helper incident reports: 0.
- Runtime match override restored to default and the run-owned Simulator was
  deleted. The isolated output was moved to Trash at
  `/Users/kn/.Trash/privateheaderkit-issue80-smoke-yyKic6`.
