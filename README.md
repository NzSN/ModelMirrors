# ModelMirrors

Verify that your implementation follows the rules defined by a TLA+ model
through trace replay over a language-agnostic IPC protocol.

## Overview

ModelMirrors uses [Apalache](https://github.com/apalache-mc/apalache) to
generate or load ITF traces from a TLA+ spec, then replays those traces
step-by-step against a client process. At each step the mirror compares the
client's actual state against the expected state from the trace and reports
whether they match.

The mirror runs as a standalone process. Clients communicate with it over
stdin/stdout using JSON messages. This means clients can be written in any
language — they just need to speak the protocol.

```
+----------------+     JSON over stdin/stdout     +-----------------+
| Client Process | <----------------------------> | Mirror Process  |
| (your impl)    |                                | (ModelMirrors)  |
+----------------+                                +-----------------+
                                                          |
                                                    +-----+------+
                                                    | Apalache   |
                                                    | (TLA+ spec)|
                                                    +------------+
```

## Two ways to register

### Register with a spec file (full pipeline)

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

### RegisterTraces with inline ITF traces (skip validation + generation)

If you already have ITF traces (e.g. generated offline, or from a previous
run), send them directly. The mirror skips Apalache entirely and goes straight
to replay:

```
Client                Mirror
  | -- register_traces --> |
  | <-- spec_validated --- |
  | <-- initial_state ---- |
  | --- report_state ----> |
  |        ...             |
  | <-- all_steps_done --- |
```

## Quick Start

### Prerequisites

- GHC 9.10+
- [apalache-mc](https://github.com/apalache-mc/apalache) on `PATH`
- cabal (or Bazel 8.7.0)

### Build

```sh
cabal build all
```

Or with Bazel:

```sh
bazel build //...
```

### Run the mirror

```sh
cabal run ModelMirrors
```

The mirror reads a single `ClientMessage` from stdin, processes it, and writes
`MirrorMessage` replies to stdout.

Example: pipe a `Register` message to the mirror using your spec file:

```sh
echo '{"proto_step":"register","specPath":"test/specs/HourClock.tla","traceConfig":{"invariant":"Inv","lengthBound":3,"numTraces":2,"view":null,"cinit":null,"paramVars":""}}' | cabal run ModelMirrors
```

Example: pipe a `RegisterTraces` message with inline ITF traces:

```sh
echo '{"proto_step":"register_traces","itfTraces":[...]}' | cabal run ModelMirrors
```

### Run tests

```sh
cabal test all
```

Tests include integration tests that invoke `apalache-mc` on
`test/specs/HourClock.tla`. Expect seconds to minutes of runtime.

## Protocol

Language independence is a goal of ModelMirrors. The protocol is the common
knowledge shared between client and mirror.

All messages are JSON objects with a `"proto_step"` field that identifies the
message type.

### Client Messages

| `proto_step`      | Description                                                    |
|-------------------|----------------------------------------------------------------|
| `register`        | Register a TLA+ spec file and trace generation config          |
| `register_traces` | Provide ITF traces directly — skip validation and generation   |
| `report_state`    | Report client's actual state after executing a step            |

#### `register`

```json
{
  "proto_step": "register",
  "specPath": "path/to/spec.tla",
  "traceConfig": {
    "invariant": "Inv",
    "lengthBound": 5,
    "numTraces": 2,
    "view": null,
    "cinit": null,
    "paramVars": ""
  }
}
```

#### `register_traces`

```json
{
  "proto_step": "register_traces",
  "itfTraces": [
    {
      "vars": ["x", "y"],
      "param_vars": [],
      "params": [],
      "states": [
        {"action_taken": "init", "x": {"#bigint": "0"}, "y": {"#bigint": "0"}},
        {"action_taken": "inc", "x": {"#bigint": "1"}, "y": {"#bigint": "0"}}
      ]
    }
  ]
}
```

#### `report_state`

```json
{
  "proto_step": "report_state",
  "state": {"x": {"#bigint": "1"}, "y": {"#bigint": "0"}}
}
```

### Mirror Messages

| `proto_step`     | Description                                    |
|------------------|------------------------------------------------|
| `spec_validated` | Spec validation result (`"valid"` or `{"invalid": "..."}`) |
| `register_error` | Error during spec validation or trace generation |
| `initial_state`  | Initial state for a trace                      |
| `next_step`      | Next action and parameters                     |
| `step_ok`        | Client state matched expected state            |
| `step_mismatch`  | Client state diverged from expected            |
| `all_steps_done` | All traces replayed successfully               |
| `protocol_error` | Protocol error                                 |

#### `spec_validated`

```json
{"proto_step": "spec_validated", "result": "valid"}
```

#### `initial_state`

```json
{
  "proto_step": "initial_state",
  "action": "init",
  "state": {"count": {"#bigint": "0"}}
}
```

#### `next_step`

```json
{
  "proto_step": "next_step",
  "action": "inc",
  "parameters": {"stride": {"#bigint": "2"}}
}
```

#### `step_mismatch`

```json
{
  "proto_step": "step_mismatch",
  "expected": {"count": {"#bigint": "1"}},
  "actual": {"count": {"#bigint": "2"}}
}
```

## Writing a Client

A client in any language must:

1. Open the mirror as a subprocess (or connect to it via stdin/stdout).
2. Send either a `register` or `register_traces` message.
3. Wait for `spec_validated`.
4. Wait for `initial_state` to begin a trace.
5. For each `next_step`, execute the action, then send `report_state` with the resulting state.
6. Handle `step_ok` (continue) or `step_mismatch` (failure).
7. Wait for `all_steps_done` to signal completion.

See `src/Protocol/Client.hs` for a reference Haskell client implementation,
including `cannedClient` (pre-canned responses), `fixedClient` (static state),
and `hourClockClient` (real logic for the HourClock spec).

## Project Structure

```
ModelMirrors/
├── app/              Executable entry point (stdio mirror)
├── src/
│   ├── Apalache/     Apalache types, command runner, trace parsing
│   ├── Engine/       Trace replay engine and step diffing
│   └── Protocol/     IPC protocol (core types, JSON format, transport)
├── test/
│   ├── Main.hs       Test runner
│   └── specs/        TLA+ specs used by integration tests
├── specs/            Protocol specification (TLA+)
├── docs/             Design documents
├── ModelMirrors.cabal
└── BUILD.bazel
```

### Key Modules

| Module                          | Purpose                                           |
|---------------------------------|---------------------------------------------------|
| `Apalache.Types`                | ITF trace types, trace config, value types, JSON  |
| `Apalache.Command`              | Shell out to apalache-mc (validate, generate)     |
| `Engine.Core`                   | `traceSteps`, `diffState`                         |
| `Engine.Replay`                 | `EngineM` typeclass for replaying traces          |
| `Engine.Interactive`            | IPC-based `StateDriver`                           |
| `Protocol.Core`                 | `ClientMessage`, `MirrorMessage`, `ProtocolState` |
| `Protocol.Format.Json`          | JSON serialization for protocol messages          |
| `Protocol.Transport.Core`       | `Transport` typeclass                             |
| `Protocol.Transport.Stdio`      | Stdio implementation of `Transport`               |
| `Protocol.Client`               | Reference client with canned/fixed/hourClock impl |
| `Protocol.Mirror`               | `runMirror`, `runMirrorWithTraces`                |

## License

See [LICENSE](LICENSE).
