# Issue remediation progress

Base: `main` at `05d7fe7a6bf1589c54918b5312654bbfa36090d3`

## Delivery order

1. #79 bounded Objective-C metadata reads
2. #80 bounded MachOKit chained-fixup reads
3. #81 actionable bounded raw-helper crash diagnostics
4. #83 bounded Objective-C table and loaded-image reads

Each issue is delivered as an independent Ready PR targeting `main`. A later
issue starts only after the earlier PR is review-clean and merged.

## Current issue: #79

Branch: `codex/issue-79-bounded-objc-metadata-reads`

Dependency bases:

- MachOObjCSection: `c7716997aa1ace417c43fcd15b5322dbbe79ec54`
- MachOSwiftSection: `122f50ee5196816a0d9d628a56a978636bc9bb03`

Verified evidence:

- Four iOS 27.0 `24A5390f` helpers terminate with
  `FileIO.FileIOError.offsetOutOfBounds` converted to a `try!` trap.
- `fileHandleAndOffset` validates only the starting location, not the complete
  scalar/layout range subsequently read.
- The generic nonoptional `_FileIOProtocol.read(offset:)` wrapper is the shared
  unsafe owner for class, category, protocol, method, property, and legacy
  relative-list scalar/layout reads.
- `ObjCIvarProtocol.offset(in:)` has a separate unconditional 4-byte read.
- Per-target process isolation contains the crash but cannot preserve the four
  affected targets or their artifacts.

Design gate approved:

- One neutral checked fixed-layout reader owns exact `UInt64` to `Int`
  conversion, overflow-safe full-range validation, fallible I/O, and
  `loadUnaligned`. The nonoptional generic wrappers are deleted so all 22
  fixed-size callers migrate under compiler enforcement.
- `ObjCMetadataReadResult` gains an additive Diagnostics SPI field-diagnostic
  channel. It does not overload the protocol-list or relative-member-list
  diagnostic contracts and does not add requirements to public protocols.
- Internal field reads distinguish `.absent`, `.value`, and `.failure`.
  Legitimate zero/RW representations stay silent; malformed external ranges
  produce typed failures without sentinel names or synthetic metadata.
- An unreadable instance RO field drops only that root class. An unreadable
  metaclass RO field keeps protocols, ivars, and instance members while
  omitting class members. An unreadable ivar offset drops only that ivar and
  preserves readable siblings in discovery order.
- File and loaded-image class-RO/ivar-offset paths use the same failure
  semantics. The PrivateHeaderKit accumulator remains the sole deduplication,
  256-entry cap, omission-count, and canonical-order owner.
- Variable-length `readDataSequence` tables are not folded into the fixed-size
  reader. They require count/byte budgets and a malformed-versus-empty outcome,
  so the remaining sequence and unchecked loaded-image table surfaces will be
  tracked as a separate hardening issue rather than hidden inside #79.

Required runtime gate:

- Re-run KoaMapper, SAML, NTKEsterbrookFaceBundleCompanion, and TextInput_zh on
  iOS 27.0 build `24A5390f` with no helper signal termination.
- Preserve readable siblings and record bounded typed degradation for malformed
  fields.
- Reconfirm #60 protocol recovery and #65 relative-member behavior.

Dependency progress:

- `e75be5d`: all audited fixed-size file metadata callers use the neutral
  checked layout reader; file/image ivar offsets no longer dereference an
  unproved range.
- `7ecc235`: deterministic exact-boundary, unaligned, truncated, 32/64-bit
  class-RO, and file/image ivar tests pass (59 focused tests, zero failures).
- Field diagnostics and single-pass sibling preservation are in progress on
  top of this green checkpoint.
- Independent review of `c7716997..7ecc235` found no actionable fixed-read
  defect; all 22 audited callers use the checked owner.
- MachOObjCSection final SHA `0d17e3d77556991dc128aa92547ea1b1ea8f9e2e`
  is pushed after a two-round clean codex-review; the first round found and
  fixed realized-metaclass version fallback.
- MachOSwiftSection coherence SHA
  `a7e5982ed7de5dab5dec76036682ea55825b77a8` is pushed after its CI-defined
  eight-suite filter and codex-review passed. Full-suite absolute-offset
  fixture drift reproduces unchanged on base `122f50e` and is not included in
  this pin-only change.
- PrivateHeaderKit dependency cohort is pinned in `55cdd0b`; consumer-side
  field diagnostic ingestion is in progress.

Observed malformed fields for the runtime gate:

- KoaMapper class RO: `0x4F800` in a `0x4DAA0` file.
- SAML class RO: `0x3B800` in a `0x3B620` file.
- TextInput_zh class RO: `0x45800` in a `0x44520` file.
- NTKEsterbrook ivar offsets: indices 8 and 9 read `0x96448` and `0x96450`
  in a `0x93540` file.
