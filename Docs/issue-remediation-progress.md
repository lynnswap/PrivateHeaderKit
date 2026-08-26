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

## Design gate

Approved against MachOObjCSection
`8f0ff76f02c0865422a72662177b5e687e43522d`.

Runtime representation contract:

- Apple objc4 `951.7` and current `main` encode `class_rw_ext_t` list arrays
  as a native-width `PointerUnion4`: low tags `0 = single`, `1 = pointer
  array`, `2 = relative list-of-lists`, `3 = reserved/dummy`; the payload is
  the remaining address after clearing the low two bits.
- Pointer-array storage is `UInt32 count` followed by native-width list
  pointers: header/table offset and pointer stride are both 4 bytes for 32-bit
  and 8 bytes for 64-bit. A readable zero-count array is legal empty.
- Relative storage has an 8-byte entry-size/count header and ordered 8-byte
  entries. Unloaded target images are normal omissions; other entry failures
  remain diagnostics while later entries continue.
- Raw zero is absent. Nonzero tag-only values, null array entries, tag 3, bad
  alignment, and unrepresentable addresses are malformed input, not empty.
- Apple documents `PointerUnion4` as non-stable ABI. Unknown encodings must stop
  as typed unsupported failures; no fallback representation is inferred.

Owner map:

- One neutral `ObjCLoadedListArrayReader` owns PAC/TBI stripping while retaining
  the low tag, exact address/displacement arithmetic, representation routing,
  alignment, pointer width, array header/count/table reads, list-specific
  validation, ordering, and diagnostics.
- The existing `ObjCMetadataTableReader` remains the sole count/byte-budget and
  complete-range owner. Its loaded-image reads must copy bounded bytes with
  `mach_vm_read_overwrite` and decode the local snapshot instead of probing and
  then directly dereferencing mutable runtime memory.
- Existing checked method/property/protocol list readers validate referenced
  headers and complete inner tables. Existing relative resolvers own outer
  count/stride/range and good/bad/good entry resolution.
- Existing raw-pointer initializers remain for their checked callers, but the
  RW-array path never calls one before a checked local header read.
- Rename the internal UInt32/UInt64 widening protocol from root-specific
  `ObjCRootPointer` to neutral `ObjCMetadataPointer`; add no parallel widening
  or budget implementation.

Diagnostics and public Diagnostics SPI:

```swift
@_spi(Diagnostics)
public enum ObjCLoadedListArrayRepresentation: Sendable, Equatable {
    case single, array, relative
}

@_spi(Diagnostics)
public struct ObjCLoadedListArrayEntry<List> {
    public let image: MachOImage
    public let list: List
}

@_spi(Diagnostics)
public struct ObjCLoadedListArrayReadResult<List, RelativeList> {
    public let representation: ObjCLoadedListArrayRepresentation?
    public let entries: [ObjCLoadedListArrayEntry<List>]
    public let relativeListList: RelativeList?
    public let tableDiagnostics: [ObjCMetadataTableDiagnostic]
}
```

- `ObjCClassRWDataExtProtocol` adds `readMethodLists(in:)`,
  `readPropertyLists(in:)`, and `readProtocolLists(in:)`.
- `ObjCMethodArray`, `ObjCPropertyArray`, and `ObjCProtocolArrayProtocol` add
  Diagnostics SPI `readLists(in:)` so direct queries and extension-field
  queries share the same owner.
- `entries` contains `(image, list)` membership in source order for every
  representation. `relativeListList` is non-nil only after a checked relative
  header read. Internal representation storage keeps those states consistent.
- Reuse `ObjCMetadataTableDiagnostic`, adding owner
  `.loadedRWExtension(kind:pointerWidth:)` and the minimum relative-image
  failure vocabulary. Do not add a parallel diagnostic hierarchy: these are the
  same table/entry provenance and structural failures as the existing reader.

Observable failure semantics:

- raw zero: representation `nil`, no entries, no diagnostics; legacy field
  query returns `nil`;
- legal empty array/relative table: present representation, empty entries, no
  diagnostics;
- malformed whole storage/table: present representation when the tag is known,
  empty entries, one table diagnostic;
- malformed pointer-array or relative entry: omit only that entry, retain later
  entries in order, and emit one indexed diagnostic;
- tag 3: no representation or dereference, one unsupported table diagnostic;
- legacy `lists(in:)` continues to return only single/array lists and returns
  `[]` for relative storage; legacy `relativeListList(in:)` continues to return
  only the relative wrapper. All legacy methods project the checked outcome.

Concurrency boundary:

- Each header/table/reference read is copied safely into local bytes, so a
  freed/unmapped pointer degrades instead of trapping. The private objc
  `runtimeLock` is unavailable, so the API does not claim one atomic snapshot
  across the extension word and every referenced list. Concurrent mutation may
  yield a partial result plus diagnostics, never a fallback guess.

Implementation non-goals:

- Do not make PrivateHeaderKit consume RW-extension arrays; its current raw dump
  uses class RO member lists.
- Do not change C-string reads, objc runtime locking, RO tag semantics, or
  unrelated raw initializer visibility.
- Do not treat tag `1` in class RO as the RW-extension pointer-array encoding;
  the two owners have different contracts.

Validation gate:

- Deterministic 32/64 loaded-image fixtures for every tagged representation,
  exact boundaries, truncation, excessive counts, unreadable pointers, and
  good/bad/good ordering.
- #60, #65, #79, #83, and #88 regressions; Debug/Release and Apple
  cross-builds.
- Exact MachOObjCSection → MachOSwiftSection → PrivateHeaderKit cohort pins.
- A disposable, safe-copy-only exact iOS 27 beta `24A5390f` runtime probe must
  confirm tags 0/1/2, 64-bit array header offset/stride, empty semantics, and
  public Objective-C runtime count parity; restore the prior runtime match and
  delete all probe artifacts afterward. arm64e authentication remains an
  explicitly unverified condition because the Simulator is arm64.
- PrivateHeaderKit full tests, release-script tests, codex-review, Ready PR,
  GitHub review/CI, and merge to `main`.
