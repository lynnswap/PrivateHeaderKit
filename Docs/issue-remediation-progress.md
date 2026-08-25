# Issue remediation progress

Base: `main` at `101748f62fa27d6851b4284df7cafc721081fa5c`

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

Design gate pending:

- Identify one file-table owner for offset conversion, count/stride arithmetic,
  entry/byte budgets, complete-range validation, and decoding.
- Identify one loaded-image range owner that can prove a full layout before any
  dereference without inventing process memory readability.
- Map legal empty, malformed table, unreadable entry, and programmer misuse to
  distinct observable semantics.
- Confirm the additive dependency API needed by PrivateHeaderKit diagnostics and
  direct-query parity before implementation begins.

Required regression coverage:

- Existing protocol-list behavior from #60.
- Existing relative-member behavior from #65.
- Existing fixed-field behavior from #79.
