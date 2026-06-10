# ServerBehavior Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `Apalache.Rpc.ServerBehavior` — replay an ITF trace against a live apalache JSON-RPC explorer, observing RPC outcomes and server state at each step.

**Architecture:** One new module. Drives the existing `Apalache.Explorer` to execute RPC calls dictated by the trace's `clLastMethod`, classifies RPC results into string tags, queries the loaded spec's state after each operation. No new dependencies.

**Tech Stack:** Existing: `Apalache.Explorer`, `Apalache.Rpc.Types`, `Apalache.Rpc.Client`, `Apalache.Types`, `containers`, `text`.

---

### Task 1: Write `Apalache.Rpc.ServerBehavior`

**Files:**
- Create: `src/Apalache/Rpc/ServerBehavior.hs`

- [ ] **Step 1: Create the module with full implementation**

File: `src/Apalache/Rpc/ServerBehavior.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Apalache.Rpc.ServerBehavior
  ( ServerStep (..)
  , replayTrace
  ) where

import Apalache.Rpc.Types
  ( ApalacheSpec (..)
  , RpcError (..)
  , InvariantKind (..)
  )
import Apalache.Explorer
  ( withApalacheServer
  , newExplorer
  , exploreInit
  , exploreNext
  , exploreCheck
  , exploreQueryState
  , exploreAssumeState
  , exploreRollback
  , exploreDispose
  , Explorer (..)
  )
import Apalache.Types
  ( ItfTrace (..)
  , TraceState (..)
  , Value (..)
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

data ServerStep = ServerStep
  { ssMethod   :: !Text
  , ssExpState :: !(Map Text Value)
  , ssObsState :: !(Map Text Value)
  , ssResult   :: !Text
  } deriving (Show, Eq)

replayTrace :: ApalacheSpec -> ItfTrace -> IO (Either RpcError [ServerStep])
replayTrace spec trace =
  withApalacheServer (Just 8822) $ \server -> do
    explRes <- newExplorer server spec [] []
    case explRes of
      Left err -> pure $ Left err
      Right expl0 -> do
        initRes <- exploreInit expl0
        case initRes of
          Left err -> pure $ Left err
          Right expl1 -> do
            qs0 <- exploreQueryState expl1
            let obs0 = either (const Map.empty) id qs0
                steps = drop 1 (traceStates trace)
            go expl1 steps [] obs0

go :: Explorer -> [TraceState] -> [ServerStep] -> Map Text Value -> IO (Either RpcError [ServerStep])
go _ [] acc _ = pure $ Right (reverse acc)
go expl (ts : rest) acc prevObs = do
  let allVars = Map.union (stateVars ts) (parameters ts)
      method  = case Map.lookup (T.pack "clLastMethod") allVars of
                  Just (VStr m) -> m
                  _             -> T.empty
      expState = allVars
  case method of
    m | T.null m || m == T.pack "none" || m == T.pack "loadSpec" || m == T.pack "health" -> do
        let step = ServerStep m expState prevObs (T.pack "ok")
        go expl rest (step : acc) prevObs

    m | m == T.pack "assumeTransition" || m == T.pack "nextStep" -> do
        nRes <- exploreNext expl 0
        case nRes of
          Left err -> do
            qs <- exploreQueryState expl
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (classifyResult err)
            go expl rest (step : acc) obs
          Right (expl', _) -> do
            qs <- exploreQueryState expl'
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (T.pack "ok")
            go expl' rest (step : acc) obs

    m | m == T.pack "checkInvariant" -> do
        cRes <- exploreCheck expl 0 StateInvariant
        qs <- exploreQueryState expl
        let obs = either (const Map.empty) id qs
            resTag = either classifyResult (const (T.pack "ok")) cRes
        let step = ServerStep m expState obs resTag
        go expl rest (step : acc) obs

    m | m == T.pack "query" -> do
        qs <- exploreQueryState expl
        let obs = either (const Map.empty) id qs
            step = ServerStep m expState obs (T.pack "ok")
        go expl rest (step : acc) obs

    m | m == T.pack "assumeState" -> do
        asRes <- exploreAssumeState expl Map.empty
        case asRes of
          Left err -> do
            qs <- exploreQueryState expl
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (classifyResult err)
            go expl rest (step : acc) obs
          Right (expl', _) -> do
            qs <- exploreQueryState expl'
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (T.pack "ok")
            go expl' rest (step : acc) obs

    m | m == T.pack "rollback" -> do
        let snap = case Map.lookup (T.pack "clSessionId") expState of
              Just (VInt n) -> fromIntegral n
              _             -> 0
        rbRes <- exploreRollback expl snap
        case rbRes of
          Left err -> do
            qs <- exploreQueryState expl
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (classifyResult err)
            go expl rest (step : acc) obs
          Right expl' -> do
            qs <- exploreQueryState expl'
            let obs = either (const Map.empty) id qs
                step = ServerStep m expState obs (T.pack "ok")
            go expl' rest (step : acc) obs

    m | m == T.pack "disposeSpec" -> do
        dRes <- exploreDispose expl
        qs <- exploreQueryState expl
        let obs = either (const Map.empty) id qs
            resTag = either classifyResult (const (T.pack "ok")) dRes
        let step = ServerStep m expState obs resTag
        go expl rest (step : acc) obs

    _ -> do
        qs <- exploreQueryState expl
        let obs = either (const Map.empty) id qs
            step = ServerStep method expState obs (T.pack "unknown")
        go expl rest (step : acc) obs

classifyResult :: RpcError -> Text
classifyResult (RpcHttpError _)       = T.pack "http_error"
classifyResult (RpcProtocolError _ _) = T.pack "protocol_error"
classifyResult (RpcParseError _)      = T.pack "parse_error"
```

- [ ] **Step 2: Add module to `Apalache.Core` re-export**

File: `src/Apalache/Core.hs` — add import and re-export:

```haskell
module Apalache.Core
  ( module Apalache.Types
  , module Apalache.Command
  , module Apalache.Trace
  , module Apalache.Explorer
  , module Apalache.Rpc.Types
  , module Apalache.Rpc.Client
  , module Apalache.Rpc.ServerBehavior
  ) where

import Apalache.Types
import Apalache.Command
import Apalache.Trace
import Apalache.Explorer
import Apalache.Rpc.Types
import Apalache.Rpc.Client
import Apalache.Rpc.ServerBehavior
```

- [ ] **Step 3: Add `Apalache.Rpc.ServerBehavior` to cabal exposed-modules**

File: `ModelMirrors.cabal` — add line after `Apalache.Rpc.Client`:

```
        Apalache.Rpc.ServerBehavior,
```

- [ ] **Step 4: Build to verify compilation**

```bash
cabal build all
```
Expected: builds without errors (with -Wall).

---

### Task 2: Write integration test

**Files:**
- Create: `test/Apalache/ServerBehaviorSpec.hs`
- Modify: `test/Main.hs`
- Modify: `ModelMirrors.cabal`

- [ ] **Step 1: Create the test module**

File: `test/Apalache/ServerBehaviorSpec.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Apalache.ServerBehaviorSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace (..)
  , Value (..)
  )
import Apalache.Command (generateTraces)
import Apalache.Rpc.Types (mkSpecFromFile, RpcError (..))
import Apalache.Rpc.ServerBehavior
  ( ServerStep (..)
  , replayTrace
  )

import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure, (@?=))

spec :: TestTree
spec = testGroup "ServerBehaviorSpec"
  [ testReplayTrace
  ]

specFile :: FilePath
specFile = "specs/ApalacheRPCClient.tla"

config :: ApalacheConfig
config = ApalacheConfig
  { specPath      = specFile
  , initPredicate = Nothing
  , nextPredicate = Nothing
  , constInit     = Nothing
  , invariant     = T.pack "ClientUntilSessionCall"
  , lengthBound   = 5
  , paramVarNames = T.empty
  }

traceConfig :: TraceGenerationConfig
traceConfig = TraceGenerationConfig
  { numTraces = 1
  , view      = Nothing
  }

testReplayTrace :: TestTree
testReplayTrace = testCase "replayTrace replays spec trace against live explorer" $ do
  traceResult <- generateTraces config traceConfig
  case traceResult of
    Left err -> assertFailure $ "generateTraces failed: " ++ show err
    Right (GenerationError msg) -> assertFailure $ "trace generation error: " ++ show msg
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated (trace : _)) -> do
      spec <- mkSpecFromFile specFile
      result <- replayTrace spec trace
      case result of
        Left (RpcHttpError msg) ->
          assertFailure $ "RPC HTTP error (apalache server not running?): " ++ T.unpack msg
        Left err ->
          assertFailure $ "replayTrace failed: " ++ show err
        Right steps -> do
          assertBool "replayTrace produced no steps" (not (null steps))
          -- Every step should have ssMethod set
          let methodsOk = all (\s -> ssMethod s /= T.empty) steps
          assertBool "some steps have empty ssMethod" methodsOk
          -- Every step should have a result tag
          let resultsOk = all (\s -> ssResult s /= T.empty) steps
          assertBool "some steps have empty ssResult" resultsOk
```

- [ ] **Step 2: Add test module to cabal other-modules**

File: `ModelMirrors.cabal` — add after `Apalache.TypesSpec`:

```
        Apalache.ServerBehaviorSpec,
```

- [ ] **Step 3: Register test in Main.hs**

File: `test/Main.hs` — add import and testGroup entry:

```haskell
import qualified Apalache.ServerBehaviorSpec as ServerBehaviorSpec
```

And add to the testGroup list:
```haskell
  , ServerBehaviorSpec.spec
```

- [ ] **Step 4: Build test suite and run the new test**

```bash
cabal build all
cabal test ModelMirrors-test --test-option='-p ServerBehaviorSpec'
```
Expected: test passes, showing steps were replayed.

---

### Task 3: Verify full test suite

- [ ] **Step 1: Run all tests**

```bash
cabal test all
```
Expected: all existing tests pass, new test passes.
