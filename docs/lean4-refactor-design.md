# Refactoring ModelMirrors via Lean 4 — Design Doc

> Status: proposal (branch `AS-LEAN`)
> Scope: port the ModelMirrors mirror (currently ~6,000 lines of GHC2024
> Haskell, 33 library modules) to Lean 4, turning the informally-tested core
> into a formally verified core, while keeping the JSON-lines wire protocol
> bit-for-bit compatible with existing clients (MirrorRust, MirrorECMA).

## 1. Motivation

ModelMirrors is itself a verification tool: it conformance-checks a client
state machine against a TLA+ model using apalache as the oracle. Its own
correctness, however, currently rests on:

- integration tests (`tasty`/`tasty-hunit` + QuickCheck), which shell out to
  `apalache-mc` and take minutes;
- TLA+ models of the protocol (`specs/MirrorProtocol.tla`,
  `MirrorProtocolFaults.tla`, `MirrorProtocolWitness.tla`), which are
  model-checked against an *abstraction* of the mirror, not the code that
  ships;
- code review discipline (`-Wall`, explicit imports, enforced RAII in
  `Resource.hs`).

There is no mechanical link between the TLA+ models and the Haskell
implementation, and several core algorithms carry subtle invariants that
tests can only sample:

- `Engine.Core.diffState` must agree with value equality exactly (after
  meta-key filtering, depth/hint caps), or conformance checking silently
  passes/fails for the wrong reason;
- `Eq Value` for `VSet` is a hand-rolled set-equality (`length &&` pairwise
  membership) — an easy place for an order/duplication bug;
- the mirror session protocol (`Protocol.Core.ClientMessage` /
  `MirrorMessage` / `ProtocolState`) has first-message and ordering rules
  enforced only by runtime checks;
- `Resource` guarantees "cleanup runs at most once, release never throws,
  leaks are logged and reclaimed by a finalizer" by careful `IORef` +
  `atomicModifyIORef'` engineering;
- `Protocol.AsyncJobs` promises terminal-once job phases and outcomes that
  mirror the synchronous replies exactly.

Lean 4 is a plausible implementation language *and* proof assistant: the
same artifact can be the shipping binary and the verified model, closing the
abstraction gap between `specs/*.tla` and the executable.

## 2. Goals and non-goals

### Goals

1. **Verified pure core.** Port `Value`, ITF trace semantics,
   `diffState`/diff hints, the protocol state machine, the async-job
   machine, and the resource lifecycle *model* to Lean 4 with
   machine-checked proofs of the invariants in §6.
2. **Wire compatibility.** The newline-delimited JSON protocol
   (`docs/protocol-spec.md`) is unchanged. Existing clients
   (MirrorRust, MirrorECMA) must interoperate without modification, byte for
   byte on the wire.
3. **Feature parity.** stdio/TCP/mTLS transports, all six `Register*`
   flows, explorer sessions, async validate/trace-gen jobs, Consul
   discovery, CLI surface (`app/Main.hs`: default stdio, `--serve`,
   `--server --tls`, `validate`).
4. **Keep the TLA+ specs.** They remain the model-level specification; the
   Lean state machine is proved to refine them (see §6.3), replacing
   "model + hope" with "model + proof + code".

### Non-goals

- Verifying apalache, the JVM, TLS libraries, or the OS — everything behind
  the effect boundary (§5.4) is trusted computing base (TCB), explicitly
  inventoried.
- Proving liveness of the concurrent TLS dispatcher; we prove safety
  properties of the sequential session core and state the dispatcher's
  obligations as assumptions.
- Rewriting the clients. The protocol is frozen.

## 3. Current architecture (what is being ported)

~6,000 LOC, single cabal package, layers that map cleanly onto a Lean
target:

| Layer | Haskell modules | Responsibility |
| ----- | --------------- | -------------- |
| Oracle adapters | `Apalache.{Core,Types,Command,Trace,Explorer,HttpManager,Rpc.*,SpecSource}` (~1,900 LOC) | `apalache-mc` CLI runner (typecheck/check/trace-gen), ITF trace parsing, explorer JSON-RPC client/server-behavior, inline spec materialization |
| Engine | `Engine{,.Core,.Types,.Replay,.Interactive}`, `MinimalTraceCheck` (~350 LOC) | `diffState`, `traceSteps`, diff hints, replay/interactive drivers |
| Protocol | `Protocol.*` incl. `Mirror` (778 LOC), `AsyncJobs` (497 LOC), `Format.Json` (413 LOC), transports (Stdio/TCP/TLS/Mock), `Registry`, `Discover`, option parsers (~2,900 LOC) | session state machine, JSON codec, transports, Consul discovery, async job store |
| Lifecycle | `Resource` (213 LOC) | enforced-RAII handle (Live/Delivered/Released/ReleaseFailed, Owned/Borrowed provenance) |
| Shell | `app/Main.hs` (233 LOC) | CLI: stdio mirror, TCP daemon, mTLS daemon (bounded dispatcher), `validate` client |

Core data types (all portable, no GHC-isms):

- `Apalache.Types.Value` — ITF values: `VInt Integer | VBool | VStr |
  VSet [Value] | VSeq | VTuple | VRecord (Map Text Value) | VMap |
  VVariant Text Value | VUnserializable Text | VNull`, with hand-written
  `Eq` (set semantics for `VSet`).
- `Engine.Types` — `Step`, `StepCommand`, `DiffHint` (7 constructors),
  `Path = [PathSeg]`, `StateDiff`.
- `Protocol.Core` — `ClientMessage` (19 constructors), `MirrorMessage`
  (20), `ProtocolState = Idle|Validating|Ready|Stepping|Done`, plus the
  async job vocabulary (`JobId/JobKind/JobPhase/JobOutcome`).

## 4. Why Lean 4 (and not "Haskell + more TLA+" or Liquid Haskell)

- **One artifact.** Lean 4 compiles to efficient native code via C; the
  verified functions *are* the shipped functions. No extraction gap, no
  shadow model to keep in sync (the current TLA+/Haskell split).
- **Dependent types where they pay.** The session protocol can be encoded
  as a phase-indexed interface (§5.3) so that e.g. "the first message on a
  fresh transport must be a `Register*`" is a *type error*, not a runtime
  `protocol_error` path that needs tests.
- **Mature enough ecosystem for this shape of program.** `batteries`/`Std`
  give finite maps, `Lean.Data.Json` gives JSON, `IO.Process` spawns
  `apalache-mc`. `Int` is arbitrary-precision — a direct match for
  `VInt Integer`. Strings are UTF-8 — a direct match for `Text`.
- The gaps (TLS, HTTP client, sockets, structured concurrency) are real and
  are the main cost of the port; §5.4 is explicit about the FFI plan.

Alternatives considered:

- **Stay in Haskell, verify with Liquid Haskell or extraction.**
  Refinement types would cover `diffState` nicely but cannot realistically
  capture the protocol state machine or the `Resource` ownership protocol
  without contorting the code; extraction approaches reintroduce the
  two-artifact gap.
- **Verify a Lean model only, keep shipping Haskell.** Cheapest, but it is
  exactly today's TLA+ situation with a different proof tool; rejected.

## 5. Target architecture

Mirror the current layered structure, but with a hard proof/effect seam:

```
lean/                            -- new tree on branch AS-LEAN
├── ModelMirrors/                -- pure, proof-carrying core (no IO)
│   ├── Core/Value.lean          -- ITF Value + decidable, proven set equality
│   ├── Core/Trace.lean          -- ItfTrace, TraceState, applyParamVars, traceSteps
│   ├── Core/Diff.lean           -- diffState, DiffHint, caps + all §6.1 theorems
│   ├── Core/Protocol.lean       -- ClientMessage, MirrorMessage, session machine
│   ├── Core/Jobs.lean           -- async job state machine + §6.4 theorems
│   ├── Core/Resource.lean       -- abstract lifecycle model + §6.5 theorems
│   └── Codec/Json.lean          -- total encode/decode + §6.6 round-trip proofs
├── ModelMirrorsIO/              -- effectful shell (trusted, thin, audited)
│   ├── Transport/{Stdio,Tcp,Tls}.lean
│   ├── Apalache/{Cli,Explorer,SpecSource}.lean
│   ├── Registry.lean            -- Consul HTTP client
│   └── Mirror/Session.lean      -- runs Core.Protocol against a Transport
├── Ffi/                         -- C shims: TLS (OpenSSL or s2n-tls), sockets
├── Main.lean                    -- CLI parity with app/Main.hs
└── test/                        -- golden wire fixtures, differential tests
```

### 5.1 Layer 0 — verified pure core

Faithful, definitionally-simple ports. Design rules:

- Every Haskell `Map Text Value` becomes a finite map with a *provably
  extensional* equality (`Std.TreeMap` or an assoc-list-backed map with
  lawful instances). This choice is what makes `diffState` soundness
  statable at all.
- `VSet` keeps the list-of-elements representation (ITF round-trips
  preserve duplicates until interpreted); set equality is a *defined*
  relation `setEq` with a `Decidable` instance plus the lemma
  `setEq xs ys ↔ ∀ v, v ∈ xs ↔ v ∈ ys`, replacing the hand-written Haskell
  `Eq` instance with a verified decision procedure.
- All partiality is explicit: implicit Haskell bottoms (e.g. partial lookups
  in trace splitting) become `Option`/`Except`, discharged by stated
  invariants.

### 5.2 Layer 1 — codecs

`Protocol.Format.Json` (413 LOC of orphan aeson instances) becomes two
total functions per message type:

```lean
encodeClient : ClientMessage → Lean.Json
decodeClient : Lean.Json → Except DecodeError ClientMessage
```

with round-trip theorems (§6.6). Field names and encodings are pinned by
golden fixtures extracted from the Haskell test suite *before* any Lean
code ships, so aeson quirks (sum encoding, `Maybe` field omission, number
formats) are frozen as data, not rediscovered.

### 5.3 Layer 2 — the session machine as a type

The mirror loop (`Protocol.Mirror.run`, 778 LOC of hand-threaded state)
becomes a finite, explicit transition function over a phase-indexed state:

```lean
inductive Phase | idle | validating | generating | ready | stepping | exploring | done

structure Session (p : Phase) where ...

def step : Session p → ClientMessage →
  Except ProtocolError (Σ p', Session p' × List MirrorMessage)
```

- `Phase` mirrors `Ms` in `specs/MirrorProtocol.tla`
  (`{"idle","validating","generating","ready","stepping","exploring","done"}`),
  extended with the async-job flows that postdate the TLA+ spec.
- Illegal orderings are *unrepresentable*: there is no `step` case
  accepting `report_state` in phase `idle`, so the first-message rule and
  the replay ordering (`initial_state → report_state → step_ok → …`) hold
  by construction. The remaining runtime `protocol_error` covers decode
  failures and oracle failures only.
- The effectful driver in `ModelMirrorsIO.Mirror.Session` is a thin fold —
  `recv line → decode → Core.step → encode → send` — with all oracle calls
  (`validateSpecIn`, `generateTracesIn`, explorer RPC) injected as
  parameters, so the core stays pure and the §6.3 refinement proof never
  mentions IO.

### 5.4 Layer 3 — effect boundary (the TCB)

Everything here is *trusted, not proved*; the design goal is to keep it
small, boring, and line-auditable:

| Capability | Haskell today | Lean 4 plan |
| ---------- | ------------- | ----------- |
| Spawn `apalache-mc`, per-session `--run-dir`, cwd isolation | `process`, `temporary` | `IO.Process.spawn`; port the "cwd = temp dir" isolation as code + regression tests; filesystem ops via `IO.FS` |
| stdio transport | `Protocol.Transport.Stdio` (16 LOC) | `IO.getStdin`/`IO.getStdout`, line framing |
| TCP transport + accept loop | `network` (151 LOC) | small C shim over `socket/bind/accept`, or a community socket package; keep "one session per connection, drops logged and survived" semantics |
| TLS 1.3 mutual auth, fingerprints, expiry warnings, CA/SAN validation | `tls`/`crypton*` (503 LOC) | **FFI to OpenSSL (or s2n-tls)** via a C shim exposing exactly `serveTlsOn`/`connectTlsPinned`-shaped functions. No Lean TLS stack exists; do not write one. Largest TCB addition — see §9. |
| Explorer JSON-RPC over HTTP | `http-client` (Explorer 329 + Rpc.Client 96 LOC) | minimal HTTP/1.1 client in Lean (loopback, ephemeral port, JSON bodies) or libcurl FFI — spike in Phase 5 |
| Consul registry client | `Registry` (119 LOC) + `Discover` | same HTTP client as explorer; JSON via `Lean.Data.Json` |
| Concurrency (bounded dispatcher, async jobs, registry heartbeats) | `stm`, threads | Lean `Task`/threads + `IO.Mutex`/channels; the *sequential* session core is proven, the dispatcher is trusted with a documented obligation list |
| SIGINT/SIGTERM deregistration | `unix` | C shim or `IO` signal hooks (POSIX-only, matching today's Windows caveat) |

## 6. Verification targets (the point of the exercise)

Ordered by value-per-effort. Each is stated against the *ported
definitions*, so the proof obligation doubles as the port's acceptance
test.

### 6.1 Diff engine soundness and completeness (`Engine.Core`)

Let `filterMeta` drop keys `#*`, `action_taken`, `parameters` (port of
`isMetaKey`), and let `≈` be the proven-correct value equality.

- **Soundness:** `diffState e a = StatesMatch → filterMeta e ≈ filterMeta a`.
- **Completeness (uncapped core):** `filterMeta e ≈ filterMeta a →` the
  uncapped diff produces `[]`.
- **Cap correctness:** `capHints` preserves all hints up to
  `maxDiffHints = 50` and appends exactly one `HTruncated` carrying the
  path of the first dropped hint.
- **Path validity:** every `DiffHint` path from `diffState e a` navigates
  to a subterm of `e` or `a` (or denotes a missing key on the stated
  side). Catches off-by-one `Index` bugs in `diffElems`.
- **`VSet` equality law:** the decidable set equality is equivalent to
  extensional membership equality (fixes the hand-rolled instance for
  good).

### 6.2 Trace pipeline (`Apalache.Trace` + `traceSteps`)

- `applyParamVars` repartitions `parameters`/`stateVars` losslessly: the
  union of the two maps is invariant, and every key lands in exactly one
  side.
- `traceSteps` preserves length and order, and the injected
  `action_taken` equals the step's action name.

### 6.3 Protocol refinement vs the TLA+ model

- Encode `specs/MirrorProtocol.tla`'s mirror-side transition relation as an
  inductive predicate `TlaStep` in Lean (manual, ~one page: the state
  space is 7 phases × 19 message tags).
- **Theorem (safety refinement):** every `Core.step` transition of the
  Lean session machine corresponds to a `TlaStep` (modulo the async-job
  and explorer-session extensions, which are stated as *extensions* of the
  TLA+ state and are candidates for upstreaming into `specs/`).
- **Theorem (no unsolicited output):** in each phase, the set of emittable
  `MirrorMessage` constructors is exactly the spec'd set (e.g. no
  `StepOk` before `ReportState` in `stepping`).

### 6.4 Async jobs (`Protocol.AsyncJobs`)

- Terminal phases (`JobDone`/`JobFailed`/`JobCancelled`) are absorbing.
- `JobUnknown` is returned exactly for ids never submitted or evicted.
- **Outcome congruence:** a completed `ValidateJob`'s `JobOutcome` payload
  equals what the synchronous `RegisterValidate` flow would reply
  (`SpecValidated`/`RegisterError`) — stated as observational equality of
  the two pure machines on identical inputs.
- Bound enforcement: validate bounds outside `[1, maxValidateBound = 100]`
  are rejected, in the async and sync paths alike.

### 6.5 Resource lifecycle (`Resource`)

Model the ownership protocol abstractly (no `IORef`): a resource is a
token in `{Live, Delivered, Released, ReleaseFailed} × {Owned, Borrowed}`.

- Cleanup runs **at most once**; `Borrowed` cleanup is a no-op;
  `Delivered` never cleans up.
- `use` on a non-`Live` resource is a type error in the Lean encoding
  (linear-style handle), so the finalizer backstop becomes dead code *for
  in-language uses*; a GC finalizer is retained only at the FFI boundary.

### 6.6 Codec round-trips

For each message type `M`: `decode (encode m) = Except.ok m`. Wire-level
equivalence with the *Haskell* aeson instances is checked by golden
fixtures + differential tests (§8), since cross-language theorems are out
of reach.

## 7. Build, tooling, packaging

- `lake` build; pin a Lean toolchain (`lean-toolchain`) and `batteries`
  at a pinned rev.
- CI: `lake build` (proofs are checked by the build — no separate step),
  `lake test` for fixtures/differential tests, plus the existing apalache
  integration suite re-pointed at the Lean binary.
- Keep the `LC_ALL=C.UTF-8` requirement (apalache quirk, unchanged).
- The Haskell package stays on `main` until Phase 7 parity sign-off; the
  port develops on this branch (`AS-LEAN`) in a `lean/` subdirectory so
  both build side by side.

## 8. Migration plan

| Phase | Deliverable | Exit criterion |
| ----- | ----------- | -------------- |
| 0. Fixture freeze | Golden JSON wire corpus generated from the Haskell test suite (all 39 message constructors × representative payloads); recorded apalache explorer RPC transcripts | Corpus replayed green against the Haskell mirror |
| 1. Pure core port | `Core/Value,Trace,Diff` + §6.1–6.2 proofs | `lake build` green; diff engine cross-tested vs Haskell on QuickCheck-generated value pairs (differential) |
| 2. Codec | `Codec/Json` + §6.6 proofs; corpus decodes/encodes byte-identically | 100% fixture round-trip, both directions |
| 3. Session machine + stdio | `Core/Protocol` + §6.3 refinement; stdio driver; CLI default mode | existing stdio integration tests pass against the Lean binary |
| 4. Jobs | `Core/Jobs` + §6.4; `ModelMirrorsIO` job store with `Task`-based workers | async validate/trace-gen parity vs Haskell on recorded workloads |
| 5. Oracle adapters | apalache CLI runner, spec materialization, explorer JSON-RPC (HTTP spike: pure-Lean minimal client vs libcurl FFI — prefer pure Lean if the explorer's HTTP surface allows) | HourClock end-to-end (validate, trace-gen, replay, explorer session) green |
| 6. Transports + registry | TCP, mTLS via OpenSSL FFI, Consul client + discovery, signal handling | `--serve`/`--server`/`validate --registry` parity; interop with MirrorRust and MirrorECMA over mTLS |
| 7. Cutover | docs, CHANGELOG, deprecation plan for the Haskell build | full test matrix green on both implementations for one release cycle; then Haskell moves to maintenance |

Phases 1–4 are low-risk and high-value; phases 5–6 carry all the FFI risk
and can ship incrementally behind the unchanged wire protocol.

## 9. Risks and open questions

1. **TLS via FFI grows the TCB.** Today's `tls`/`crypton` stack is pure
   Haskell; linking OpenSSL means trusting a C library *and* our shim.
   Mitigations: pin and vendor the TLS backend, keep the shim to
   connect/accept/read/write + fingerprint extraction, fuzz the shim, and
   treat the OpenSSL config surface (TLS 1.3-only, client certs required,
   CA/SAN validation) as the #1 code-review target.
2. **HTTP client gap.** Explorer RPC and Consul need an HTTP/1.1 client.
   Writing one in Lean is feasible (loopback, JSON, no TLS for loopback;
   Consul is plain HTTP today) but must handle chunked responses and
   timeouts correctly. Spike in Phase 5 before committing.
3. **Map choice drives proof ergonomics.** `Std.HashMap` is fast but its
   extensional theory is painful; tree/assoc maps prove easily but are
   slower on wide states. Plan: prove against the slow, obviously correct
   structure, then optionally swap in a hash map behind a verified
   interface if profiling demands it. Real state maps are small; expect
   the simple structure to suffice.
4. **Proof maintenance cost.** §6.3's refinement must be updated whenever
   the protocol grows (as it did with async jobs). Accepted as a feature:
   the TLA+ spec, the Lean model, and the code can no longer drift
   silently.
5. **Unicode/locale and apalache quirks** (UTF-8 locale, `_apalache-out`
   litter, cwd isolation) are behavior, not types: ported as documented
   shell obligations with regression tests, not proofs.
6. **Performance.** No concerns expected: the workload is dominated by
   apalache itself; the mirror is an I/O multiplexer over small JSON
   messages. Lean's reference-counted persistent structures are adequate;
   verify with a replay benchmark in Phase 3.
7. **Open question — linearity vs finalizers.** Whether to keep any GC
   finalizer backstop for Lean-internal resources once `use`-on-dead is
   unrepresentable; default answer: no — finalizers only behind the FFI
   boundary, where Lean's type system cannot see ownership.

## 10. Relationship to existing docs

- `docs/protocol-spec.md` — frozen contract; the Lean codec is tested
  against it byte-for-byte.
- `docs/resource-model-design.md` — §6.5 formalizes its invariants.
- `docs/async-operations-design.md` — §6.4 formalizes its job model.
- `specs/MirrorProtocol.tla` and siblings — remain the model-level spec;
  §6.3 links them to code for the first time.
