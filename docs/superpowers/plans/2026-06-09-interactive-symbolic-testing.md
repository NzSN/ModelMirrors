# Interactive Symbolic Testing — Remaining Implementation

**Date:** 2026-06-09
**Branch:** `interactive`
**Ref:** `docs/apalache/interactive.md`

## Completed

| Component | Status |
|-----------|--------|
| `Apalache.Rpc.Types` — JSON-RPC 2.0 protocol types, aeson instances | Done |
| `Apalache.Rpc.Client` — HTTP client, typed method dispatch | Done |
| `Apalache.Explorer` — server lifecycle, high-level exploration API | Done |
| `Apalache.Core` re-exports + `.cabal` deps (`base64-bytestring`, `http-client`, `http-types`) | Done |
| Bazel BUILD/MODULE compatibility | Done |
| `docs/apalache/interactive.md` — reference documentation for the JSON-RPC API | Done |
| Existing 43 tests pass (cabal); 40/43 pass (Bazel) | Done |

## Remaining

### 1. Tests for new modules

**`test/Apalache/ExplorerSpec.hs`** — integration tests requiring a running `apalache-mc server`.

**Rpc.Types roundtrip tests:**
- `LoadSpecParams` / `LoadSpecResult` encode → decode
- `AssumeTransitionParams` / `AssumeTransitionResult` with `TransitionStatus` enum
- `NextStateParams` / `NextStateResult`
- `CheckInvariantParams` / `CheckInvariantResult` with `InvariantStatus` enum
- `QueryParams` / `QueryResult` with `QueryKind` enum
- `AssumeStateParams` / `AssumeStateResult`
- Edge: malformed JSON, missing fields, unexpected status strings

**Rpc.Client tests:**
- `newRpcClient` + `health` — verify server responds OK
- `loadSpec` (minimal spec: `Counter.tla` or inline TLA+) → get session ID + `SpecParams`
- `disposeSpec` — free session, verify subsequent calls return error
- `assumeTransition` → `nextStep` → `checkInvariant` cycle
- Error handling: invalid method returns `RpcProtocolError`, bad JSON returns `RpcParseError`

**Explorer tests:**
- `startApalacheServer` / `stopApalacheServer` lifecycle (process starts, health check passes, process terminates)
- `withApalacheServer` bracket — server stops even on exception
- `newExplorer` — loads spec, returns `Explorer` with correct `SpecParams`
- `exploreInit` — assumes Init, advances to step 1
- `exploreNext` + `exploreCheck` loop → invariant violated, counterexample trace returned
- `exploreQueryState` — returns `Map Text Value` (ITF-encoded)
- `exploreQueryOperator` — returns operator value (e.g., `View`)
- `exploreAssumeState` — constrains a variable, returns ENABLED
- `exploreRollback` — takes N steps, rollback to snapshot 0, verify step 0 state
- `exploreUntilViolation` — convenience loop, returns step count + counterexample

Wire into `test/Main.hs`:

```haskell
import qualified ExplorerSpec
spec = testGroup "ModelMirrors" [..., ExplorerSpec.spec]
```

### 2. Protocol integration — `MkExploreMirror`

**`src/Protocol/Mirror.hs`** — new step variant for interactive exploration.

**New data type:**

```haskell
data MkExploreMirror t = MkExploreMirror
  { mexTransport :: t
  , mexSpec      :: ApalacheSpec
  , mexInvariants :: [Text]
  , mexExports    :: [Text]
  }
```

**New `Step` instance:**

```haskell
instance Transport t => Step (MkExploreMirror t) where
  exec m = do
    server <- liftIO $ startApalacheServer Nothing
    result <- liftIO $ exploreMirror server m
    liftIO $ stopApalacheServer server
    case result of
      Left err -> pure [MirrorSendProtocolError (showRpcError err)]
      Right steps -> pure steps
```

**Core interactive loop (`exploreMirror`):**

```haskell
exploreMirror :: Transport t => ApalacheServer -> MkExploreMirror t -> IO (Either RpcError [MirrorStep])
exploreMirror server m = do
  let transport = mexTransport m
  expl <- newExplorer server (mexSpec m) (mexInvariants m) (mexExports m)
  case expl of
    Left err -> pure (Left err)
    Right e -> do
      e1 <- exploreInit e
      case e1 of
        Left err -> pure (Left err)
        Right e2 -> do
          -- check initial state invariant
          ci <- exploreCheck e2 0 StateInvariant
          case ci of
            Right (InvViolated, _) ->
              pure (Right [MirrorSendSpecValidatedValid, MirrorSendStepMismatch 0 (StateMismatch mempty mempty [])])
            _ -> do
              sendMsg transport (SpecValidated SpecValid)
              loop transport e2 1 []
```

```haskell
loop :: Transport t => t -> Explorer -> Int -> [MirrorStep] -> IO (Either RpcError [MirrorStep])
loop transport expl stepIdx acc = do
  nextResult <- exploreNext expl 0
  case nextResult of
    Left err -> pure (Left err)
    Right (e', TransDisabled) -> do
      sendMsg transport AllStepsDone
      pure (Right (reverse (MirrorSendAllStepsDone : acc)))
    Right (e', _) -> do
      stateResult <- exploreQueryState e'
      case stateResult of
        Left err -> pure (Left err)
        Right expected -> do
          let action = T.pack "explore"
          sendMsg transport (InitialState action expected)
          resp <- recvMsg transport
          case resp of
            Right (ReportState actual) -> do
              let diff = diffState expected actual
              assumeResult <- exploreAssumeState e' actual
              case (diff, assumeResult) of
                (StatesMatch, Right (e'', _)) -> do
                  sendMsg transport StepOk
                  ci <- exploreCheck e'' 0 StateInvariant
                  case ci of
                    Right (InvViolated, _) ->
                      pure (Right (reverse (MirrorSendStepMismatch stepIdx diff
                        : MirrorRecvReportState stepIdx action
                        : MirrorSendInitialState action expected : acc)))
                    _ -> loop transport e'' (stepIdx + 1)
                      (MirrorSendStepOk stepIdx
                        : MirrorRecvReportState stepIdx action
                        : MirrorSendInitialState action expected : acc)
                (StateMismatch{}, _) -> do
                  sendMsg transport (StepMismatch (Map.empty) (Map.empty))
                  pure (Right (reverse (MirrorSendStepMismatch stepIdx diff
                    : MirrorRecvReportState stepIdx action
                    : MirrorSendInitialState action expected : acc)))
                _ -> pure (Left (RpcProtocolError 0 "assumeState failed"))
            _ -> pure (Left (RpcProtocolError 0 "expected ReportState"))
```

### 3. New client message + MirrorStep

**`src/Protocol/Core.hs`:**

```haskell
data ClientMessage
  = Register !ApalacheConfig !TraceGenerationConfig
  | RegisterTraces !ApalacheConfig ![FilePath]
  | RegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath)
  | RegisterExplore !ApalacheSpec ![Text] ![Text]   -- spec, invariants, exports
  | ReportState !(Map Text Value)
```

**`src/Protocol/Format/Json.hs`:** aeson instance with `proto_step = "register_explore"`.

**`src/Protocol/Mirror.hs`:** add variant to `MirrorStep`:

```haskell
data MirrorStep
  = ...
  | MirrorRecvRegisterExplore !ApalacheSpec ![Text] ![Text]
  | ...
```

### 4. `run` routing

In the `run` function, add a case for `RegisterExplore`:

```haskell
run transport = StepPending $ do
  msg <- recvMsg transport
  case msg of
    Right (RegisterExplore spec invs exports) -> do
      steps <- exec (MkExploreMirror transport spec invs exports)
      pure (MirrorRecvRegisterExplore spec invs exports, steps)
    -- existing cases unchanged
    ...
```

### 5. Files summary

| File | Action | Lines (est) |
|------|--------|-------------|
| `test/Apalache/ExplorerSpec.hs` | **NEW** | ~200 |
| `test/Main.hs` | MODIFY | +2 |
| `src/Protocol/Core.hs` | MODIFY | +1 |
| `src/Protocol/Format/Json.hs` | MODIFY | +20 |
| `src/Protocol/Mirror.hs` | MODIFY | +100 |
| `test/BUILD.bazel` | MODIFY | +1 |

No new dependencies. No new Bazel packages.

### 6. Effort estimate

| Task | Est. |
|------|------|
| ExplorerSpec — pure test `Rpc.Types` roundtrips | 30 min |
| ExplorerSpec — `Rpc.Client` tests | 30 min |
| ExplorerSpec — `Explorer` integration tests | 1 hr |
| `MkExploreMirror` + `exploreMirror` loop | 1 hr |
| `RegisterExplore` message + JSON instance | 30 min |
| `run` routing + `MirrorStep` variant | 15 min |
| Bazel BUILD update | 15 min |
| **Total** | **~4 hr** |

### 7. Edge cases

| Scenario | Handling |
|----------|----------|
| Server fails to start (port in use, binary not found) | `startApalacheServer` returns error; `MkExploreMirror` surfaces as `MirrorSendProtocolError` |
| Client sends invalid spec (parse error) | `loadSpec` returns `RpcProtocolError` code 255; surfaced to client |
| Transition disabled (no possible next step) | `exploreNext` returns `TransDisabled`; mirror sends `AllStepsDone` |
| `assumeState` fails (client state inconsistent with spec) | Returns `TransDisabled`; mirror sends `StepMismatch` |
| Invariant violated mid-exploration | `exploreCheck` returns `InvViolated` with trace; mirror sends `StepMismatch` + stops |
| Server crashes mid-session | Next `rpcCall` returns `RpcHttpError`; `exploreMirror` cleans up and surfaces error |
