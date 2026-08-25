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
