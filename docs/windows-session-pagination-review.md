# Windows pagination review chain

Refs [#2365](https://github.com/Gentleman-Programming/gentle-shell/issues/2365). Review bounded native discovery first, then the complete client collector. The tracker is documentation-only and must remain draft/no-merge until its child slices are integrated.

## Proposed branch chain

```text
main
└── feat/windows-presence-pagination-451          tracker
    └── fix/windows-presence-pagination-451-helper
        └── fix/windows-presence-pagination-451-client
```

The first child targets the tracker; the second targets the first child. Upstream-owned base branches require maintainer agreement before upstream child PRs can be opened. Fork branches alone do not establish that agreement or issue approval.

## Review order

| Slice | Review focus | Boundary |
| --- | --- | --- |
| Tracker | This review plan | No product changes |
| Native helper | Pinned reads, absent-only identity-bound reclamation, bounded snapshots/cursors, native fixtures | Helper RPCs work without the new client |
| Client | Exact page decoding, complete-or-fail collection, public 90-peer integration | Activates paginated discovery while retaining public result shapes |

The native slice exceeds the advisory 400-line review budget because its Windows ownership, live-pipe, long-path and cleanup fixture belongs with the behavior it verifies. Keep that coherent boundary rather than removing tests or compressing code; obtain any exception the destination policy requires.

## Observed local checks

| Check | Result |
| --- | --- |
| Native PowerShell protocol, bounds, legacy-bounds, deadline | Four modes passed, empty stderr, owned runtime removed |
| Public native pagination/orphan, resumed activation, busy endpoint | Three tests passed |
| Client and selected transport regressions | 37 passed; 53 platform skips |
| TypeScript | Zero diagnostics after worktree dependency-path correction; baseline unchanged |
| Upstream baseline/current legacy commands | Identical stdout, stderr and exit status |

These are local results, not hosted CI or merge approval. Independent security verification and the destination's required CI are separate requirements. The unrestricted installer suite was not run locally because a fixture changes real HKCU state.

## Scope and submission

- Preserve upstream's existing safe stale-record reclamation and every ACL/pinned-handle check.
- Keep native fixtures in new owned temporary roots; do not change real profiles, registry settings, dependencies or installers.
- The installed release overlay is a separate local recovery; this contribution does not install or publish it.
- Use `Refs #2365`, not an automatic closing reference. Confirm issue approval, the tracker-base route, exactly one permitted `type:*` label and target CI policy before submission.
