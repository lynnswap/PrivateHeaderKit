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

Status: design audit in progress on branch
`codex/issue-60-ios-protocol-aliases`.

Verified evidence:

- The `v0.5.4` iOS 27.0 `24A5390f` run published `ARAnchor` without
  `ARDaemonSecureCoding` and `ARAnchorCopying`.
- The persisted warnings classify both dropped entries as
  `missingBackingData`.
- PR #63 previously recovered only exact runtime-registry pointer matches.
- The dependency owner is MachOObjCSection's loaded-image protocol list reader;
  PrivateHeaderKit warning propagation is not the correction point.

Pending:

- Prove how the raw list pointers differ from their registered canonical
  protocol objects.
- Fix that identity mapping at the dependency owner without accepting unknown
  pointers or inventing names.
- Add deterministic dependency tests and an iOS runtime smoke.
- Advance the coherent dependency cohort in PrivateHeaderKit.
- Run repository validation and a clean base-branch codex review.
- Push and open a non-draft PR to `main`.
