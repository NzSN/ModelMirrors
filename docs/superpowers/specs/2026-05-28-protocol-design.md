# Protocol Design

## Summary

Define the IPC protocol messages and state machine for ModelMirrors. The protocol is
language-independent — clients in any language can implement it over any transport.
This module captures the message types and valid protocol flow, with no assumption
about serialization format, IPC mechanism, or transport.

## Messages

### Client → Mirror

| Message | Fields | Purpose |
|---------|--------|---------|
| `Register` | `FilePath`, `TraceGenerationConfig` | Register a TLA+ spec and trace generation config |
| `ReportState` | `Map Text Value` | Report client state after executing a step |

### Mirror → Client

| Message | Fields | Purpose |
|---------|--------|---------|
| `SpecValidated` | `ValidateResult` | Result of spec validation (valid or invalid+error) |
| `InitialState` | `Map Text Value` | Initial state from ITF trace |
| `NextStep` | `Map Text Value` | Next expected state in the trace |
| `StepOk` | — | Client state matched expected state for this step |
| `StepMismatch` | `Map Text Value`, `Map Text Value` | Mismatch (expected, actual) |
| `AllStepsDone` | — | Trace replay completed successfully |
| `ProtocolError` | `Text` | Protocol-level error |

## State Machine

```
Idle ──(Register)──→ Validating
Validating ──(SpecValidated valid)──→ Ready
Validating ──(SpecValidated invalid)──→ Done
Ready ──(InitialState + NextStep)──→ Stepping
Stepping ──(ReportState + StepOk)──→ Stepping  (more steps)
                                    └→ Done      (last step)
Stepping ──(ReportState + StepMismatch)──→ Done
* ──(ProtocolError)──→ Done
```

All other transitions are protocol violations.

## Modules

### `Protocol` (`src/Protocol.hs`)

- Pure message types and state machine
- Uses existing types from `Apalache.Types` (`ValidateResult`, `TraceGenerationConfig`, `Value`)
- No serialization instances, no IO, no process handling

### `Protocol.Json` (`src/Protocol/Json.hs`)

- JSON codec via `aeson` (`ToJSON`/`FromJSON` instances) for all protocol messages
- `Value` and `ItfTrace` already have JSON instances; minimal new code needed
- Wire protocol: each JSON message includes a `"tag"` field for message type discrimination

### JSON Wire Format

```
{"tag": "register",           "specPath": "...", "traceConfig": {...}}
{"tag": "report_state",       "state": {...}}
{"tag": "spec_validated",     "result": "valid" | {"invalid": "error"}}
{"tag": "initial_state",      "state": {...}}
{"tag": "next_step",          "state": {...}}
{"tag": "step_ok"}
{"tag": "step_mismatch",      "expected": {...}, "actual": {...}}
{"tag": "all_steps_done"}
{"tag": "protocol_error",     "error": "..."}
```

Both modules added to `exposed-modules` in `ModelMirros.cabal`.
