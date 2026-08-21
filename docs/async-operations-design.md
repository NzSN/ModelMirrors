# Async Operations Design — Validate-Only and Trace-Generation-Only Paths

Status: **implemented** — all elements below are shipped in the library and covered
by the test suite (`cabal build all` + `LC_ALL=C.UTF-8 cabal test all` green,
191 tests; see §12 for implementation notes and deliberate deviations). Purely
additive: every element below is a *new* constructor, wire tag, function, or module.
No existing constructor, wire tag, function, session flow, or behavior is modified.

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
  | JobInfraError    !Text                        -- apalache infrastructure error
  -- (named JobInfraError, not JobFailed: JobPhase already has a JobFailed
  -- constructor and Haskell shares the constructor namespace; wire: {"error": …})

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
| apalache infrastructure error (exit 255, missing binary) | `register_error` | `job_result` with `JobInfraError` |
| typecheck failure / invariant violation | `spec_validated {invalid}` | `job_result` with `JobValidateDone (SpecInvalid e)` |
| trace parse failure in readback | `register_error` | `job_result` with `JobInfraError` |
| unknown `jobId` in query/await/cancel | — | `job_status {phase:"unknown"}` (in-band, no exception) |

Rationale: everything validated *before* `job_accepted` stays a register error, so
`job_accepted` is a reliable capability: once held, all further outcomes arrive as
`job_status`/`job_result`.

## 4. Mirror-side job machinery — new module `Protocol.AsyncJobs`

```haskell
data JobStore = JobStore
  { jsJobs     :: MVar (Map JobId JobHandle)
  , jsSlots    :: QSemN           -- bounds concurrent apalache processes
  , jsCounter  :: IORef Int       -- JobId = "job-<n>", unique per store
  , jsRegistry :: Registry        -- Resource.Registry (shipped): every job resource is
                                  -- acquireIn'd here; session close = forceReleaseAll
  }

data JobHandle = JobHandle
  { jhKind   :: JobKind
  , jhPhase  :: TVar JobPhase
  , jhResult :: MVar JobOutcome   -- written exactly once, at terminal transition
  , jhThread :: ThreadId
  , jhSpec   :: Resource SpecRes               -- acquireSpec (shipped), registered (§11)
  , jhRunDir :: Resource FilePath              -- acquireSessionDir (shipped), registered
  , jhProc   :: Maybe (Resource ProcessHandle) -- spawnApalache (shipped) while running;
                                               -- release = idempotent terminate+wait (§6)
  }
```

Lifecycle:

1. **Submit** (session thread): pre-checks → acquire the spec and run dir via
   `acquireIn jsRegistry` (`acquireSpec` / `acquireSessionDir` — registration is
   atomic with acquisition, so no leak window and nothing to forget) → create handle
   → `forkIO` job body → `sendMsg (JobAccepted …)` → return to the session loop
   *immediately*. Any failure before `job_accepted` → `register_error`, and the
   just-acquired resources are released in place.
2. **Run** (job thread): acquire `jsSlots` (phase `JobPending` → `JobRunning`),
   invoke apalache via `spawnApalache` and keep the returned
   `Resource ProcessHandle` in `jhProc` (registered too, so force-release kills
   the child) → write `jhResult`, set terminal phase, release slot.
3. **Collect**: `query_job` is non-blocking (`JobStatus`, plus `JobResult` when
   terminal). `await_job` blocks server-side on `jhResult` with optional timeout;
   timeout → `JobStatus` with the current phase. Terminal delivery is idempotent
   within the session (result retained; see GC).
4. **GC**: targeted `release` of `jhSpec`/`jhRunDir` when the terminal result
   is first delivered; `forceReleaseAll jsRegistry` at session close covers anything
   still live — LIFO (process handle before spec/run dirs), total, idempotent.
   Running jobs: `release jhProc` terminates the apalache child (§6), then
   `killThread jhThread`. The module-wide GC finalizer is the last-resort backstop.
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

## 6. Cancellation

`cancel_job` → phase `JobCancelled`, `release jhProc` (the
`Resource ProcessHandle` from `spawnApalache`: idempotent
`terminateProcess` + `waitForProcess`, safe if the child already exited),
`killThread jhThread`, targeted `release` of the job's spec/run-dir resources,
free the slot, reply `job_status {phase:"cancelled"}`.

This supersedes the original "best-effort v1" caveat in this section: the
resource-model implementation (docs/resource-model-design.md §4 B1, **shipped**)
already provides exactly the process handle the old text listed as a future
extension point — no `validateSpecInAsync`/`generateTraceFilesInAsync` variants
are needed; job bodies simply run `spawnApalache` and keep the handle. What
remains best-effort: an apalache child that ignores SIGTERM — `release` is total,
so mirror-side cleanup still completes, at worst leaving a stray grandchild to the
OS.

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
  forced apalache failure → `JobInfraError` post-accept; unknown jobId → `JobUnknown`.
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
| `src/Resource.hs` | (shipped) `Registry`/`acquireIn`/`forceReleaseAll` back the `JobStore`; no changes needed |
| `src/Apalache/Command.hs` | (shipped) `spawnApalache` gives job bodies a `Resource ProcessHandle` (§6); no further changes needed |
| `src/Apalache/SpecSource.hs` | (shipped) `acquireSpec`/`acquireSessionDir` used by job submit; no changes needed |
| `app/Main.hs` | none for v1 (stdio default may later opt into `runAsyncSession`; serve wrappers unchanged) |
| `test/Main.hs` | +async cases per §9 |

## 11. Resource lifecycle model — shared semantics for sync and async

> **Revised** to build directly on the **shipped** enforced-RAII model
> (`docs/resource-model-design.md`, module `Resource`). The ad-hoc
> `SpecHandle`/`TraceSet`/`Provenance` sketch from the previous revision of
> this section is superseded: spec dirs, run dirs, and processes are now
> `Resource` values, and the old `SpecHandle` role maps onto
> `Resource SpecRes`.

### 11.1 Why lexical brackets alone are not enough for async

The sync paths manage resources with brackets — now enforced brackets, re-based on
the Resource model (as built: `withSpecDir` = `acquireSpec` + `finally`/
`release`; `withSessionDir` and `withApalacheServer` = `Resource.with`).
Lexical scopes close when `JobAccepted` is sent, so async cannot reuse them
directly: an async job's resources must outlive the request that created them and
die with a *dynamic* event (terminal transition, session close). That is exactly
the Resource model's second discipline: a per-session `Registry` with
`acquireIn` + `forceReleaseAll`. One ownership vocabulary, two scoping
disciplines — sync keeps the brackets, async registers.

### 11.2 Resource vocabulary the async paths use (all shipped except the trace set)

| Role | Shipped API | Notes |
|---|---|---|
| Spec | `acquireSpec :: Maybe ApalacheSpec -> ApalacheConfig -> IO (Either Text (Resource SpecRes, ApalacheConfig))` (`Apalache.SpecSource`) | `SpecRes{specResDir, specResRootPath, specResProvenance}`; `Provenance` (`Owned`/`Borrowed`) is the canonical `Resource.Provenance`, re-exported by `SpecSource`. `Borrowed` cleanup is a no-op by construction — the client's own `specPath` is never deleted. |
| Run dir | `acquireSessionDir :: IO (Resource FilePath)` (`Apalache.SpecSource`) | cleanup = `removeDirectoryRecursive` |
| Process | `spawnApalache :: … -> IO (…, Resource ProcessHandle)` (`Apalache.Command`) | idempotent `terminateProcess`+`waitForProcess` cleanup; the basis of cancellation (§6) |
| Trace set | **future**: `TraceSetRes` + `acquireTraceSet` (deferred — resource-model Appendix A item 8) | the old `TraceSetState` maps onto `ResourceState`: `Live`→`Live`; `Delivered`→`Resource.transfer` at the `destPath` copy; `Released`→`Resource.release` |

All `Resource` operations are idempotent and total; `release` is CAS
at-most-once; forgotten releases are caught by the registry (dynamic scope) or the
GC finalizer backstop (`leak:` log).

### 11.3 Sync semantics (as built — unchanged behavior, enforced basis)

Already shipped with the resource model: `withSpecDir` (`acquireSpec` +
`finally`/`release`), `withSessionDir` and `withApalacheServer`
(`Resource.with`) — signatures and observable behavior byte-identical, including
the `destPath` copy-then-disclaim in `MkRunMirrorGenTraces` (which becomes an
explicit `Resource.transfer` when `TraceSetRes` lands).

### 11.4 Async semantics (the session registry owns the resources)

- **Submit** (session thread): `acquireIn jsRegistry` the spec (`acquireSpec`)
  and run dir (`acquireSessionDir`) — acquire+register is atomic, so there is no
  leak window and nothing to remember. Failure → `register_error`; anything
  acquired is released in place.
- **Run** (job thread): apalache via `spawnApalache` against
  `specResRootPath` with cwd/run-dir from the run-dir resource; the process
  handle lives in `jhProc` (also registered). For gen-traces, completion
  produces the trace set; a `destPath` copy is a `transfer`
  (Delivered — ownership disclaimed); the run-dir portion is still released.
- **Terminal transition** (done/failed/cancelled): result delivered → targeted
  `release` of the job's spec/run-dir/process resources. Validate jobs own no
  trace set.
- **Session close / server shutdown**: `forceReleaseAll jsRegistry` — LIFO
  (process before spec/run dirs), total, idempotent. `Delivered` trace sets are
  never touched — same abandonment semantics as the sync path.
- **Cancellation** (§6): cancel is a terminal transition riding the same
  mechanics — `release jhProc` kills the apalache child for real.

### 11.5 Invariants (both paths) — as enforced by the Resource model

1. Every `Owned` spec resource is released **at most once** (CAS on the state
   cell) and **at least once** — by enforced bracket (sync) or by terminal
   transition / `forceReleaseAll` (async); a forgotten release is reclaimed and
   logged by the GC finalizer backstop.
2. A `Borrowed` spec path is never deleted by the mirror, on any path — its
   cleanup is a no-op by construction (`Resource.Provenance`).
3. A trace set leaves the mirror's ownership exactly once: `release` (mirror
   temp) xor `transfer` (client `destPath`), enforced by the
   `ResourceState` machine — never both.
4. No job resource outlives its session: session close implies
   `forceReleaseAll`, so temp dirs and apalache children cannot leak past the
   connection that created them.

## 12. Implementation notes (post-implementation sync)

The feature shipped as specified above, with the following deliberate deviations
and discoveries:

1. **`JobInfraError` naming** (§2): the infra-error `JobOutcome` constructor is
   `JobInfraError`, not `JobFailed`, because `JobPhase` already occupies the
   `JobFailed` constructor name. The wire tag is `{"error": …}` as specified.
   (The doc body above already uses the shipped name.)
2. **Capacity model** (§4, §9): the separate `maxAsyncJobs` bound is implemented
   as `jsCapacity` on the `JobStore` — slots = capacity = queue bound. At
   capacity a submit is rejected *pre-accept* with `register_error`
   "job queue full" rather than queued for later serialization; a resubmit
   after a running job completes is accepted. The §9 concurrency tests assert
   this implemented semantics.
3. **`jhProc` representation** (§4): the process-handle slot is an
   `IORef (Maybe (Resource ProcessHandle))`, not a plain `Maybe` — the job
   thread fills it after `spawnApalache` while cancel/session-close read it
   concurrently. All cancel/close paths go through `cancelJob`/`closeJobStore`;
   nothing touches `jhProc` directly.
4. **`maxValidateBound` location**: the constant (value unchanged: 100) lives in
   `Protocol.AsyncJobs` and `Protocol.Mirror` delegates to it, avoiding a
   module-import cycle.
5. **Bug fix found by the async integration tests**: `generateTraceFilesVia`
   (`Apalache.Command`) did not absolutize a relative `specPath` when a run dir
   is set (`validateSpecVia` did). Async gen-traces exposed this because
   `spawnApalacheIn` pins the child cwd to the job run dir. Fixed for parity;
   observable sync behavior is unchanged for absolute paths.
6. **Behavior-preserving refactors**: `spawnApalacheWith` (`Apalache.Command`)
   and `acquireSpecWith` (`Apalache.SpecSource`) were extracted as shared
   workers behind the existing exported signatures; no wire, flow, or
   signature changes.
7. **Tests**: `test/Protocol/AsyncJobsSpec.hs` (11 tests) implements §9 in
   full — MockTransport round-trips with injected fake job bodies, error tiers,
   concurrency/GC, and HourClock async integration alongside the sync cases.

