# ModelMirrors

Verify that your implementation follows the rules defined by a TLA+ model —
through trace replay or interactive symbolic model checking — over a
language-agnostic JSON-lines IPC protocol.

## Overview

ModelMirros uses [Apalache](https://github.com/apalache-mc/apalache) as the
oracle for a TLA+ spec, then conformance-checks a client state machine against
it, state by state (`diffState`: exact variable-by-variable equality). The
oracle works three ways:

1. **Trace replay** — apalache CLI generates ITF counterexample traces (or you
   supply your own); the mirror replays them step-by-step.
2. **Mirror-driven symbolic exploration** — the mirror drives a live apalache
   explorer server, computing each successor state *symbolically* (no
   pregenerated trace) and checking state invariants after every step.
3. **Client-driven explorer sessions** — the mirror proxies raw explorer
   commands (`assumeTransition`, `nextStep`, `queryState`, `checkInvariant`,
   `assumeState`, `rollback`) from the client to the apalache server, for
   targeted, scriptable symbolic checking.

The mirror runs as a standalone process. Clients speak newline-delimited JSON
over **stdio or TCP** — any language can implement a client (a TypeScript one
lives at [MirrorECMA](https://github.com/NzSN/MirrorECMA)). Spec sources —
including their `EXTENDS` dependency closure — can travel **inline** in the
registration messages, so a remote mirror needs no filesystem access to client
files.

```
+----------------+     JSON-lines (stdio | TCP)    +-----------------+
| Client         | <-----------------------------> | Mirror          |
| (your impl)    |                                 | (ModelMirrors)  |
+----------------+                                 +-----------------+
                                                  /        \
                                          CLI (traces)    JSON-RPC (explorer)
                                                /              \
                                          +---------+    +-----------+
                                          | apalache|    | apalache  |
                                          | check   |    | server    |
                                          +---------+    +-----------+
```

## Registration flows

### `register` — generate traces, then replay

The mirror validates the spec, generates traces, then replays them:

```
Client                Mirror
  | --- register --------> |
  |                        | -- validate spec + generate traces
  | <-- spec_validated --- |
  | <-- initial_state ---- |
  | --- report_state ----> |
  | <-- step_ok / mismatch |
  |        ...             |
  | <-- all_steps_done --- |
```

### `register_traces` — replay precomputed traces

Send ITF trace file paths (on the mirror's filesystem). The mirror skips
Apalache entirely and goes straight to replay. **Mirror-local only** — remote
clients should use `register` or the explore flows.

### `register_trace_gen` — generate trace files only

The mirror generates ITF trace files and replies `gen_traces_done` with their
paths (on the mirror). No replay.

### `register_explore` — mirror-driven symbolic checking

Same stepping loop as `register`, but expected states come from symbolic
exploration instead of a concrete trace. `next_step.parameters` carries the
**full expected state** (not paramVars-extracted params).

### `register_explore_session` — client-driven symbolic checking

```
Client                Mirror
  | - register_explore_session > |
  | <-- explorer_ready --------- |
  | --- explore_assume_transition > |
  | <-- explore_transition_status |
  | --- explore_next_step -----> |
  | <-- explore_step_done ------- |
  | --- explore_query_state ----> |
  | <-- explore_state ----------- |
  |        ... any order ...      |
  | --- explore_done -----------> |
  | <-- explore_session_done ---- |
```

Commands and replies strictly alternate. A `protocol_error` rejects the
command but the **session stays open**.

## Quick Start

### Prerequisites

- GHC 9.10+
- [apalache-mc](https://github.com/apalache-mc/apalache) on `PATH`
- cabal (or Bazel 9.1.0)

### Build

```sh
cabal build all        # or: bazel build //...
```

### Run the mirror

```sh
cabal run ModelMirrors                 # stdio mirror (one session)
cabal run ModelMirrors -- --serve 8823 # TCP daemon: one session per
                                       # connection, sequential accept loop
```

Example: pipe a `register` message to the stdio mirror:

```sh
echo '{"proto_step":"register","apalacheConfig":{"specPath":"test/specs/HourClock.tla","initPredicate":null,"nextPredicate":null,"constInit":null,"invariant":"TraceComplete","lengthBound":13,"paramVars":""},"traceConfig":{"numTraces":1,"view":null},"spec":null}' | cabal run ModelMirrors
```

### Run tests

```sh
cabal test all                       # or: bazel test //test:ModelMirrors-test
```

Tests include integration tests that invoke `apalache-mc` (CLI and explorer
server). Expect seconds to minutes of runtime.

## Protocol

All messages are single-line JSON objects tagged by `"proto_step"`.

### Client Messages

| `proto_step` | Fields | Description |
|---|---|---|
| `register` | `apalacheConfig`, `traceConfig`, `spec?` | Generate traces, then replay against the client |
| `register_traces` | `apalacheConfig`, `itfTracePaths` | Replay given trace files (mirror-local paths) |
| `register_trace_gen` | `apalacheConfig`, `traceConfig`, `destPath?`, `spec?` | Generate trace files only |
| `register_explore` | `spec`, `invariants`, `exports`, `maxSteps?` | Mirror-driven symbolic exploration + conformance |
| `register_explore_session` | `spec`, `invariants`, `exports` | Open a client-driven explorer session |
| `report_state` | `state` | Client's actual state after a step |
| `explore_assume_transition` | `transitionId` | Session command: prepare a transition |
| `explore_next_step` | — | Session command: advance one step |
| `explore_query_state` | — | Session command: read the current state |
| `explore_check_invariant` | `invariantId` | Session command: check a state invariant |
| `explore_assume_state` | `state` | Session command: constrain the current state |
| `explore_rollback` | `snapshotId` | Session command: revert to a snapshot |
| `explore_done` | — | Close the session |

#### `register` (with inline spec)

`spec` is optional. When present, the mirror **materializes** the sources to a
temp directory (files named after their `MODULE` headers, so the apalache CLI
resolves `EXTENDS` among them) and ignores `apalacheConfig.specPath`. Source
order matters: **`sources[0]` is the root module**, the rest are dependencies.

```json
{
  "proto_step": "register",
  "apalacheConfig": {
    "specPath": "ignored-when-spec-present",
    "initPredicate": null, "nextPredicate": null, "constInit": null,
    "invariant": "TraceComplete", "lengthBound": 13, "paramVars": ""
  },
  "traceConfig": {"numTraces": 1, "view": null},
  "spec": {"sources": ["---- MODULE ExtMain ----\n...", "---- MODULE ExtDep ----\n..."]}
}
```

### Mirror Messages

| `proto_step` | Fields | Description |
|---|---|---|
| `spec_validated` | `result`: `"valid"` \| `{invalid}` | Spec accepted; stepping begins |
| `initial_state` | `action`, `state` | First expected state |
| `next_step` | `action`, `parameters` | Next expected step |
| `step_ok` | — | Reported state matched |
| `step_mismatch` | `expected`, `actual` | Conformance failure; run aborts |
| `all_steps_done` | — | All traces/steps verified |
| `gen_traces_done` | `itfTracePaths` | Trace files written (mirror-local paths) |
| `explorer_ready` | `initTransitions`, `nextTransitions`, `stateInvariants` | Session opened |
| `explore_transition_status` / `explore_assume_status` | `status`: `ENABLED` \| `DISABLED` \| `UNKNOWN` | Command result |
| `explore_step_done` | `stepNo` | Step advanced |
| `explore_state` | `state` | Current symbolic state |
| `explore_invariant_status` | `status`: `SATISFIED` \| `VIOLATED` \| `UNKNOWN` | Invariant result |
| `explore_rollback_done` | `snapshotId` | Reverted |
| `explore_session_done` | — | Session closed cleanly |
| `register_error` | `error` | Registration failed; run ends |
| `protocol_error` | `error` | Protocol violation (session flows: session survives) |

#### `step_mismatch`

```json
{
  "proto_step": "step_mismatch",
  "expected": {"count": {"#bigint": "1"}},
  "actual": {"count": {"#bigint": "2"}}
}
```

### Transports

| Mode | How | Notes |
|---|---|---|
| stdio | run with no args | One session, then exit |
| TCP | `--serve <port>` | Daemon: one session per connection, sequential accept loop; a dropped client is logged to stderr and the loop continues. Plain TCP, no TLS |

## Writing a Client

A client in any language must:

1. Spawn the mirror (stdio) or connect to a mirror daemon (TCP).
2. Send one registration message (`register`, `register_traces`,
   `register_trace_gen`, `register_explore`, or `register_explore_session`).
3. For stepping flows: wait for `spec_validated`, then answer each
   `initial_state`/`next_step` with `report_state`; handle `step_ok` /
   `step_mismatch`; finish at `all_steps_done`.
4. For explorer sessions: wait for `explorer_ready`, then alternate
   `explore_*` commands with their replies; finish with `explore_done`.

State maps use the Apalache ITF value encoding (ints as `{"#bigint": "42"}`,
tuples as `{"#tup": [...]}`, etc.). Reported states must contain **every**
state variable — including `action_taken` if the spec has one, since the
mirror derives action names from it.

See `src/Protocol/Client.hs` for a reference Haskell client implementation,
including `cannedClient` (pre-canned responses), `fixedClient` (static state),
and `hourClockClient` (real logic for the HourClock spec).

## Self-Verification

ModelMirrors verifies its own mirror implementation using **model-based
testing (MBT)**. A TLA+ protocol model generates expected action sequences;
the real mirror is driven through the same flows and its output is compared.

### How it works

**1. Model the protocol** — `specs/MirrorProtocol.tla` is a state machine with
two parties (mirror and client), message channels, and actions like
`MirrorRecvRegister`, `MirrorSendInitialState`, `MirrorRecvReportState`.
Invariants act as stop conditions — violating them produces counterexample
traces.

**2. Generate traces** — Apalache model-checks the spec. When an invariant is
violated, it produces ITF traces — sequences of states showing every action
taken. With `numTraces = 100`, we get distinct protocol flows covering
different registration paths, step counts, and Ok/Mismatch branches.

**3. Drive the mirror** — For each trace, the test forks the real mirror
and a real HourClock client (`hourClockClient` + `runClientWithTraces`).
The client sends a `RegisterTraces` message with a pre-generated HourClock
trace; the mirror replays step-by-step; the client responds with correct
state computed via `hcTick`. The mirror returns a `[MirrorStep]` — a
structured trace of every protocol event it performed.

**4. Normalize** — `MinimalTraceCheck.normalize` collapses timing-dependent
pairs (`RecvReport+StepOk` → `StepOk`, `RecvReport+StepMismatch` →
`StepMismatch`) and strips terminal `AllStepsDone`.

**5. Build the expected sequence** — The TLA+ trace's mirror actions are
extracted and normalized to canonical names (e.g. `RecvRegister` →
`RecvRegisterTraces` since the test always uses that path).

**6. Compare** — Both sequences are trimmed to the spec's step count and
compared with `==`. The key insight: step results (`StepOk` vs `StepMismatch`)
map to the same canonical name — the MBT test verifies protocol message
*sequence*, not state correctness.

The apalache JSON-RPC client is verified the same way:
`specs/ApalacheRPCClient.tla` models the client as a nondeterministic oracle
over `specs/AapalacheRPCProtocol.tla`; `ServerBehaviorSpec` replays
spec-generated call sequences against a live apalache explorer server in
lockstep.

### Verified models

| Spec | Checked with | Properties |
|---|---|---|
| `specs/MirrorProtocol.tla` | TLC | `PhaseOk`, `NoProtocolError` |
| `specs/MinimalTraceCheck.tla` | TLC, Apalache | `SelfCheck`, `NormalizeIdempotent` |

## Project Structure

```
ModelMirrors/
├── app/              Executable entry point (stdio mirror / --serve daemon)
├── src/
│   ├── Apalache/     Apalache types, command runner, trace parsing,
│   │                 explorer RPC client, inline-spec materialization
│   ├── Engine/       Trace replay engine and step diffing
│   ├── Protocol/     IPC protocol (core types, JSON format, transports)
│   └── MinimalTraceCheck.hs   Trace normalization and comparison
├── test/
│   ├── Main.hs       Test runner
│   └── specs/        TLA+ specs used by integration tests
├── specs/            Protocol specifications (TLA+)
├── docs/             Design documents
├── ModelMirrors.cabal
└── BUILD.bazel
```

### Key Modules

| Module | Purpose |
|---|---|
| `Apalache.Types` | ITF trace types, trace config, value types, JSON |
| `Apalache.Command` | Shell out to apalache-mc (validate, generate) |
| `Apalache.Explorer` | Explorer session management over the apalache server |
| `Apalache.Rpc.Client` | JSON-RPC client for the apalache explorer server |
| `Apalache.Rpc.Types` | RPC request/response types, `ApalacheSpec` |
| `Apalache.SpecSource` | Materialize inline spec sources to a temp dir |
| `Engine.Core` | `traceSteps`, `diffState` |
| `Engine.Replay` | `EngineM` typeclass for replaying traces |
| `Engine.Interactive` | IPC-based `StateDriver` |
| `Protocol.Core` | `ClientMessage`, `MirrorMessage`, `ProtocolState` |
| `Protocol.Format.Json` | JSON serialization for protocol messages |
| `Protocol.Transport.Core` | `Transport` typeclass |
| `Protocol.Transport.Stdio` | Stdio implementation of `Transport` |
| `Protocol.Transport.Tcp` | TCP implementation + `serveTcp` accept loop |
| `Protocol.Client` | Reference client with canned/fixed/hourClock impl |
| `Protocol.Mirror` | Mirror flows: replay, explore, sessions, `run` |
| `MinimalTraceCheck` | Normalize and compare MirrorStep sequences |

## License

See [LICENSE](LICENSE).
