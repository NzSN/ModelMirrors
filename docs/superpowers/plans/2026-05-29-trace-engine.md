# Trace Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a pure, lazy trace engine module (`Engine`) that steps through ITF traces and compares expected vs actual states.

**Architecture:** Three new source files under `src/Engine/` — `Types.hs` (data types), `Core.hs` (pure functions), and a re-export umbrella at `src/Engine.hs`. The engine depends on `Apalache.Types` for `Value` and `ItfTrace`, on `containers` for `Map`, and on `text` for `Text`. No protocol or transport dependencies. Pure unit tests follow the existing hand-written spec pattern.

**Tech Stack:** Haskell, GHC 9.12+, `base`, `containers`, `text` (all already in package deps).

---

### Task 1: Engine Types Module

**Files:**
- Create: `src/Engine/Types.hs`

- [ ] **Step 1: Create `src/Engine/Types.hs`**

```haskell
module Engine.Types where

import Apalache.Types (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data Step = Step
  { stepIdx  :: !Int
  , stepVars :: !(Map Text Value)
  } deriving (Show, Eq)

data VarDiff
  = ValueMismatch !Text !Value !Value
  | MissingVar    !Text !Value
  | ExtraVar      !Text !Value
  deriving (Show, Eq)

data StateDiff
  = StatesMatch
  | StateMismatch
      !(Map Text Value)
      !(Map Text Value)
      ![VarDiff]
  deriving (Show, Eq)
```

- [ ] **Step 2: Build to verify module compiles**

Run: `cabal build all`
Expected: Build succeeds (though unused module warning is fine at this point).

- [ ] **Step 3: Commit**

```bash
git add src/Engine/Types.hs
git commit -m "feat: add Engine.Types module"
```

---

### Task 2: Engine Core Module

**Files:**
- Create: `src/Engine/Core.hs`

- [ ] **Step 1: Create `src/Engine/Core.hs`**

```haskell
module Engine.Core where

import Apalache.Types (ItfTrace (..), Value)
import Engine.Types (Step (..), StateDiff (..), VarDiff (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

traceSteps :: ItfTrace -> [Step]
traceSteps trace = zipWith (\i m -> Step i m) [0..] (traceStates trace)

diffState :: Map Text Value -> Map Text Value -> StateDiff
diffState expected actual =
  let allKeys = Map.keysSet expected <> Map.keysSet actual
      diffs = foldr checkKey [] allKeys
        where
          checkKey k acc =
            case (Map.lookup k expected, Map.lookup k actual) of
              (Just ev, Just av) | ev == av  -> acc
              (Just ev, Just av)             -> ValueMismatch k ev av : acc
              (Just ev, Nothing)             -> MissingVar k ev : acc
              (Nothing, Just av)             -> ExtraVar k av : acc
              (Nothing, Nothing)             -> acc
  in case diffs of
       [] -> StatesMatch
       _  -> StateMismatch expected actual diffs
```

- [ ] **Step 2: Build to verify module compiles**

Run: `cabal build all`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/Engine/Core.hs
git commit -m "feat: add Engine.Core module with traceSteps and diffState"
```

---

### Task 3: Engine Umbrella Module

**Files:**
- Create: `src/Engine.hs`

- [ ] **Step 1: Create `src/Engine.hs`**

```haskell
module Engine
  ( module Engine.Types
  , module Engine.Core
  ) where

import Engine.Types
import Engine.Core
```

- [ ] **Step 2: Build to verify**

Run: `cabal build all`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/Engine.hs
git commit -m "feat: add Engine umbrella re-export module"
```

---

### Task 4: Register Modules in Cabal

**Files:**
- Modify: `ModelMirros.cabal:65-69`

- [ ] **Step 1: Add Engine modules to `exposed-modules`**

Replace the existing `exposed-modules:` block (lines 65-73) with:

```
    exposed-modules:
        Apalache.Core,
        Apalache.Types,
        Apalache.Command,
        Apalache.Trace,
        Engine,
        Engine.Types,
        Engine.Core,
        Protocol.Core,
        Protocol.Format.Json,
        Protocol.Transport.Core,
        Protocol.Transport.Stdio
```

- [ ] **Step 2: Build to verify**

Run: `cabal build all`
Expected: Build succeeds with no warnings.

- [ ] **Step 3: Commit**

```bash
git add ModelMirros.cabal
git commit -m "feat: expose Engine modules in cabal file"
```

---

### Task 5: Tests for Engine

**Files:**
- Create: `test/EngineSpec.hs`

- [ ] **Step 1: Create `test/EngineSpec.hs`**

```haskell
module EngineSpec (spec) where

import Apalache.Types (ItfTrace (..), Value (..))
import Engine.Core (traceSteps, diffState)
import Engine.Types (Step (..), StateDiff (..), VarDiff (..))

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== EngineSpec ==="
  testTraceStepsEmpty
  testTraceStepsOne
  testTraceStepsTwo
  testDiffEmptyMaps
  testDiffIdentical
  testDiffValueMismatch
  testDiffMissingVar
  testDiffExtraVar
  testDiffMixed

----------------------------------------------------------------------
-- traceSteps tests

testTraceStepsEmpty :: IO ()
testTraceStepsEmpty = do
  putStrLn "[1] traceSteps empty trace ..."
  let trace = ItfTrace [] []
  let steps = traceSteps trace
  if null steps
    then putStrLn "  PASS: empty trace yields empty list"
    else do
      putStrLn "FAIL: expected empty list"
      exitFailure

testTraceStepsOne :: IO ()
testTraceStepsOne = do
  putStrLn "[2] traceSteps single state ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let trace = ItfTrace [T.pack "x"] [s0]
  let steps = traceSteps trace
  case steps of
    [Step 0 m]
      | m == s0 -> putStrLn "  PASS: single state produces Step 0"
      | otherwise -> do
          putStrLn "FAIL: state data incorrect"
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected one step, got " ++ show (length steps)
      exitFailure

testTraceStepsTwo :: IO ()
testTraceStepsTwo = do
  putStrLn "[3] traceSteps two states ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let steps = traceSteps trace
  case steps of
    [Step 0 a, Step 1 b]
      | a == s0 && b == s1 -> putStrLn "  PASS: two states produce Steps 0 and 1"
      | otherwise -> do
          putStrLn "FAIL: state data incorrect"
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected two steps, got " ++ show (length steps)
      exitFailure

----------------------------------------------------------------------
-- diffState tests

testDiffEmptyMaps :: IO ()
testDiffEmptyMaps = do
  putStrLn "[4] diffState empty maps ..."
  let result = diffState Map.empty (Map.empty :: Map Text Value)
  case result of
    StatesMatch -> putStrLn "  PASS: empty maps match"
    _ -> do
      putStrLn "FAIL: expected StatesMatch"
      exitFailure

testDiffIdentical :: IO ()
testDiffIdentical = do
  putStrLn "[5] diffState identical maps ..."
  let m = Map.fromList
        [ (T.pack "a", VInt 1)
        , (T.pack "b", VBool True)
        ]
  let result = diffState m m
  case result of
    StatesMatch -> putStrLn "  PASS: identical maps match"
    _ -> do
      putStrLn "FAIL: expected StatesMatch"
      exitFailure

testDiffValueMismatch :: IO ()
testDiffValueMismatch = do
  putStrLn "[6] diffState value mismatch ..."
  let expected = Map.singleton (T.pack "x") (VInt 1)
  let actual   = Map.singleton (T.pack "x") (VInt 2)
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [ValueMismatch k (VInt 1) (VInt 2)]
      | k == T.pack "x" -> putStrLn "  PASS: value mismatch detected"
    _ -> do
      putStrLn $ "FAIL: expected ValueMismatch, got " ++ show result
      exitFailure

testDiffMissingVar :: IO ()
testDiffMissingVar = do
  putStrLn "[7] diffState missing variable ..."
  let expected = Map.singleton (T.pack "x") (VInt 1)
  let actual   = Map.empty
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [MissingVar k (VInt 1)]
      | k == T.pack "x" -> putStrLn "  PASS: missing var detected"
    _ -> do
      putStrLn $ "FAIL: expected MissingVar, got " ++ show result
      exitFailure

testDiffExtraVar :: IO ()
testDiffExtraVar = do
  putStrLn "[8] diffState extra variable ..."
  let expected = Map.empty
  let actual   = Map.singleton (T.pack "y") (VStr (T.pack "bonus"))
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [ExtraVar k (VStr s)]
      | k == T.pack "y" && s == T.pack "bonus" -> putStrLn "  PASS: extra var detected"
    _ -> do
      putStrLn $ "FAIL: expected ExtraVar, got " ++ show result
      exitFailure

testDiffMixed :: IO ()
testDiffMixed = do
  putStrLn "[9] diffState mixed differences ..."
  let expected = Map.fromList
        [ (T.pack "a", VInt 1)
        , (T.pack "b", VBool True)
        ]
  let actual = Map.fromList
        [ (T.pack "a", VInt 99)
        , (T.pack "c", VStr (T.pack "hello"))
        ]
  let result = diffState expected actual
  case result of
    StateMismatch _ _ diffs
      | length diffs == 3 -> putStrLn "  PASS: all three diffs found"
      | otherwise -> do
          putStrLn $ "FAIL: expected 3 diffs, got " ++ show (length diffs)
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected StateMismatch, got " ++ show result
      exitFailure
```

- [ ] **Step 2: Commit**

```bash
git add test/EngineSpec.hs
git commit -m "test: add pure unit tests for Engine"
```

---

### Task 6: Wire Engine Tests into Test Runner

**Files:**
- Modify: `test/Main.hs`
- Modify: `ModelMirros.cabal:130-133`

- [ ] **Step 1: Add `EngineSpec` import and call in `test/Main.hs`**

Replace `test/Main.hs` content:

```haskell
module Main (main) where

import qualified Apalache.CommandSpec as CommandSpec
import qualified Apalache.TraceSpec as TraceSpec
import qualified Apalache.TypesSpec as TypesSpec
import qualified EngineSpec

main :: IO ()
main = do
  EngineSpec.spec
  CommandSpec.spec
  TraceSpec.spec
  TypesSpec.spec
```

- [ ] **Step 2: Add `EngineSpec` to `other-modules` in `ModelMirros.cabal`**

Replace the `other-modules:` block (lines 130-133) with:

```
    other-modules:
        Apalache.CommandSpec,
        Apalache.TraceSpec,
        Apalache.TypesSpec,
        EngineSpec
```

- [ ] **Step 3: Build tests**

Run: `cabal build all`
Expected: Build succeeds with no warnings.

- [ ] **Step 4: Run tests**

Run: `cabal test all`
Expected: All tests pass (EngineSpec runs first, then the existing Apalache tests).

NOTE: EngineSpec tests are pure and will run fast. The existing Apalache tests will still run after and require `apalache-mc`.

- [ ] **Step 5: Commit**

```bash
git add test/Main.hs ModelMirros.cabal
git commit -m "test: wire EngineSpec into test suite"
```

---

### Task 7: Final Verification

- [ ] **Step 1: Full build with warnings as errors**

Run: `cabal build all --ghc-options=-Werror`
Expected: Build succeeds with zero warnings.

- [ ] **Step 2: Run full test suite**

Run: `cabal test all`
Expected: All tests pass.

- [ ] **Step 3: Verify nothing broken in git**

Run: `git status`
Expected: Clean working tree, all changes committed.
