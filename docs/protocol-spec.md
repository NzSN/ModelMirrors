# Mirror Protocol Specification

This document defines the protocol for communicating with a ModelMirrors mirror process. Client implementations in any language must follow this spec to interact correctly.

## Transport

The mirror process communicates over **stdio** (stdin/stdout). Messages are **newline-delimited JSON**: one JSON object per line, encoded as UTF-8.

Future transports (e.g. socket) may be added but the message format remains the same.

## Message Envelope

Every message is a JSON object with a required `proto_step` field that acts as a discriminant:

```jsonc
{ "proto_step": "<tag>", /* ...other fields... */ }
```

## Client → Mirror Messages

The client sends these message types to the mirror process.

### Register

Initiates a session. Sends the path to a TLA+ spec and trace generation parameters.

| Field | Tag |
|-------|-----|
| `proto_step` | `"register"` |
| `specPath` | `string` — path to a `.tla` file |
| `traceConfig` | `object` (see below) |

**`traceConfig` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `invariant` | `string` | Name of the invariant to check |
| `lengthBound` | `number` (integer) | Maximum length of generated traces |
| `numTraces` | `number` (integer) | Number of counterexample traces to generate |

**Example:**
```json
{
  "proto_step": "register",
  "specPath": "./specs/HourClock.tla",
  "traceConfig": {
    "invariant": "TypeOK",
    "lengthBound": 10,
    "numTraces": 1
  }
}
```

### ReportState

Reports the client's actual state after executing an action. The mirror compares it against the expected state from the ITF trace.

| Field | Tag |
|-------|-----|
| `proto_step` | `"report_state"` |
| `state` | `object` — map of variable name → value (see [Value Encoding](#value-encoding)) |

**Example:**
```json
{
  "proto_step": "report_state",
  "state": {
    "hr": { "#bigint": "5" },
    "ticked": true,
    "action_taken": "advance"
  }
}
```

## Mirror → Client Messages

The mirror sends these message types in response.

### SpecValidated

Sent after `Register`. Reports whether the spec passed apalache typecheck + model check.

| Field | Tag |
|-------|-----|
| `proto_step` | `"spec_validated"` |
| `result` | `"valid"` (string) or `{"invalid": "<error text>"}` (object) |

**Success:**
```json
{ "proto_step": "spec_validated", "result": "valid" }
```

**Failure:**
```json
{ "proto_step": "spec_validated", "result": { "invalid": "Type checking error: ..." } }
```

### InitialState

Sent after successful validation. Contains the action name the client should execute to reach the initial state. The mirror keeps the expected state and compares it against the client's `ReportState` response.

| Field | Tag |
|-------|-----|
| `proto_step` | `"initial_state"` |
| `action` | `string` — the action name to execute |

**Example:**
```json
{
  "proto_step": "initial_state",
  "action": "Init"
}
```

### NextStep

The next action in the trace sequence. The client should execute the `action` and report the resulting state via `ReportState`.

| Field | Tag |
|-------|-----|
| `proto_step` | `"next_step"` |
| `action` | `string` — the action name to execute |

**Example:**
```json
{
  "proto_step": "next_step",
  "action": "Advance"
}
```

### StepOk

Sent in response to `ReportState`. The client's reported state matches the expected state. The client should wait for the next `NextStep` message.

```json
{ "proto_step": "step_ok" }
```

### StepMismatch

Sent in response to `ReportState`. The client's state differs from the expected state. The trace replay stops at this point.

| Field | Tag |
|-------|-----|
| `proto_step` | `"step_mismatch"` |
| `expected` | `object` — the state expected by the trace |
| `actual` | `object` — the state reported by the client |

**Example:**
```json
{
  "proto_step": "step_mismatch",
  "expected": { "hr": { "#bigint": "5" } },
  "actual": { "hr": { "#bigint": "3" } }
}
```

### AllStepsDone

Sent when all steps in the trace have been successfully replayed. The implementation is correct with respect to this trace.

```json
{ "proto_step": "all_steps_done" }
```

### ProtocolError

Sent when an invalid message or unexpected protocol state is encountered.

| Field | Tag |
|-------|-----|
| `proto_step` | `"protocol_error"` |
| `error` | `string` — human-readable error description |

## Value Encoding

State maps carry typed values. The JSON encoding distinguishes TLA+ types:

| TLA+ type | JSON |
|-----------|------|
| `Int` | `{"#bigint": "42"}` — integer as a string inside `#bigint` object. Negative: `{"#bigint": "-5"}`. Zero is `{"#bigint": "0"}` (not `""`). |
| `Bool` | JSON boolean: `true` / `false` |
| `Str` | JSON string: `"hello"` |
| `Set(...)` | JSON array: `[{"#bigint": "1"}, {"#bigint": "2"}]` |
| `<<a, b>>` (tuple) | `{"#tup": [{"#bigint": "1"}, true]}` |
| `[k1 \|-> v1, ...]` (record/function) | JSON object: `{"k1": ..., "k2": ...}` |
| Null/missing | `null` or `{"#bigint": ""}` |

**Note:** Integers use the `{"#bigint": "<digits>"}` wrapper to avoid JavaScript/JSON number precision loss. Client implementations must parse these as arbitrary-precision integers.

## Protocol State Machine

```
                      ┌─────────┐
                      │  Idle   │
                      └────┬────┘
                           │ Register
                           ▼
                    ┌─────────────┐
                    │  Validating  │
                    └──────┬──────┘
                           │ SpecValidated (if valid)
                           ▼
                      ┌────────┐
                      │ Ready  │◄───────────┐
                      └───┬────┘            │
                          │ InitialState    │ StepOk
                          ▼                 │
                    ┌──────────┐     ┌──────┴─────┐
                    │ Stepping │────►│   client   │
                    └──────────┘     │ ReportState│
                                     └────────────┘
                          │
                          │ AllStepsDone / StepMismatch
                          ▼
                      ┌────────┐
                      │  Done  │
                      └────────┘
```

1. **Idle** — session start. Client sends `Register`.
2. **Validating** — mirror runs apalache typecheck + model check. Sends `SpecValidated`.
3. **Ready** — mirror sends `InitialState` (first trace state).
4. **Stepping** — for each step:
   - Mirror sends `InitialState` (step 0) or `NextStep` (step 1+) with the action name.
   - Client executes the action, then sends `ReportState` with its actual state.
   - Mirror compares against the expected state from the trace and replies with `StepOk` (continue) or `StepMismatch` (stop).
5. **Done** — mirror sends `AllStepsDone` on success, or reaches `Done` after `StepMismatch`.

Any invalid message or state violation produces `ProtocolError` and terminates the session.

## Transport Detail

The current transport (`StdioTransport`) works as follows:

- **Send**: write the JSON-encoded message as a single line (no embedded newlines), followed by a newline (`\n`), then flush stdout.
- **Receive**: read one line from stdin, decode as JSON.

Client implementations must avoid emitting newlines inside JSON values. Use standard JSON escaping (`\n` → `\\n`).
