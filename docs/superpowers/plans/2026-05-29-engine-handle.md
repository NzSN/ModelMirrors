# Engine.Handle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an effect-parametric `EngineM` typeclass with a default `replayTrace` method, so the engine can be instantiated both purely and with I/O.

**Architecture:** New `src/Engine/Handle.hs` module with the `EngineM` class. The default implementation delegates to the existing pure `Engine.Core` (traceSteps, diffState). `Engine` umbrella updated. No new dependencies.

**Tech Stack:** Haskell, GHC 9.12+, `base`, `containers`, `text` (all already in package deps).

---

### Task 1: Engine Handle Module

**Files:**
- Create: `src/Engine/Handle.hs`

- [ ] **Step 1: Create `src/Engine/Handle.hs`**

```haskell
module Engine.Handle (EngineM (..)) where

import Apalache.Types (ItfTrace (..), Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StateDiff (..))

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> (Step -> m (Map Text Value)) -> m [StateDiff]
  replayTrace trace report = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        actual <- report step
        let diff = diffState (stepVars step) actual
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]
```

Add `Engine.Handle` to `exposed-modules` in `ModelMirros.cabal`, alphabetical among `Engine*` entries.

- [ ] **Step 2: Build to verify**

Run: `cabal build all`
Expected: Build succeeds with no warnings.

- [ ] **Step 3: Commit**

```bash
git add src/Engine/Handle.hs ModelMirros.cabal
git commit -m "feat: add Engine.Handle with EngineM typeclass"
```

---

### Task 2: Update Engine Umbrella

**Files:**
- Modify: `src/Engine.hs`

- [ ] **Step 1: Add `Engine.Handle` to the umbrella re-export**

Replace `src/Engine.hs` with:

```haskell
module Engine
  ( module Engine.Types
  , module Engine.Core
  , module Engine.Handle
  ) where

import Engine.Types
import Engine.Core
import Engine.Handle
```

- [ ] **Step 2: Build to verify**

Run: `cabal build all`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/Engine.hs
git commit -m "feat: re-export Engine.Handle from Engine umbrella"
```

---

### Task 3: Tests for replayTrace

**Files:**
- Modify: `test/EngineSpec.hs`

Add tests to the existing `EngineSpec` module. Append these functions and add their calls to `spec`.

- [ ] **Step 1: Add test functions for replayTrace**

Append to `test/EngineSpec.hs` after the existing diffState tests, before the end of the module:

```haskell
import Apalache.Types (ItfTrace (..))
import Engine.Handle (EngineM (..))
import Control.Monad.Identity (runIdentity)

----------------------------------------------------------------------
-- replayTrace tests

testReplayEmpty :: IO ()
testReplayEmpty = do
  putStrLn "[10] replayTrace empty trace ..."
  let trace = ItfTrace [] []
  let report = \_ -> pure (Map.empty :: Map Text Value)
  let result = runIdentity (replayTrace trace report)
  if null result
    then putStrLn "  PASS: empty trace yields empty list"
    else do
      putStrLn "FAIL: expected empty list"
      exitFailure

testReplayAllMatch :: IO ()
testReplayAllMatch = do
  putStrLn "[11] replayTrace all match ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report step = pure (stepVars step)
  let results = runIdentity (replayTrace trace report)
  case results of
    [StatesMatch, StatesMatch] -> putStrLn "  PASS: both steps match"
    _ -> do
      putStrLn $ "FAIL: expected [StatesMatch, StatesMatch], got " ++ show results
      exitFailure

testReplayFirstMismatch :: IO ()
testReplayFirstMismatch = do
  putStrLn "[12] replayTrace first mismatch ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report step = pure (Map.singleton (T.pack "x") (VInt 999))
  let results = runIdentity (replayTrace trace report)
  case results of
    [StateMismatch{}] -> putStrLn "  PASS: stops on first mismatch"
    _ -> do
      putStrLn $ "FAIL: expected [StateMismatch], got " ++ show results
      exitFailure

testReplaySecondMismatch :: IO ()
testReplaySecondMismatch = do
  putStrLn "[13] replayTrace second mismatch ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report (Step 0 _) = pure (Map.singleton (T.pack "x") (VInt 1))
      report _           = pure (Map.singleton (T.pack "x") (VInt 999))
  let results = runIdentity (replayTrace trace report)
  case results of
    [StatesMatch, StateMismatch{}] -> putStrLn "  PASS: matches first, stops on second"
    _ -> do
      putStrLn $ "FAIL: expected [StatesMatch, StateMismatch], got " ++ show results
      exitFailure
```

- [ ] **Step 2: Add calls to `spec`**

In the `spec` function in `test/EngineSpec.hs`, add at the end (before the line with `testDiffMixed`):

```haskell
  testReplayEmpty
  testReplayAllMatch
  testReplayFirstMismatch
  testReplaySecondMismatch
```

- [ ] **Step 3: Build and run tests**

Run: `cabal test all`
Expected: All tests pass (9 existing + 4 new = 13 EngineSpec tests).

- [ ] **Step 4: Commit**

```bash
git add test/EngineSpec.hs
git commit -m "test: add replayTrace tests via Identity monad"
```

---

### Task 4: Final Verification

- [ ] **Step 1: Full build with warnings as errors**

Run: `cabal build all --ghc-options=-Werror`
Expected: Build succeeds with zero warnings.

- [ ] **Step 2: Run full test suite**

Run: `cabal test all`
Expected: All tests pass.

- [ ] **Step 3: Verify git status**

Run: `git status`
Expected: Clean working tree.
