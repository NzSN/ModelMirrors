# Mirror Protocol Specification

This document defines the protocol for communicating with a ModelMirrors mirror process. Client implementations in any language must follow this spec to interact correctly.

## Transport

The mirror process communicates over **stdio** (stdin/stdout) by default, or over **TCP** (`--serve <port>`) or **mutually-authenticated TLS 1.3 over TCP** (`--server <port> --tls ...`). Messages are **newline-delimited JSON**: one JSON object per line, encoded as UTF-8. The message format is identical on all transports; TLS affects only connection establishment (mutual certificate authentication), never the session protocol.

## Discovery and mTLS (Client Guide)

This section is the complete procedure for a client **in any language** to locate a mirror via the service registry and connect to it securely. It assumes the server was started as:

```
ModelMirrors --server <port> --tls --cert <server.crt> --key <server.key> \
    --ca <ca.crt> --registry <registry-url>
```

You need, provisioned out-of-band: the CA certificate (`ca.crt`) and a client certificate + private key signed by that CA (see `scripts/gen-certs.sh`).

### Step 1 — Discover

Query the Consul-compatible registry over plain HTTP:

```
GET <registry-url>/v1/health/service/modelmirrors?passing=true
```

The response is a JSON array; only the `Service` object of each entry matters:

```json
[
  {
    "Service": {
      "ID": "modelmirrors-host1-8999",
      "Address": "10.0.0.5",
      "Port": 8999,
      "Meta": { "cert-sha256": "<64 lowercase hex chars>" }
    }
  }
]
```

Rules:

- Only entries returned with `passing=true` are healthy; do not filter further.
- Skip entries with an empty or missing `Address`, or a missing/zero `Port`.
- `Meta["cert-sha256"]` may be absent; treat it as optional (step 3 becomes a no-op).
- Any registry error (unreachable, non-200, malformed JSON) means "no servers" — fail closed or fall back to a directly configured `host:port`.

### Step 2 — TLS handshake

Open a TCP connection to a chosen `Address:Port` and perform a TLS handshake with:

- **TLS 1.3 only** — the server accepts no other version.
- **Server authentication**: verify the server certificate chain against the pinned `ca.crt`, and verify the hostname/IP in the certificate SAN (standard library behavior when a CA store and server name are supplied).
- **Client authentication**: present your client certificate and key when the server requests them (it always does). A server signed by a *different* CA, or a missing client certificate, fails the handshake — retry with the next registry entry.

### Step 3 — Fingerprint pinning (defense in depth)

If the registry entry contained `Meta["cert-sha256"]`:

1. Take the peer's **leaf certificate** (the first certificate in the chain presented by the server), in its raw **DER** encoding.
2. Compute **SHA-256** over the DER bytes, rendered as **lowercase hex** (64 characters).
3. Compare with the registry value. On mismatch, close the connection and try the next entry.

This step is defense in depth: the mTLS handshake in step 2 already authenticates the server, so a forged registry entry cannot cause impersonation — at worst it causes failed connections.

### Step 4 — Session

Speak the session protocol exactly as on stdio/TCP: newline-delimited JSON, and the **first message must be a `Register*` message** (`register`, `register_traces`, `register_trace_gen`, `register_explore`, or `register_explore_session`). Any other first message receives a `protocol_error` and the connection is closed. There is no greeting, banner, or version exchange — the registry and the TLS handshake carry all setup information.

### Pseudocode

```
entries = http_get(registry + "/v1/health/service/modelmirrors?passing=true")
for entry in entries:
    svc = entry.Service
    if !svc.Address or !svc.Port: continue
    try:
        conn = tls13_connect(svc.Address, svc.Port,
                             ca=ca_crt, cert=client_crt, key=client_key)
        if svc.Meta["cert-sha256"]:
            assert sha256_hex(peer_leaf_cert_der(conn)) == svc.Meta["cert-sha256"]
        return conn            # ready for step 4
    catch:
        continue               # try next entry
fail "no usable mirror"
```

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

The full client and mirror phase machines (from `specs/MirrorProtocol.tla`) are diagrammed in [`mirror-protocol-state-machine.svg`](mirror-protocol-state-machine.svg) ([Graphviz source](mirror-protocol-state-machine.dot)).

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
