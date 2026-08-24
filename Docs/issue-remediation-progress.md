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
- The current dependency tests cover exact-address hits but not an address miss
  whose bounded raw name resolves to a registered canonical protocol.

Design contract:

- Probe the complete raw protocol layout before reading any field.
- Read the raw mangled name with a fixed bound and without unbounded
  `String(cString:)` traversal.
- Admit an out-of-image reference only when `objc_getProtocol(rawName)` finds
  the Objective-C runtime's canonical identity.
- Preserve the raw mangled name in generated output.
- Unknown names, unreadable layouts/names, and full metadata reads remain typed
  degradation; no caller-side merge or inferred image owner is allowed.
- Remove the address snapshot, lock, and refresh state made obsolete by the
  runtime-owned name lookup.

Pending:

- Implement the design contract in a MachOObjCSection worktree based on
  `932bff230815e39901e825e419db588377edee5c`.
- Cover distinct-address alias, raw Swift mangled-name preservation, unknown
  name, unreadable/nonterminated name, unreadable layout, and full-read cases.
- Add deterministic dependency tests and an iOS runtime smoke.
- Advance the coherent dependency cohort in PrivateHeaderKit.
- Run repository validation and a clean base-branch codex review.
- Push and open a non-draft PR to `main`.
