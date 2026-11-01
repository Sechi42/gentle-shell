# Complete bounded Windows peer discovery

> Helper review slice: the helper RPCs and native fixture are implemented here. The client collector and public 90-peer integration described below belong to the dependent client slice; the observed local results describe the combined candidate.

The Windows client collects `list-page` results until completion, returning every accepted peer or an I/O error, never a partial list. Existing helper `list` retains its 64-directory-entry limit for older clients.

## Contract

Send `{requestId, operation:"list-page", cursor:null}` to start. Optionally include `excludeSessionId` (a valid session ID), repeating the same exclusion on every continuation. A successful result contains exactly `{records:[publicPresenceRecord...], cursor:string|null}`; public records retain `version`, `sessionId`, `endpoint`, and `createdAt`.

Continue until the cursor is null. Cursors are opaque, helper-local, sequential and single-use. Unknown, malformed, expired, replayed, other-helper or exclusion-mismatched cursors return `invalid`, without record data. A lost cursor cannot be resumed. A caller may explicitly make a new list call; the client never automatically retries, restarts a snapshot, or falls back to `list`. Schema violations follow existing recognized-operation behavior: `invalid`, then close the request loop. Old helpers reject the new operation; clients must not downgrade on failure.

## Bounds and consistency

| Boundary | Budget |
|---|---|
| Page control frame | 16,384 UTF-8 bytes, checked for the new RPC; overflow returns `busy`. Legacy output semantics are unchanged. |
| Page | 32 records; maximum validated IDs and timestamps fit in the frame, including a 128-character request ID. |
| Scan | 4,096 names, including invalid names. |
| Read work | At most 4,096 attempts at the existing 8,192-byte file limit; no retries. |
| Snapshot | 524,288 canonical serialized UTF-8 record bytes, at most 4,096 winners. |
| Active state | Two retained snapshots plus one transient bounded scan; a third start returns `busy`. |
| Scan deadline | 2,000 ms, checked cooperatively around enumeration, reads and sorting; it cannot cancel a stalled synchronous OS call. |
| Cursor lifetime | 2,000 ms from completed scan, never extended by paging; lazy expiry and a 2,000-ms sweep. |

Scan, name, byte or deadline exhaustion returns `busy`, never a successful partial snapshot. `resolve` uses the same complete bounded scan without allocating cursor state. Legacy `list`, pages and resolve share pinned enumeration and record reads, ACL/ownership checks, newest timestamp then greatest token winner selection, and ordinal session ordering. Existing invalid-record filtering is unchanged.

Upstream discovery retains its existing best-effort reclamation: only an endpoint conclusively absent via `WaitNamedPipe` is omitted and considered for deletion. Reclamation reopens the record relative to the pinned directory, excludes write/delete sharing, verifies owner, ACL, hardlink count, identity and contents, and probes absence again before deleting the verified handle. Alive and inconclusive endpoints are preserved. This upstream behavior is separate from the installed release overlay's no-deletion guarantee.

Directory reads are best-effort, not a filesystem transaction. Once accepted, pages come from the retained array; later mutation cannot change it. A fresh call rescans. Completed or expired snapshots and shutdown release retained arrays; an inaccessible expired array can remain for one additional sweep.

## Client collection

Public `listActivations` and `list` preserve their record/candidate output shapes and exclusion behavior, including small lists. Each page carries the identical exclusion. `resolve` uses the helper's complete bounded scan, not the first page.

The strict control decoder admits only the exact `{records,cursor}` page shape: at most 32 validated records and a null or 32 lowercase hexadecimal cursor. Legacy frame parsing and the 16,384-byte control limit are unchanged. The collector requires a page reply, so a legacy records-only reply cannot masquerade as completion. New clients fail closed against old helpers; old clients can still use the new helper's small legacy lists.

Collection accepts at most 4,096 records, 524,288 canonical `RecordText` UTF-8 record bytes, and 128 sequential page requests. The helper marks its last nonempty page terminal, so no extra empty terminal request is needed; only an initially empty snapshot may return an empty page. One 2,000-ms cooperative client budget covers all requests and validation, without extending helper cursor expiry. Checks and a collection timer bound asynchronous waiting, not stalled synchronous OS I/O or event-loop execution; this is not an OS-level hard deadline.

Pages must retain strictly increasing ordinal session IDs: the helper has already selected newest timestamp/greatest token winners. Duplicate or regressive records, excluded peers, repeated cursors, empty continuations, malformed replies, helper rejection and expiry fail closed without partial public output or retry.

## Native fixture

`tests/windows-session-pagination.test.ps1` restores the public-protocol fixture from `8f3ae84cf99bc31e7a9146cd2153cbe3072437ba`, adapted for upstream absent-pipe reclamation. Run each mode in a separate native PowerShell 5.1 process, from the repository root, in the authorized disposable-test runtime. `TMPDIR` must identify that runtime's dedicated temporary directory in native absolute Windows form, not a shared fallback or a real agent home.

```powershell
& C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -File tests/windows-session-pagination.test.ps1 -Mode protocol
& C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -File tests/windows-session-pagination.test.ps1 -Mode bounds
& C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -File tests/windows-session-pagination.test.ps1 -Mode legacy-bounds
& C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -File tests/windows-session-pagination.test.ps1 -Mode deadline
```

The fixture exclusively creates a GUID-owned root beneath `TMPDIR`, rejects reparse ancestors and pre-existing targets, and retains private SID-only record ACLs. It holds one first-instance, asynchronously listening synthetic named-pipe server per record token, reusing it when a token repeats. This keeps required peers alive without bypassing production liveness or security checks. Native extended-length filesystem paths support 128-character IDs under long runtime paths; no OS or registry setting changes. The deadline mode injects one exact-threshold clock observation into a disposable helper copy under that same owned root, never under `node_modules` or the installed overlay. Finally, every owned pipe is disposed before exact tracked-file deletion and nonrecursive owned-directory removal; no real profiles or records are used.

The harness caps each asynchronous task wait at 5,000 ms and cumulative active waiting at 23,000 ms. Only time inside `Task.Wait` is charged; owned filesystem setup, ACL/ancestor checks, file-state verification, filesystem cleanup and the intentional cursor-expiry sleep are excluded. Already-completed tasks consume no wait budget but still propagate faults. The parent separately enforces a 90-second process wall timeout; the existing 3-second helper-exit wait is unchanged. These harness limits do not change the production helper scan, cursor or client collection budgets of 2,000 ms. Failure diagnostics contain fixed assertion text or an exception type, stage, last fixed operation/request sequence, tracked owned-file count and elapsed wall/active-wait times, never raw replies, helper stderr or paths. Successful stdout and legacy trace hashing are unchanged.

Coverage retains 64/65/90 peers, timestamp/token winners and ordinal ordering, mutation-stable snapshots, cursor replay/expiry/capacity, maximum IDs/timestamps/request IDs and page frames, byte/name-budget failures and recovery, unchanged rejected-input files/counters, legacy trace hashing and controlled deadline recovery.

### Observed local verification — not a CI verdict

The corrected fixture passed all four modes on native PowerShell 5.1: exit 0, empty helper and outer stderr, and no owned runtime residue. Three public native integration cases (90-peer pagination with orphan reclamation, resumed-activation preservation, and a busy endpoint) also passed. The explicit client/transport allowlist passed 37 tests with 53 platform skips.

The initial protocol run failed with `bounded wait expired; cleanup: bounded wait expired`, without a process timeout. Static inspection proved defective harness accounting, but its exact first-failure phase was not captured. Only fixture accounting and failure diagnostics changed before the successful four-mode check; production deadlines were not increased. TypeScript validation reports zero diagnostics after resolving worktree-local SDK imports without changing the baseline or dependency contents. A single upstream-baseline/candidate legacy check matched stdout, stderr and exit status. Independent security verification and target-host CI remain separate; these local passes are not merge approval.
