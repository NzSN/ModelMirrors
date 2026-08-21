# Async Operations Design — Validate-Only and Trace-Generation-Only Paths

Status: **design only, no implementation**. Purely additive: every element below is a
*new* constructor, wire tag, function, or module. No existing constructor, wire tag,
function, session flow, or behavior is modified.

## 1. Background: the two synchronous paths today

### 1.1 Validate-only path

- Client entry: `runClientValidate` (`src/Protocol/Client.hs`) sends
  `RegisterValidate cfg bound mSpec` (wire: `"register_validate"`).
- Mirror entry: `MirrorRecvRegisterValidate` → `MkRunValidate`
  (`src/Protocol/Mirror.hs`): bound-range guard (`1..maxValidateBound=100`), spec
  materialization, then a **blocking** `validateSpecIn` (apalache typecheck + check,
  seconds to minutes) inside the session thread, then one reply:
  `SpecValidated v` or `RegisterError e`.

### 1.2 Trace-generation-only path

- Client entry: `runClientGenTracesWithSpec` sends
  `RegisterGenTraces cfg tc destPath mSpec` (wire: `"register_trace_gen"`).
- Mirror entry: `MirrorRecvRegisterGenTraces` → `MkRunMirrorGenTraces`: spec
  materialization, then a **blocking** `generateTraceFilesIn` in the session thread,
  dest-path copy, trace-content readback, then one reply:
  `GenTracesDone paths contents` or `RegisterError e`.

### 1.3 What async must respect

- `Protocol.Transport.Core` is a strict one-JSON-value request → one-JSON-value
  response alternation (`sendMsg`/`recvMsg`). There is **no push channel**.
  Therefore the async model is **submit → poll / long-poll**, never server-initiated
  completion notices. Zero transport changes.
- The existing sync replies and error tiers are preserved verbatim as async outcomes
  (§3.3), so async is a true superset of the sync behavior.
- Existing `run`/`runMirror*`/`runClient*` entry points keep working untouched.

## 2. New protocol vocabulary (`Protocol.Core`, additive)

```haskell
-- New types
newtype JobId = JobId Text            -- server-generated, opaque to the client
data JobKind  = ValidateJob | GenTracesJob
data JobPhase = JobPending            -- accepted, waiting for a worker slot
              | JobRunning            -- apalache invocation in flight
              | JobDone               -- terminal, result available
              | JobFailed             -- terminal, infrastructure failure
              | JobCancelled          -- terminal, cancelled by client
              | JobUnknown            -- queried JobId not (or no longer) known

data JobOutcome                       -- payload mirrors the sync reply exactly
  = JobValidateDone  !ValidateResult              -- == SpecValidated v
  | JobGenTracesDone ![FilePath] ![TraceContent]  -- == GenTracesDone paths contents
  | JobFailed        !Text                        -- apalache infrastructure error

-- ClientMessage additions
-- | RegisterValidateAsync  !ApalacheConfig !Int !(Maybe ApalacheSpec)
-- | RegisterGenTracesAsync !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
-- | QueryJob !JobId                              -- non-blocking poll
-- | AwaitJob !JobId !(Maybe Int)                 -- long-poll, optional timeout (seconds)
-- | CancelJob !JobId

-- MirrorMessage additions
-- | JobAccepted !JobId !JobKind
-- | JobStatus   !JobId !JobPhase
-- | JobResult   !JobId !JobOutcome
```

`ProtocolState` is left alone; async session state is tracked separately (§5).

### 2.1 Wire format (`Protocol.Format.Json`, additive cases only)

| Message | `proto_step` | Extra fields |
|---|---|---|
| `RegisterValidateAsync` | `register_validate_async` | `apalacheConfig`, `bound`, `spec?` |
| `RegisterGenTracesAsync` | `register_trace_gen_async` | `apalacheConfig`, `traceConfig`, `destPath?`, `spec?` |
| `QueryJob` | `query_job` | `jobId` |
| `AwaitJob` | `await_job` | `jobId`, `timeoutSecs?` |
| `CancelJob` | `cancel_job` | `jobId` |
| `JobAccepted` | `job_accepted` | `jobId`, `kind` (`"validate"` / `"gen_traces"`) |
| `JobStatus` | `job_status` | `jobId`, `phase` |
| `JobResult` | `job_result` | `jobId`, `outcome` (tagged: `validate` / `genTraces` / `error`) |

Payload shapes inside `outcome` reuse the existing `result`, `itfTracePaths`,
`itfTraces`, and `error` field encodings byte-for-byte.

## 3. The two async flows

### 3.1 Validate-only async (entries: `RegisterValidateAsync` / `MirrorRecvRegisterValidateAsync`)

```
C→M  register_validate_async {apalacheConfig, bound, spec?}
     |  mirror: bound guard 1..100 → materialize spec (both SYNCHRONOUS, as today)
     |  any failure here → existing `register_error` (no job created)
     |  else: allocate JobId, fork job thread, reply immediately
M→C  job_accepted {jobId, kind:"validate"}
C→M  await_job {jobId, timeoutSecs?}          (or query_job for a one-shot poll)
M→C  job_status {jobId, phase:"running"}      ← on await timeout; client may re-await
C→M  await_job {jobId}
M→C  job_result {jobId, outcome:{validate: "valid" | {invalid: e}}}
```

Job body = exactly what `MkRunValidate` does after the guard:
`validateSpecIn (Just jobDir) cfg' bound` in a job-private temp dir.

### 3.2 Trace-generation-only async (entries: `RegisterGenTracesAsync` / `MirrorRecvRegisterGenTracesAsync`)

```
C→M  register_trace_gen_async {apalacheConfig, traceConfig, destPath?, spec?}
     |  mirror: materialize spec (synchronous) → failure: `register_error`
     |  else: allocate JobId, fork job thread, reply immediately
M→C  job_accepted {jobId, kind:"gen_traces"}
C→M  query_job {jobId}  →  M→C job_status {jobId, phase:"running"}
C→M  await_job {jobId}
M→C  job_result {jobId, outcome:{genTraces:{itfTracePaths, itfTraces}}}
```

Job body = exactly what `MkRunMirrorGenTraces` does after materialization:
`generateTraceFilesIn`, dest-path copy, trace-content readback — all inside the job
thread, so the delivered outcome is identical to the sync reply.

### 3.3 Failure mapping (identical tiers to sync)

| Stage | Sync reply today | Async reply |
|---|---|---|
| bound outside `1..100` | `register_error` | `register_error` (before `job_accepted`) |
| spec materialization failure | `register_error` | `register_error` (before `job_accepted`) |
| server at job capacity | — | `register_error` "job queue full" (before `job_accepted`) |
| apalache infrastructure error (exit 255, missing binary) | `register_error` | `job_result` with `JobFailed` |
| typecheck failure / invariant violation | `spec_validated {invalid}` | `job_result` with `JobValidateDone (SpecInvalid e)` |
| trace parse failure in readback | `register_error` | `job_result` with `JobFailed` |
| unknown `jobId` in query/await/cancel | — | `job_status {phase:"unknown"}` (in-band, no exception) |

Rationale: everything validated *before* `job_accepted` stays a register error, so
`job_accepted` is a reliable capability: once held, all further outcomes arrive as
`job_status`/`job_result`.

## 4. Mirror-side job machinery — new module `Protocol.AsyncJobs`

```haskell
data JobStore = JobStore
  { jsJobs    :: MVar (Map JobId JobHandle)
  , jsSlots   :: QSemN            -- bounds concurrent apalache processes
  , jsCounter :: IORef Int        -- JobId = "job-<n>", unique per store
  }

data JobHandle = JobHandle
  { jhKind   :: JobKind
  , jhPhase  :: TVar JobPhase
  , jhResult :: MVar JobOutcome   -- written exactly once, at terminal transition
  , jhThread :: ThreadId
  , jhSpec   :: SpecHandle        -- owned spec resource (§11); released at terminal transition
  , jhDir    :: FilePath          -- job-private temp dir (run dir + trace files)
  }
```

Lifecycle:

1. **Submit** (session thread): pre-checks → create handle → `forkIO` job body →
   `sendMsg (JobAccepted …)` → return to the session loop *immediately*.
2. **Run** (job thread): acquire `jsSlots` (phase `JobPending` → `JobRunning`),
   call the *existing* `validateSpecIn` / `generateTraceFilesIn` (no Apalache-layer
   changes for the base design), write `jhResult`, set terminal phase, release slot.
3. **Collect**: `query_job` is non-blocking (`JobStatus`, plus `JobResult` when
   terminal). `await_job` blocks server-side on `jhResult` with optional timeout;
   timeout → `JobStatus` with the current phase. Terminal delivery is idempotent
   within the session (result retained; see GC).
4. **GC**: the job temp dir and slot are freed when the terminal result is first
   delivered *or* when the session ends. Session close with jobs still running →
   `killThread` + directory cleanup (same best-effort caveat as cancellation, §6).
5. **Scoping**: v1 store is **per session** (created by the session entry point).
   Documented extension: a server-wide store passed into a new serve wrapper enables
   submit-on-one-connection / poll-on-another; existing serve functions stay as-is.

Capacity: `--jobs` bounds concurrent *sessions*; async multiplies apalache processes
per session, so `jsSlots` is the new bound (`maxAsyncJobs`, default = `--jobs`,
future server flag). Full queue → `register_error` at submit time.

## 5. Session loop and step-log integration (`Protocol.Mirror`, additive)

Existing `run` handles exactly one register per connection and is **unchanged**.
New entry point:

```haskell
runAsyncSession :: Transport t => t -> JobStore -> IO [MirrorStep]
```

A recv-dispatch loop: async registers fork and return to the loop; job operations
(`QueryJob`/`AwaitJob`/`CancelJob`) are answered from the store; a *sync*
register message received mid-session still runs to completion inline (blocking the
loop — documented, matches today's behavior); transport EOF ends the session and GCs
its jobs. Async session state (outstanding job set) lives in the new module; the
existing `ProtocolState` ADT is untouched.

New `MirrorStep` constructors (trace/observability parity with sync):

```haskell
-- | MirrorRecvRegisterValidateAsync  !ApalacheConfig !Int !(Maybe ApalacheSpec)
-- | MirrorRecvRegisterGenTracesAsync !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
-- | MirrorRecvJobQuery !JobId | MirrorRecvJobAwait !JobId | MirrorRecvJobCancel !JobId
-- | MirrorSendJobAccepted !JobId !JobKind
-- | MirrorSendJobStatus   !JobId !JobPhase
-- | MirrorSendJobResult   !JobId !Text          -- outcome summary tag
```

plus `mirrorStepActionName` entries (`"MirrorRecvRegisterValidateAsync"`, …) and
`normalizeMirrorSteps` passthrough. Immediate failures reuse the existing
`MirrorSendRegisterError` / `MirrorSendProtocolError` steps — no duplication.

New `Step` instances (one per operation, mirroring the sync structure):

```haskell
data MkRunValidateAsync  t = MkRunValidateAsync  t JobStore ApalacheConfig Int (Maybe ApalacheSpec)
data MkRunGenTracesAsync t = MkRunGenTracesAsync t JobStore ApalacheConfig TraceGenerationConfig (Maybe FilePath) (Maybe ApalacheSpec)
data MkJobQuery t = MkJobQuery t JobStore JobId
data MkJobAwait t = MkJobAwait t JobStore JobId (Maybe Int)
data MkJobCancel t = MkJobCancel t JobStore JobId
```

New exported wrappers: `runMirrorValidateAsync`, `runMirrorGenTracesAsync`
(signatures mirror `runMirrorValidate` / `runMirrorGenTracesWithSpec`, plus the store).

## 6. Cancellation (designed, marked best-effort in v1)

`cancel_job` → phase `JobCancelled`, `killThread jhThread`, free slot and temp
dir, reply `job_status {phase:"cancelled"}`. Caveat: killing the Haskell thread
does not kill the spawned `apalache-mc` child, because `Apalache.Command` uses
`readCreateProcessWithExitCode`. True cancellation is a documented extension point:
*add* `validateSpecInAsync` / `generateTraceFilesInAsync` to `Apalache.Command`
returning the `ProcessHandle` (additive; existing wrappers delegate to them). v1
ships with best-effort cancel and this limitation documented.

## 7. Client API (`Protocol.Client`, additive)

```haskell
submitValidateAsync  :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text JobId)
submitGenTracesAsync :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO (Either Text JobId)
pollJob   :: Transport t => t -> JobId -> IO (Either Text (JobPhase, Maybe JobOutcome))
awaitJob  :: Transport t => t -> JobId -> Maybe Int -> IO (Either Text JobOutcome)  -- loops job_status until terminal
cancelJob :: Transport t => t -> JobId -> IO (Either Text ())

-- Drop-in async equivalents of the sync one-shots (same result shapes):
runClientValidateAsync  :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ValidateResult)
runClientGenTracesAsync :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO (Either Text ([FilePath], [TraceContent]))
```

`submit*` returns `Left` on `register_error`/`protocol_error` (same mapping as
the sync runners), `Right jobId` on `job_accepted`.

## 8. Compatibility and fallback

- **New client → old mirror**: the old mirror's decoder fails the unknown
  `proto_step` and its existing `Left` branch replies `protocol_error`. The
  client detects this and may fall back to the synchronous `register_validate` /
  `register_trace_gen` calls — behavior unchanged, just blocking again.
- **Old client → new mirror**: unaffected; new tags are never emitted unless requested.
- No version handshake needed; the tag namespace is the negotiation.

## 9. Testing plan (future)

- `MockTransport` round-trips: submit → poll → result for both paths with an
  *injected fake job body* (job body parameterized in `Protocol.AsyncJobs` so tests
  need no apalache); assert step logs via `normalizeMirrorSteps`.
- Error tiers: bad bound and materialization failure → `register_error` pre-accept;
  forced apalache failure → `JobFailed` post-accept; unknown jobId → `JobUnknown`.
- Concurrency: `maxAsyncJobs=1` serializes two submits; session-close GC kills a
  running job.
- Integration: HourClock async validate + async trace-gen against real apalache,
  alongside (not replacing) the existing sync cases.

## 10. File-by-file change map (all additive)

| File | Change |
|---|---|
| `src/Protocol/Core.hs` | +JobId/JobKind/JobPhase/JobOutcome, +5 ClientMessage ctors, +3 MirrorMessage ctors |
| `src/Protocol/Format/Json.hs` | +ToJSON/FromJSON cases for the new messages/types only |
| `src/Protocol/AsyncJobs.hs` | **new module**: JobStore, JobHandle, submit/query/await/cancel/GC |
| `src/Protocol/Mirror.hs` | +MirrorStep ctors, +5 Step instances, +`runAsyncSession`, +2 wrappers |
| `src/Protocol/Client.hs` | +7 client functions (§7) |
| `src/Apalache/Command.hs` | (extension, cancel v2) +`*Async` variants exposing ProcessHandle |
| `app/Main.hs` | none for v1 (stdio default may later opt into `runAsyncSession`; serve wrappers unchanged) |
| `test/Main.hs` | +async cases per §9 |

## 11. Resource lifecycle model — shared semantics for sync and async

### 11.1 What the code has today (and why it is not enough for async)

Current modeling is **acquire/release pairs under lexical brackets**, not handles:

- Spec content: `ApalacheSpec` (pure data, no life).
- Spec on disk: `materializeSpec` / `removeSpecDir` pair; the only caller is
  `withSpecDir` (`Protocol.Mirror`), which brackets the dir to one synchronous
  register handler.
- Run dir: `withSessionDir` = `withSystemTempDirectory`, bracketed to the sync flow.
- Trace files: live inside the session bracket, or are copied to a client `destPath`
  and **abandoned** (ownership passes to the caller; the mirror never deletes them).
- The single existing handle is `Explorer` (`newExplorer` / `exploreDispose`) —
  the precedent this design generalizes.

Lexical brackets close when `JobAccepted` is sent, so async cannot reuse them
directly. The fix is a first-class ownership model that sync wraps in brackets and
async stores in the `JobHandle` — one set of semantics, two scoping disciplines.

### 11.2 New concepts (additive; `Apalache.Resources` or inside `Protocol.AsyncJobs`)

```haskell
data SpecHandle = SpecHandle
  { shPath       :: !FilePath        -- root .tla path to hand to apalache
  , shDir        :: !(Maybe FilePath) -- temp dir to release, if owned
  , shProvenance :: !Provenance
  }

data Provenance = Owned | Borrowed
  -- Owned:    materialized from an inline ApalacheSpec; mirror must delete.
  -- Borrowed: client's own specPath (Nothing spec); mirror must NEVER delete.

data TraceSet = TraceSet
  { tsId      :: !Int
  , tsDir     :: !FilePath           -- outDir containing the .itf.json files
  , tsPaths   :: ![FilePath]
  , tsState   :: !(TVar TraceSetState)
  }

data TraceSetState
  = Live          -- files exist under mirror-owned dir; mirror must clean
  | Delivered     -- copied to client destPath; ownership disclaimed (today's behavior)
  | Released      -- cleaned; any further use is a bug
```

Operations: `acquireSpec :: Maybe ApalacheSpec -> ApalacheConfig -> IO (Either Text (SpecHandle, ApalacheConfig))`
(returns the config with `specPath` overridden when materialized), `releaseSpec`,
`releaseTraceSet`, `markDelivered`. All are idempotent; release of a `Borrowed`
spec is a no-op by construction.

### 11.3 Sync semantics (unchanged behavior, new implementation basis)

`withSpecDir` / `withSessionDir` become thin brackets over `acquireSpec` /
`releaseSpec`: acquire at handler entry, release on exit (normal or exceptional).
The sync flow's observable behavior — including the `destPath` copy that marks the
`TraceSet` `Delivered` — is byte-identical to today.

### 11.4 Async semantics (the job handle owns the resources)

- **Submit** (session thread): `acquireSpec` succeeds → create job resources; the
  `SpecHandle` and a job-private run dir move into the `JobHandle`
  (`jhSpec`, `jhDir`). Failure → `register_error`, nothing acquired.
- **Run** (job thread): apalache runs against `shPath` with cwd/run-dir `jhDir`.
  For gen-traces, completion creates the `TraceSet`; a `destPath` copy transitions
  it to `Delivered` (session dir portion still released).
- **Terminal transition** (done/failed/cancelled): result delivered → release
  `Owned` spec dir and run dir. Validate jobs own no `TraceSet`.
- **Session close / server shutdown**: the `JobStore` registry force-releases every
  live handle (kill thread → release spec/run dirs). `Delivered` trace sets are
  never touched — same abandonment semantics as the sync path.
- **Cancellation** (§6): cancel = terminal transition, so cleanup rides the same path;
  the apalache child-process caveat applies unchanged.

### 11.5 Invariants (both paths)

1. Every `Owned` `SpecHandle` is released exactly once — by bracket (sync) or by
   terminal transition / force-release (async).
2. A `Borrowed` spec path is never deleted by the mirror, on any path.
3. A `TraceSet` leaves the mirror's ownership exactly once: `Released` (mirror
   temp) xor `Delivered` (client `destPath`), never both.
4. No job thread outlives its session: session close implies force-release, so temp
   dirs cannot leak past the connection that created them.
