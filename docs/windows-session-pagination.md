# Complete bounded Windows peer discovery

The Windows client collects `list-page` results until completion, returning every
accepted peer or an I/O error, never a partial list. Existing helper `list` retains
its 64-directory-entry limit for older clients. Discovery neither deletes records
nor classifies them as stale.

## Contract

Send exactly `{requestId, operation:"list-page", cursor:null}` to start.
Optionally include `excludeSessionId` (a valid session ID); repeat the same
exclusion on every continuation. A successful result has exactly
`{records:[publicPresenceRecord...], cursor:string|null}`. Public records retain
exactly `version`, `sessionId`, `endpoint`, `createdAt`.

Continue with the returned cursor until it is null. Cursors are opaque,
helper-local, sequential and single-use. Unknown, malformed, expired, replayed,
other-helper or exclusion-mismatched cursors return `invalid`, with no record data.
A lost cursor cannot be resumed. A caller may explicitly make a new list call;
the client never automatically retries, restarts a snapshot, or falls back to `list`. Schema violations follow
existing recognized-operation behavior: `invalid`, then close the request loop.
Old helpers reject the new operation; clients must not downgrade on failure.

## Bounds and consistency

| Boundary | Budget and rationale |
|---|---|
| Page control frame | Existing 16,384 UTF-8 bytes, checked before new-RPC output; overflow returns `busy`. Legacy operations retain their prior output semantics |
| Page | 32 records; even maximum validated IDs/timestamps fit below the frame budget, including a 128-character request ID |
| Scan | 4,096 names, matching the existing larger-scan reference; includes invalid names, not just accepted records |
| Read work | At most 4,096 attempts × existing 8,192-byte file limit = 32 MiB; no retries |
| Snapshot | 524,288 canonical serialized UTF-8 record bytes, counted before acceptance; at most 4,096 winners |
| Active state | Two retained snapshots (at most 1 MiB serialized payload), plus one transient bounded scan during resolve; a third snapshot start returns `busy` |
| Scan deadline | 2,000 ms cooperative checks around enumeration/record reads and sorting, matching the existing pipe deadline; not cancellation of a stalled synchronous OS call |
| Cursor lifetime | 2,000 ms from completed scan, never extended by paging; lazy expiry plus a 2,000-ms sweep under the existing gate |

Scan/name/byte/deadline exhaustion returns `busy`, never a successful partial
snapshot. `resolve` uses the same complete bounded scan without allocating cursor
state. Legacy `list`, pages and resolve share the pinned enumeration, record
parser, ACL/ownership checks, deduplication (newest timestamp, then greatest token)
and ordinal session ordering. Existing invalid-record filtering remains unchanged.

Directory reads are best-effort, not a filesystem transaction. Once accepted,
pages come only from the retained record array: later mutation cannot change it.
A fresh call rescans. Completed/expired snapshots and shutdown release retained
arrays; expiry sweep may retain an inaccessible expired array for one extra sweep.

## Client collection

Public `listActivations` and `list` preserve their record/candidate output shapes
and exclusion behavior, including small lists. Each page carries the identical
exclusion. `resolve` uses the helper's complete bounded scan, not the first page.

The decoder adds only the exact `{records,cursor}` shape (at most 32 validated
records, null or 32 lowercase hexadecimal cursor); legacy frame parsing and the
16,384-byte control limit are unchanged. The collector separately requires a page
reply, so a legacy records-only reply cannot masquerade as successful completion.
New clients fail closed against old helpers; old clients can still use the new
helper's small legacy lists.

Collection accepts at most 4,096 records, 524,288 canonical `RecordText` UTF-8
record bytes, and 128 sequential page requests. The helper marks its last nonempty
page terminal, so no extra empty terminal request is needed (only an initially
empty snapshot may return an empty page). A single 2,000-ms cooperative client
budget covers all requests and validation, without extending helper cursor expiry.
Checks plus a collection timer bound async waiting, not stalled synchronous OS I/O
or event-loop execution; this is not an OS-level hard deadline.

Pages must retain strictly increasing ordinal session IDs: the helper already
selects newest timestamp/greatest token winners. Duplicate or regressive records,
excluded peers, repeated cursors, empty continuations, malformed replies, helper
rejection and expiry all fail closed, with no partial public output or retry.

## Verification boundary

`tests/windows-session-pagination-client.test.ts` exercises the real host decoder
with a fake child, covering public aggregation, exact limits, refusal/call counts,
and a controlled clock. The selected `Windows-native paginated presence` bootstrap
case uses a fresh temporary profile and public registry calls for 90 peers,
exclusion, beyond-page-one resolve and winner semantics; it never accesses HKCU.


`tests/windows-session-pagination.test.ps1` uses only a GUID-owned disposable
profile, explicit private file ACLs, bounded waits and owned-file cleanup. Run it
with PS5.1. Modes `protocol`, `bounds`, and `deadline` are separate bounded checks.
`bounds` uses 128-character session/request IDs and maximum safe timestamps;
all page frames fit 16 KiB. It checks complete aggregation immediately below the
512-KiB payload cap, `busy` immediately above, and capacity recovery after rejection.
The protocol mode similarly checks recovery after the 4096-name scan cap.

`deadline` creates a candidate-source copy under `node_modules/.gentle-pagination-*`.
Only its clock observation is controlled: check 20 observes exactly 2000 ms;
all other observations use the real stopwatch. This exercises public `busy`
propagation mid-scan and two subsequent snapshots (no leaked slot), without a
production testing RPC or changed ACL/budget. It does **not** prove wall-clock
cancellation of synchronous native I/O; production checks remain cooperative.

`legacy-bounds` pins all existing operations at maximum relevant public inputs.
A disposable baseline/candidate differential compares sanitized reply digests,
stdout, stderr and exit status. In particular, maximum legacy `list` replies can
exceed 16 KiB: changing them to `busy` was an unintended compatibility regression.
The new output check is therefore scoped to `list-page`, not shared legacy RPCs.

### Legacy timeout diagnosis

The original selected Node bootstrap command timed out at 30 seconds (no result).
An isolated eager `gentle-agents` extension import also exceeded 15 seconds before
native fixtures could launch; even its 8-second timer did not run. The fixed
PowerShell executable exists. Deferring that extension import to the three tests
that use it removes unrelated extension loading from the selected native test.
The corrected selected command passed once: 1 test, 5.9 seconds, exit 0. This is
new evidence after a harness correction, not a relabeling of the original timeout.

Independent security/concurrency verification (risk items 2 and 4) remains required
after client integration; this helper slice is not full-feature completion.
