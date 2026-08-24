# Issue remediation progress

Base: `main` at `6bdce4438828938cf8ae8e5a1aed1b31015bba78`

## Delivery order

1. #60 canonical Objective-C protocol conformances
2. #79 bounded Objective-C metadata reads
3. #80 bounded MachOKit chained-fixup reads
4. #81 actionable bounded raw-helper crash diagnostics

Each issue is delivered as an independent Ready PR targeting `main`. A later
issue does not enter implementation until the earlier issue has a review-clean
PR.

## Current issue: #60

Status: design gate complete on branch
`codex/issue-60-ios-protocol-aliases`.

Verified evidence:

- The `v0.5.4` iOS 27.0 `24A5390f` run published `ARAnchor` without
  `ARDaemonSecureCoding` and `ARAnchorCopying`.
- The persisted warnings classify both dropped entries as
  `missingBackingData`.
- PR #63 previously recovered only exact runtime-registry pointer matches.
- The dependency owner is MachOObjCSection's loaded-image protocol list reader;
  PrivateHeaderKit warning propagation is not the correction point.
- Apple objc4 defines raw `protocol_ref_t` values as potentially unremapped and
  resolves a noncanonical reference by its raw `mangledName`. Therefore exact
  address membership in `objc_copyProtocolList` is not a valid identity
  invariant.
- A focused `24A5390f` runtime trace proved that the missing ARKit protocol
  objects and their names are readable in the active main dyld-cache mapping.
  `ARDaemonSecureCoding` and `ARAnchorCopying` both carry flags `0x60000000`,
  while `objc_getProtocol(rawName)` returns `nil`.
- In objc4, those flags are `PROTOCOL_FIXED_UP_1 | PROTOCOL_IS_CANONICAL`, and
  `remapProtocol` returns a canonical raw pointer before consulting the runtime
  name registry. The runtime lookup is therefore not an admission requirement
  for a cache-owned canonical protocol.

Design contract:

- Probe the raw protocol layout and verify that its declared size covers the
  mandatory prefix through `flags`.
- For a canonical pointer, require the protocol object and mangled name to be
  in active dyld-cache mappings, and bound the UTF-8 read by both the fixed
  string limit and the mapping boundary.
- Mirror objc4's two identity paths: use the stable cache identity directly
  for a cache-owned canonical protocol; otherwise use
  `objc_getProtocol(rawName)` to canonicalize a noncanonical alias.
- Preserve the raw mangled name in generated output.
- Unknown names, unreadable layouts/names, and full metadata reads remain typed
  degradation; no caller-side merge or inferred image owner is allowed.
- Do not accept readable arbitrary memory based only on a forged canonical bit.

Pending:

- Replace the insufficient name-registry-only dependency implementation with
  the refined canonical-cache contract, then publish a new coherent dependency
  cohort.
- Re-run the iOS 27.0 `24A5390f` ARKit runtime smoke and verify `ARAnchor`
  conformance plus zero matching warnings.
- Update PrivateHeaderKit to the final coherent dependency cohort.
- Run repository validation and a clean base-branch codex review.
- Push and open a non-draft PR to `main`.
