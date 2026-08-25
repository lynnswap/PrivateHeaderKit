# Issue remediation progress

Base: `main` at `101748f62fa27d6851b4284df7cafc721081fa5c`

Delivery order:

1. #83 bounded regular Objective-C tables and loaded roots
2. #87 bounded loaded Objective-C RW extension arrays

## Current issue: #83

Branch: `codex/issue-83-bounded-objc-metadata-reads`

Goal:

- Make variable-length file-backed Objective-C tables and loaded-image root/list
  reads reject malformed external ranges without arithmetic overflow, unchecked
  dereference, or raw-helper termination.
- Preserve readable sibling metadata and discovery order while emitting bounded
  typed degradation through the existing diagnostic owner.

Confirmed scope from the issue:

- File-backed method, property, and ivar table reads.
- Loaded-image class, category, and protocol roots and member-list headers.
- Direct relative method/property list queries that bypass checked traversal.
- Deterministic 32/64-bit file and loaded-image boundary fixtures.

Dependency bases:

- MachOObjCSection:
  `0d17e3d77556991dc128aa92547ea1b1ea8f9e2e`
- MachOSwiftSection:
  `a7e5982ed7de5dab5dec76036682ea55825b77a8`

Verified evidence:

- Nine production file-backed method/property/ivar branches use the same
  `readDataSequence` helper, which performs unchecked count/stride arithmetic,
  narrowing, `try!` I/O, and aligned loads.
- Regular class, protocol, and category member-list headers collapse unreadable
  non-null storage into absence; their loaded decoders do not prove the full
  table range.
- All twelve loaded class/protocol/category root properties read section pointer
  tables and referenced layouts without a complete image-range proof. A
  good/bad/good root sequence terminates at the bad pointer.
- Singular method/property relative-list queries bypass the checked plural
  resolver added for #65.
- File/image `__objc_methlist` iterators repeat unchecked header, list-size,
  alignment, and entry-size operations on the same public table surface.
- Valid method table ranges can still contain arithmetic-poisoned entries:
  cache IMP subtraction and relative entry offsets can underflow/overflow or
  manufacture zero-offset fallback metadata.
- The existing protocol reader already owns the correct 65,536-entry / 512-KiB
  budget, checked arithmetic, full file/image range proof, and unaligned decode.

Design gate approved:

- Rename/generalize the protocol-only table reader into one neutral
  `ObjCMetadataTableReader`. It owns exact offset/count/stride conversion,
  checked multiplication/addition, the existing entry/byte budgets, complete
  file/image range proof, fallible I/O/probing, unaligned decode, and checked
  logical entry offsets.
- Delete all four `readDataSequence` overloads once their nine production call
  sites migrate. Method/property/ivar direct APIs become thin compatibility
  projections over a typed table outcome; a legal zero-count table is success
  with `[]`, while malformed/unreadable storage is failure.
- Nonempty entry-size lists validate the ABI stride before decoding. A zero-count
  list does not validate unused stride/alignment, preserving #65 semantics.
- Method entry decoding uses checked cache/displacement/entry-offset arithmetic.
  A malformed entry is skipped with an indexed failure; no `?? 0` fallback is
  used, and later siblings retain discovery order.
- Add an independent Diagnostics SPI `ObjCMetadataTableDiagnostic` and additive
  `ObjCMetadataReadResult.tableDiagnostics`. It represents class/protocol/
  category member tables without changing the exhaustive #60 protocol, #65
  relative-member, or #79 fixed-field diagnostic enums.
- Add a concrete Diagnostics SPI root read on `MachOImage.ObjectiveC` covering
  the twelve existing root properties plus ordered root-table diagnostics.
  Existing properties keep their signatures and project the same per-section
  checked owner; `ObjCSectionRepresentable` gains no requirement.
- The loaded root owner reads raw 32/64-bit section fields with exact conversion,
  checks slide/address/range arithmetic, rejects pointer-size remainders, applies
  the common budget, probes the complete pointer table, and reads each referenced
  layout independently so good/bad/good roots survive in order.
- Loaded metaclass/superclass/category-class layouts use the same checked layout
  primitive because they are reachable from retained roots and share the same
  full-range invariant.
- Relative plural and singular method/property queries share one per-entry
  resolver. Unloaded entries are normal omissions; unavailable or malformed
  entries remain typed in the plural path and project to `nil` in the singular
  compatibility API.
- File/image method-section iterators use checked header/list size/alignment and
  stop safely on structural failure instead of trapping.
- PrivateHeaderKit consumes root and per-subject table diagnostics through the
  existing `RawDumpObjCDiagnosticsAccumulator` member channel. It adds no report,
  set, cap, omission counter, sorting owner, persistence path, or DB migration.

Observable semantics:

- absent section / wrong bitness: `nil`, no diagnostic;
- present empty root section: `[]`, no diagnostic;
- malformed whole root/member table: no values from that table plus one table
  diagnostic;
- malformed root/member entry: omit that entry, append an indexed diagnostic,
  and continue later siblings in source order;
- zero member pointer: absent, no diagnostic;
- nonzero unreadable header/table: failure, never absence or regular fallback;
- malformed singular relative query: `nil`;
- public compatibility APIs discard typed diagnostics but use the same checked
  outcome and therefore cannot re-enter an unsafe decoder.

Explicit exclusions:

- Hostile C-string pointer hardening remains outside this table/layout change,
  matching MachOObjCSection Evolution 0007. No claim is made that arbitrary
  loaded strings are fully hardened.
- Runtime RW-extension array-of-lists has a distinct tagged array ABI and is not
  used by PrivateHeaderKit's current metadata traversal. Its unchecked public
  queries are tracked by #87 rather than receiving a guessed #83 patch.
- No current iOS 27 crash is attributed to #83; deterministic malformed fixtures
  are the correctness gate rather than a claimed crash recovery.

Required regression coverage:

- Existing protocol-list behavior from #60.
- Existing relative-member behavior from #65.
- Existing fixed-field behavior from #79.
- Diagnostics SPI compile coverage and legacy direct-query parity.
- 32/64-bit file and loaded-image exact-boundary, truncation, excessive-count,
  byte-budget, arithmetic-overflow, and good/bad/good fixtures.
- Exact dependency coherence: MachOObjCSection, MachOSwiftSection, then
  PrivateHeaderKit pins and pin-contract tests.

Dependency progress:

- MachOObjCSection core checkpoint
  `748070697d20cace20618ef8bc9f6b4d10949c69` centralizes the neutral file/image
  table reader, preserves #60 failure precedence, migrates the nine file table
  paths plus image member tables, makes method arithmetic fallible, and removes
  the unsafe `readDataSequence` owner.
- At that checkpoint `swift build`, 57 protocol safety tests, and 17 combined
  relative-member/fixed-field regression tests pass.
- Phase A continues checked direct projections, method iterators, and table/file
  fixtures. Phase B is stacked from the core checkpoint for loaded roots,
  relationships, regular headers, relative direct parity, and loaded fixtures.
- MachOObjCSection Phase A checkpoint
  `c1a78f8ed6f6aaa592317bdd553129b10abb29af` adds no-trap file/image method
  iterators, checked `EntrySizeList` projections, empty-before-stride semantics,
  indexed property-coordinate failures, section read cleanup, and 18 direct
  reader/member/iterator tests.
- Phase A validation: debug/release builds and 90 focused new + #60/#65/#79
  tests pass; unsafe-pattern and diff checks are clean. The full suite reaches
  an unchanged absolute `/Users/JH/Downloads/iOS18.5-SwiftUI` fixture dependency
  and then traps in the identical base test force unwrap, so that environment
  fixture is not changed by #83.
- A follow-up checkpoint is restoring the public `EntrySizeList.size` `Int`
  signature while retaining the internal fallible size owner; malformed legacy
  projections return zero instead of changing public source compatibility.
- MachOObjCSection Phase A final
  `309091379d653f4cbf7d07aab7faa1269736b61c` preserves the public `Int`
  signatures for entry size, count, and size while keeping iterators on the
  internal fallible size API. Malformed projections return zero; legal empty
  lists return the header size. The focused regression set passes 92 tests.
