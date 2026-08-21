# Resource Model Design — Enforced RAII for ModelMirrors

Status: **design only, no implementation**. Purely additive: existing modules keep
working; enforcement is introduced underneath them. Supersedes the ad-hoc
`SpecHandle`/`TraceSet` sketch in `docs/async-operations-design.md` §11 (those
become typed `Resource` wrappers, §4 below).

## 1. Problem statement

Today's safety is **RAII by discipline**: acquire/release pairs (`materializeSpec`/
`removeSpecDir`, `newManager`/—, `newExplorer`/`exploreDispose`) are untied;
only convention (and a few `withX` brackets) prevents leaks. Nothing in the types
stops a caller from acquiring and forgetting, releasing twice, or using after
release. Async (job model) additionally needs **dynamic lifetimes** that lexical
brackets cannot express.

Goal: make the invariants **enforced by construction** where possible, **checked at
runtime** otherwise, and **backstopped by GC** as a last resort — without changing
existing call sites.

## 2. Core abstraction — new module `src/Resource.hs` (module `Resource`)

An opaque handle + total cleanup + one-bit ownership state. The constructor is not
exported; the only way to obtain a `Resource` is `acquire`/`acquireIn`.

```haskell
data ResourceState = Live | Delivered | Released | ReleaseFailed

data Resource a  -- opaque; fields not exported

acquire     :: Text -> IO a -> (a -> IO ()) -> IO (Resource a)
acquireIn   :: Registry -> Text -> IO a -> (a -> IO ()) -> IO (Either ResourceError (Resource a))
release     :: Resource a -> IO ()                          -- idempotent, total
transfer    :: Resource a -> IO ()                          -- disclaim ownership (Delivered)
use         :: Resource a -> (a -> IO b) -> IO (Either ResourceError b)
with        :: Text -> IO a -> (a -> IO ()) -> (Resource a -> IO b) -> IO b

data Registry  -- opaque
newRegistry      :: IO Registry
forceReleaseAll  :: Registry -> IO ()                       -- idempotent, LIFO order

data ResourceError = UseAfterRelease Text | RegistryClosed
```

Semantics:

- **`acquire label get cleanup`** — masked across allocation+finalizer attachment.
  If `get` throws, nothing is registered. Wraps `cleanup` in a catch-all so
  **release is total by construction** (like C++ noexcept destructors). Attaches a
  GC finalizer via a *weak* reference to the state cell: if the handle becomes
  unreachable while still `Live`, run cleanup and log `leak: <label>` — a backstop
  that converts silent leaks into logged, eventually-reclaimed bugs. (The weak ref
  keeps only the state cell, never the value, so cleanup closures don't pin it.)
- **`release`** — atomic CAS `Live → Released`; cleanup runs only on the winning
  transition ⇒ **released at most once, enforced**. Re-release is a logged no-op.
  `Delivered → Released` is a silent no-op (ownership was transferred).
- **`transfer`** — `Live → Delivered`, detaches the finalizer, **skips cleanup**.
  This is the explicit form of today's silent abandonment (A5: `destPath` copies).
- **`use`** — fails with `UseAfterRelease` unless `Live` ⇒ use-after-release is
  a runtime error, not silent corruption. (Single-owner resources need no lock; a
  cross-thread resource can layer an `MVar` — not needed for the current inventory.)
- **`with`** = `bracket acquire release` — the enforced lexical form; on scope
  exit the finalizer is already detached.
- **`acquireIn`** — acquire + register **atomically in the same masked block**:
  registration cannot be forgotten because it lives inside the only constructor.
  A closed registry rejects new acquisitions (and cleans up immediately) ⇒
  no-acquire-after-shutdown enforced.
- **`forceReleaseAll`** — atomically closes the registry, takes all handles,
  releases them **LIFO** (reverse acquisition order: job thread before its spec dir),
  each total. This is the dynamic-lifetime equivalent of bracket's guaranteed cleanup.

## 3. Invariant → mechanism → guarantee level

| Invariant | Mechanism | Level |
|---|---|---|
| Released at most once | CAS on state cell | enforced (runtime) |
| Released at least once — lexical scope | `with` = bracket | enforced for `with` users |
| Released at least once — dynamic scope | `acquireIn` + `forceReleaseAll` at session close | enforced by construction |
| Forgotten release anywhere | GC finalizer: cleanup + leak log | backstop (no timing guarantee) |
| Never delete borrowed (A2, A6, A7) | `Provenance` in value; cleanup = no-op for `Borrowed` | enforced by construction |
| No use-after-release | `use` guard | runtime check |
| No acquire-after-shutdown | registry closed flag | runtime check |
| Release never throws | cleanup wrapped total at `acquire` | enforced by construction |
| Double-delivery / deliver-then-clean | `transfer` detaches finalizer | enforced by construction |

Honest limits: this is **not** linear types — code can still drop a `Resource` and
ignore it; but then the finalizer (backstop) or the registry (dynamic scope) still
reclaims it, and the leak is logged. Optional upgrade for hot cross-module paths:
phantom typestate `Resource (s :: Phase)`, `Phase = Open | Closed` — deferred.

## 4. Typed wrappers (additive functions; existing exports untouched)

| Inventory # | Wrapper (new fn) | Cleanup action | Lifetime class |
|---|---|---|---|
| A1 | `acquireSpec :: Maybe ApalacheSpec -> ApalacheConfig -> IO (Either Text (Resource SpecRes, ApalacheConfig))` | `removeDirectoryRecursive` when `Owned`; no-op when `Borrowed` | lexical (sync) / dynamic (async job) |
| A3 | `acquireSessionDir :: IO (Resource FilePath)` | `removeDirectoryRecursive` | lexical / dynamic |
| A4+A5 | `acquireTraceSet` (+ `transfer` on `destPath` copy) | delete temp trace files | dynamic; ends `Released` xor `Delivered` |
| B1 | `spawnApalache :: ... -> IO (Resource ProcessHandle)` | `terminateProcess` + `waitForProcess` (idempotent) | dynamic — **closes the cancel kill-window** |
| B2 | `acquireApalacheServer :: Maybe Int -> IO (Resource ServerInfo)` | terminate+wait (today's `stopApalacheServer`) | lexical |
| C1 | `acquireExplorer :: Resource ServerInfo -> ... -> IO (Either RpcError (Resource ExplorerRes))` | `exploreDispose` RPC | dynamic; finalizer closes the dropped-connection leak |
| D5 | one shared `Resource Manager` per server process | manager cleanup | process-lifetime, registered |
| D1–D4 | keep existing brackets (already enforced lexically); optional `with` re-base | as today | lexical |
| F1 | `acquireRegistration :: ... -> IO (Resource RegInfo)` | `deregisterService` | process-lifetime; TTL stays as the SIGKILL backstop |

Existing shims re-based **without signature changes** — enforcement moves underneath:
`withSpecDir` → `with` over `acquireSpec`; `withSessionDir` → `with` over
`acquireSessionDir`; `withApalacheServer` → `with` over `acquireApalacheServer`.
The raw pairs (`materializeSpec`/`removeSpecDir`) stay exported for compatibility
but are no longer used by any first-party path.

## 5. Sync/async unification

One vocabulary, two disciplines — matching the earlier async design:

- **Sync paths**: `with` brackets, exactly as today. Behavior unchanged.
- **Async paths** (async-operations-design §4/§11): `JobHandle` holds
  `ResourceId`s, not raw paths; the per-session `JobStore` embeds a `Registry`;
  job submit = `acquireIn` (spec, run dir, process); terminal transition =
  targeted `release`; session close = `forceReleaseAll`. §11's
  `SpecHandle`/`TraceSet` = `Resource SpecRes` / `Resource TraceSetRes`;
  `Delivered` = §11's delivered state. The four §11 invariants are rows in §3.

## 6. Test plan (future)

- Mock resources: acquire/release counts, double-release no-op, use-after-release
  error, transfer skips cleanup.
- GC backstop: acquire, drop, `performGC`, assert cleanup ran + leak logged.
- Registry: `acquireIn`-then-close releases LIFO; acquire-after-close rejected and
  cleaned up.
- Exception paths: bracket release under synchronous and async exceptions.
- Integration: HourClock sync flows unchanged; async job cancel releases spec dir.

## 7. File-by-file change map (all additive)

| File | Change |
|---|---|
| `src/Resource.hs` | **new module**: `Resource`, `Registry`, operations |
| `src/Apalache/SpecSource.hs` | +`acquireSpec` (raw pair kept for compat) |
| `src/Apalache/Command.hs` | +`spawnApalache` returning `Resource ProcessHandle` |
| `src/Apalache/Explorer.hs` | +`acquireApalacheServer`, +`acquireExplorer`; shims re-based |
| `src/Apalache/Rpc/Client.hs`, `src/Protocol/Registry.hs` | shared registered `Manager` instead of per-call |
| `src/Protocol/Mirror.hs` | shims re-based on `with`; no signature or behavior change |
| `ModelMirrors.cabal` | +`Resource` in exposed-modules |
| `docs/async-operations-design.md` | §11 handles reinterpreted as typed `Resource`s (§5 here) |
| `test/Main.hs` | +`ResourceSpec` per §6 |

## Appendix A — As-built record (implementation by AgentTeams, 2026-06)

Implemented additively; every §3 invariant verified by an independent reviewer
hand-audit plus the full test suite (180/180, incl. apalache integration),
cold `cabal clean && cabal build all --ghc-options=-Werror` green.

Deviations from the design text above (all recorded, none blocking):

1. §2 exports: shipped as designed — `ResourceState(..)`, `Provenance(..)`,
   `ResourceError(..)` all exported from `Resource` (an intermediate revision
   kept `ResourceState` internal; corrected during implementation).
   `Apalache.SpecSource` re-exports `Resource.Provenance` — single source of truth.
2. §2 typo fixed: `acquireIn` returns `Either ResourceError (Resource a)`
   (`RegistryClosed` is a constructor, not a type).
3. §4 A3: `acquireSessionDir`/`freshSessionDir`/`removeSessionDir` live in
   `Apalache.SpecSource` (spec + session-dir concerns co-located).
4. §4 D5: the shared process-lifetime manager is a new module,
   `src/Apalache/HttpManager.hs` (unsafePerformIO singleton, `dirCounter`
   pattern). Cleanup is a documented **no-op**: `closeManager` is deprecated
   upstream ("Manager will be closed for you automatically when no longer in
   use") with no replacement; the top-level binding keeps the resource
   reachable so the GC backstop cannot report a spurious leak.
5. §4 C1: `acquireExplorer` takes the existing `ApalacheServer` record as its
   server argument (not a `Resource ServerInfo`); disposal cleanup unchanged.
6. `withSpecDir` is `acquireSpec` + `finally`/`release` rather than literal
   `Resource.with` — the `RegisterError` Left-branch control flow does not fit
   `with`'s shape; semantics and signature unchanged. `withSessionDir` and
   `withApalacheServer` are literal `Resource.with` re-bases.
7. Registry internals: existential-wrapper entries (`RegEntry = forall a.
   RegEntry (Resource a)`) in acquisition order; LIFO/idempotent/total as designed.
8. Deferred to the async-job scope (design §5, not violations): A4/A5
   `acquireTraceSet` and F1 `acquireRegistration`.

Shipped footprint — new: `src/Resource.hs`, `src/Apalache/HttpManager.hs`,
`test/ResourceSpec.hs` (18 tests); modified (additive only): `ModelMirrors.cabal`,
`src/Apalache/{Command,Explorer,SpecSource}.hs`, `src/Apalache/Rpc/Client.hs`,
`src/Protocol/{Mirror,Registry}.hs`, `test/Main.hs`. No existing export,
signature, or behavior changed.
