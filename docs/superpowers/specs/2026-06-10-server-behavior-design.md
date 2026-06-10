# ServerBehavior Design

## Purpose

`Apalache.Rpc.ServerBehavior` replays an ITF trace against a live apalache
JSON-RPC explorer server, observing both RPC-level outcomes and server state
at each step. The ITF trace is generated from the `ApalacheRPCClient` TLA+
spec, which models the observable behavior of the Haskell RPC client and the
explorer server. Replaying the trace verifies that the Haskell implementation
is consistent with the specification.

## Interface

### Types

```haskell
data ServerStep = ServerStep
  { ssMethod    :: !Text              -- RPC method called (from trace: clLastMethod)
  , ssExpState  :: !(Map Text Value)  -- expected server state (from trace)
  , ssObsState  :: !(Map Text Value)  -- observed server state (from live query)
  , ssResult    :: !Text              -- observed RPC result: "ok" | "http_error"
                                      --   | "protocol_error" | "parse_error"
  }
```

### Function

```haskell
replayTrace :: ApalacheSpec -> ItfTrace -> IO (Either RpcError [ServerStep])
```

- `Left RpcError` only for fatal setup errors (server could not start, spec
  could not load). Per-step errors are captured in `ssResult`.
- Returns steps in trace order. The initial step (where `clLastMethod = "none"`)
  is skipped.

## Algorithm

1. Fork apalache server on port 8822 via `withApalacheServer`
2. Create explorer with `newExplorer`
3. Iterate through `traceStates`, skipping any where `clLastMethod = "none"`:
   a. Read `clLastMethod` from the expected state to determine which RPC
      operation to call
   b. Execute the corresponding RPC call via the existing `Apalache.Rpc.Client`
      or `Apalache.Explorer` functions
   c. Classify the RPC result: success -> `"ok"`, `RpcHttpError` ->
      `"http_error"`, `RpcProtocolError` -> `"protocol_error"`,
      `RpcParseError` -> `"parse_error"`
   d. Call `exploreQueryState` to get the actual live server state snapshot
   e. Record the `ServerStep`
4. Return all steps

### Trace action to RPC call mapping

| `clLastMethod`        | Haskell call                             |
|-----------------------|------------------------------------------|
| `"health"`            | `health`                                 |
| `"loadSpec"`          | `loadSpec` (done via `newExplorer`)      |
| `"assumeTransition"`  | `assumeTransition` + `nextStep`          |
| `"nextStep"`          | `nextStep`                               |
| `"checkInvariant"`    | `checkInvariant`                         |
| `"query"`             | `query` (state query)                    |
| `"assumeState"`       | `assumeState`                            |
| `"rollback"`          | `rollback`                               |
| `"disposeSpec"`       | `disposeSpec`                            |
| `"none"` (init)       | Skip (initialization step, no call)      |

### Result classification

| Haskell outcome              | `ssResult` value   |
|------------------------------|--------------------|
| `Right _`                    | `"ok"`             |
| `Left (RpcHttpError _)`      | `"http_error"`     |
| `Left (RpcProtocolError _ _)`| `"protocol_error"` |
| `Left (RpcParseError _)`     | `"parse_error"`    |

## Dependencies

- **New:** None. All types are from existing modules.
- **Existing:** `Apalache.Explorer`, `Apalache.Rpc.Types`, `Apalache.Rpc.Client`,
  `Apalache.Types`, `Data.Map.Strict`, `Data.Text`.

## Files Changed

| File                                        | Change                                      |
|---------------------------------------------|---------------------------------------------|
| `src/Apalache/Rpc/ServerBehavior.hs`        | Write implementation                        |
| `src/Apalache/Core.hs`                      | Import and re-export `ServerBehavior`       |
| `ModelMirrors.cabal`                        | Add `Apalache.Rpc.ServerBehavior` to exposed-modules |

## Testing

Add an integration test (`Apalache.ServerBehaviorSpec`) that:

1. Generates an ITF trace from `ApalacheRPCClient.tla` using
   `Apalache.Command.generateTraces`
2. Loads `AapalacheRPCProtocol.tla` into the explorer (the base spec)
3. Replays trace steps via `replayTrace`
4. For each step, asserts that the observed RPC result matches the expected
   result from the trace

Requires `apalache-mc` on PATH (same as existing integration tests).
