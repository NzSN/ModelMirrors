# Interactive Symbolic Testing with Apalache

## Overview

Apalache's JSON-RPC explorer server lets external tools drive symbolic execution
of TLA+ specifications step-by-step. This enables **interactive symbolic testing**:
a feedback loop where the SMT solver picks actions from the spec, the harness
concretizes them against a real implementation, and the implementation's responses
feed back into the next solver step.

```
loadSpec → assumeTransition(Init) → nextStep → checkInvariant →
  [not violated]  assumeTransition(Action) → nextStep → checkInvariant →
  [violated]      get ITF counterexample → report divergence
  [else]          query state values → concretize & drive SUT → loop
```

## Starting the Server

```bash
apalache-mc server --port=8822 --server-type=explorer
```

Or with Docker:

```bash
docker run --rm -p 8822:8822 ghcr.io/apalache-mc/apalache:latest \
  server --server-type=explorer
```

The server listens on `http://localhost:8822/rpc` and speaks
[JSON-RPC 2.0](https://www.jsonrpc.org/specification).

**Health check:**

```bash
curl -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"health","params":{},"id":1}'
```

## API Reference

### Sessions and Snapshots

Every `loadSpec` call creates a **session** identified by `sessionId`.
All exploration methods are scoped to a session.

The server uses **snapshots** for checkpoint/rollback. Every mutating call
returns a `snapshotId`. Call `rollback` to return to an earlier snapshot,
undoing all constraints added since.

### Methods

| Method | Mutates | Purpose |
|--------|---------|---------|
| `health` | No | Server liveness check |
| `loadSpec` | Yes | Load TLA+ spec, create session |
| `disposeSpec` | Yes | Free session resources |
| `assumeTransition` | Yes* | Add transition constraints to solver |
| `nextStep` | Yes | Advance to next symbolic state |
| `checkInvariant` | No** | Check invariant against current state |
| `query` | No** | Extract trace / state / operator value |
| `nextModel` | Yes | Enumerate alternative models |
| `rollback` | Yes | Restore earlier snapshot |
| `assumeState` | Yes | Constrain state variables to concrete values |
| `compact` | Yes | Replace long trace with single concrete state |
| `applyInOrder` | Varies | Batch multiple calls in one HTTP round-trip |

\* Rolled back automatically if status is `DISABLED`.
\** Temporarily modifies context, then rolls back.

---

### `loadSpec` — Load a specification

Sources are **base64-encoded** TLA+ modules, not file paths.
The first source must be the root module.

```json
{
  "method": "loadSpec",
  "params": {
    "sources": ["<base64-root-module>", "<base64-imported-module>"],
    "init": "Init",
    "next": "Next",
    "invariants": ["TypeOK", "SafetyProp"],
    "exports": ["View"]
  }
}
```

**Response:**

```json
{
  "result": {
    "sessionId": "1",
    "snapshotId": 0,
    "specParameters": {
      "initTransitions": [{"index": 0, "labels": ["I"]}],
      "nextTransitions": [{"index": 0, "labels": ["A"]}, {"index": 1, "labels": ["B"]}],
      "stateInvariants": [{"index": 0, "labels": ["Inv"]}],
      "actionInvariants": []
    }
  }
}
```

The `specParameters` tell you how many transitions, invariants, and labels
are available. Use these indices in subsequent calls.

**Spec requirements:**
- Module must start with `---- MODULE Name ----` and end with `====`
- Operators referenced by `invariants` and `exports` must be defined in the spec
- Operators listed in `exports` are preserved (unused definitions are pruned)
- The optional `init`/`next` params override the default predicate names

---

### `assumeTransition` — Assume a transition

Adds the transition's constraints to the SMT context.
If `checkEnabled` is `true`, the solver checks whether the transition
is feasible given the current symbolic path.

```json
{
  "method": "assumeTransition",
  "params": {
    "sessionId": "1",
    "transitionId": 0,
    "checkEnabled": true,
    "timeoutSec": 10
  }
}
```

**Response:**

```json
{
  "result": {
    "sessionId": "1",
    "snapshotId": 2,
    "transitionId": 0,
    "status": "ENABLED"
  }
}
```

`status` values:
- `ENABLED` — transition is feasible; context modified
- `DISABLED` — transition infeasible; context automatically rolled back
- `UNKNOWN` — solver timed out; context modified (proceed at your own risk)

For `Init` (at step 0), use `transitionId` from `initTransitions`.
After `nextStep`, use `transitionId` from `nextTransitions`.

---

### `nextStep` — Advance state

Renames primed variables (`x'`) to unprimed (`x`), making the current
frame the new "previous" state. Does not add new constraints.

```json
{
  "method": "nextStep",
  "params": {"sessionId": "1"}
}
```

**Response:**

```json
{
  "result": {
    "sessionId": "1",
    "snapshotId": 3,
    "newStepNo": 1
  }
}
```

Must be called after a successful `assumeTransition` (status `ENABLED` or `UNKNOWN`).

---

### `checkInvariant` — Check an invariant

Checks whether the invariant can be violated by a concrete execution
along the current symbolic path. Returns a counterexample trace in
[ITF format](https://apalache-mc.org/docs/adr/015adr-trace.html) on violation.

```json
{
  "method": "checkInvariant",
  "params": {
    "sessionId": "1",
    "invariantId": 0,
    "kind": "STATE",
    "timeoutSec": 10
  }
}
```

**Response (satisfied):**

```json
{
  "result": {
    "sessionId": "1",
    "invariantStatus": "SATISFIED",
    "trace": null
  }
}
```

**Response (violated):**

```json
{
  "result": {
    "sessionId": "1",
    "invariantStatus": "VIOLATED",
    "trace": {
      "#meta": {"format": "ITF", "varTypes": {"x": "Int"}},
      "vars": ["x"],
      "states": [
        {"#meta": {"index": 0}, "x": {"#bigint": "0"}},
        {"#meta": {"index": 1}, "x": {"#bigint": "10"}}
      ]
    }
  }
}
```

Timing: check state invariants after `nextStep`; check action invariants
between `assumeTransition` and `nextStep`.

---

### `query` — Query the current context

Extract values from a model of the current SMT context.

```json
{
  "method": "query",
  "params": {
    "sessionId": "1",
    "kinds": ["TRACE", "STATE", "OPERATOR"],
    "operator": "View",
    "timeoutSec": 10
  }
}
```

**Kinds:**
- `"TRACE"` — Full concrete trace (ITF envelope)
- `"STATE"` — Last state only (single ITF state object)
- `"OPERATOR"` — Value of a nullary operator (must be in `exports`)

**Response:**

```json
{
  "result": {
    "sessionId": "1",
    "trace": { ... },
    "state": { "x": {"#bigint": "5"} },
    "operatorValue": {"#tup": [false, true, false]}
  }
}
```

The solver may return different models on successive calls (seeds are fixed
by default for determinism; see [SMT randomization](https://apalache-mc.org/docs/apalache/tuning.html#randomization)).

---

### `rollback` — Undo to a snapshot

Restores the context to an earlier snapshot. All snapshots with higher
IDs are discarded.

```json
{
  "method": "rollback",
  "params": {
    "sessionId": "1",
    "snapshotId": 0
  }
}
```

Useful for backtracking: explore one branch, roll back, explore another.

---

### `nextModel` — Enumerate alternative models

Finds a model with a different `operator` value than the current one.
The `operator` must be exported in `loadSpec`.

```json
{
  "method": "nextModel",
  "params": {
    "sessionId": "1",
    "operator": "View",
    "timeoutSec": 10
  }
}
```

On success (`hasNext: "TRUE"`), call `query` to extract the new model.
To prevent the exclusion constraint from leaking, `rollback` after enumeration.

---

### `assumeState` — Constrain to concrete values

Adds equality constraints `var == value` to the current state.

```json
{
  "method": "assumeState",
  "params": {
    "sessionId": "1",
    "checkEnabled": true,
    "equalities": {
      "x": {"#bigint": "42"},
      "y": {"#bigint": "0"}
    }
  }
}
```

Values use ITF encoding (e.g. `{"#bigint": "42"}` for integers).
This is how the test harness feeds implementation observations back into
the symbolic context.

---

### `compact` — Reset solver complexity

After 200-300 symbolic steps the accumulated constraints slow the solver.
`compact` extracts a concrete last state, rolls back to `snapshotId`,
and asserts that state as equalities — resetting the solver without
losing state.

```json
{
  "method": "compact",
  "params": {
    "sessionId": "1",
    "snapshotId": 0,
    "timeoutSec": 10
  }
}
```

---

### `applyInOrder` — Batch calls

Execute multiple exploration steps sequentially under one session lock.

```json
{
  "method": "applyInOrder",
  "params": {
    "sessionId": "1",
    "calls": [
      {"method": "assumeTransition", "params": {"transitionId": 0, "checkEnabled": true}},
      {"method": "nextStep", "params": {}},
      {"method": "query", "params": {"kinds": ["STATE"]}}
    ]
  }
}
```

Execution stops at the first failing step. Reduces HTTP round-trips for
tight exploration loops.

## Walkthrough: Counter Spec

Minimal spec (`/tmp/Counter.tla`):

```tla
---- MODULE Counter ----
EXTENDS Integers
VARIABLE
  \* @type: Int;
  count
Init == count = 0
TICK(S) ==
  S \in {2, 3} /\
  count' = count + S
Next == \E S \in {2, 3}: TICK(S)
TraceComplete == count < 12
View == count
================
```

### 1. Start server

```bash
apalache-mc server --port=8822 --server-type=explorer &
sleep 4
```

### 2. Load spec

```bash
B64=$(base64 -w0 /tmp/Counter.tla)
curl -s -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","method":"loadSpec",
    "params":{
      "sources":["'"$B64"'"],
      "invariants":["TraceComplete"],
      "exports":["View"]
    },
    "id":1
  }'
```

Response: `sessionId: "1"`, 1 init transition (index 0), 1 next transition (index 0).

### 3. Init state

```bash
# Assume Init (transition 0 from initTransitions)
curl -s -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"assumeTransition","params":{"sessionId":"1","transitionId":0,"checkEnabled":true},"id":2}'
# → "status":"ENABLED"

# Advance
curl -s -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"nextStep","params":{"sessionId":"1"},"id":3}'
# → "newStepNo":1

# Check invariant (count=0 < 12 → satisfied)
curl -s -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"checkInvariant","params":{"sessionId":"1","invariantId":0},"id":4}'
# → "invariantStatus":"SATISFIED"
```

### 4. Interactive tick loop

Repeat for each symbolic step:

```bash
# Assume Next (transition 0 from nextTransitions)
curl ... -d '{"method":"assumeTransition","params":{"sessionId":"1","transitionId":0,...}}'
# → ENABLED (solver picks stride 2 or 3)

# Advance
curl ... -d '{"method":"nextStep","params":{"sessionId":"1"}}'

# Check invariant
curl ... -d '{"method":"checkInvariant","params":{"sessionId":"1","invariantId":0}}'
```

After 4 ticks the solver finds `count=12`, invariant violated:

```json
{
  "invariantStatus": "VIOLATED",
  "trace": {
    "states": [
      {"#meta":{"index":0}, "count":{"#bigint":"0"}},
      {"#meta":{"index":1}, "count":{"#bigint":"3"}},
      {"#meta":{"index":2}, "count":{"#bigint":"6"}},
      {"#meta":{"index":3}, "count":{"#bigint":"9"}},
      {"#meta":{"index":4}, "count":{"#bigint":"12"}}
    ]
  }
}
```

The solver consistently chose stride=3 — the larger value leads to violation faster.

### 5. Query the view at any step

```bash
curl -s -X POST http://localhost:8822/rpc \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"query","params":{"sessionId":"1","kinds":["OPERATOR"],"operator":"View"},"id":10}'
# → "operatorValue":{"#bigint":"6"}
```

## CONSTANTS and CInit

The JSON-RPC API **does not support** `CInit` — there is no `cinit` parameter
in `loadSpec`. Specs using `CONSTANTS` will fail with:

```
SubstRule: Variable <NAME> is not assigned a value
```

**Workaround:** Inline constant initialization into `Init`:

```tla
-- Before (fails):
CONSTANTS STRIDES
Init == count = 0
CInit == STRIDES = {2, 3}

-- After (works):
Init == count = 0 /\ STRIDES = {2, 3}
```

## Python Helpers

Two libraries simplify working with the API:

- **[apalache-rpc-client](https://github.com/konnov/apalache-rpc-client/)** —
  Python client for the JSON-RPC server. Handles session management,
  base64 encoding, and method dispatch.

- **[itf-py](https://github.com/konnov/itf-py/)** —
  Serialize/deserialize ITF traces and expressions. Used to parse
  counterexample traces and construct query values.

Example:

```python
from apalache_rpc_client import ApalacheClient
from itf import ITFTrace

client = ApalacheClient("http://localhost:8822/rpc")

# Load spec
session = client.load_spec(
    sources=["/path/to/spec.tla"],
    invariants=["TypeOK"],
    exports=["View"],
)

# Init
client.assume_transition(session, transition_id=0)
client.next_step(session)

# Tick loop
for i in range(10):
    result = client.assume_transition(session, transition_id=0)
    if result["status"] != "ENABLED":
        break
    client.next_step(session)
    inv = client.check_invariant(session, invariant_id=0)
    if inv["invariantStatus"] == "VIOLATED":
        trace = ITFTrace.from_dict(inv["trace"])
        print(f"Violated at step {i}: {trace.states[-1]}")
        break

client.dispose_spec(session)
```

## Architecture for Testing Harnesses

```
┌─────────────────────────────────────────┐
│ harness.py                              │
│                                         │
│  loop:                                  │
│    result = assumeTransition(spec)      │
│    if DISABLED: rollback, try other     │
│    nextStep()                           │
│    state = query(kinds=["STATE"])       │
│    action = concretize(state)    ◄──────┼── spec → real values
│    response = execute(sut, action)      │
│    assumeState(response)         ◄──────┼── real → spec constraints
│    checkInvariant()                     │
│    if VIOLATED: report divergence       │
│                                         │
│  External:                              │
│    Apalache server (localhost:8822)     │
│    System under test (Docker container) │
└─────────────────────────────────────────┘
```

## References

- [Apalache JSON-RPC README](https://github.com/apalache-mc/apalache/tree/main/json-rpc)
- [ITF Trace Format](https://apalache-mc.org/docs/adr/015adr-trace.html)
- [Interactive Symbolic Testing of TFTP](https://protocols-made-fun.com/tlaplus/2025/12/15/tftp-symbolic-testing.html) — blog post by Igor Konnov
- [McMillan & Zuck (2019)](https://www.mcmil.net/pubs/SIGCOMM19.pdf) — original paper on specification-based testing with SMT
