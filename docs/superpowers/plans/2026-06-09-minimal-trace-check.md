# MinimalTraceCheck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a `MinimalTraceCheck` module that normalizes `MirrorStep` sequences (strips trailing `AllStepsDone`, collapses `RecvReport+StepOk`/`RecvReport+StepMismatch` pairs) and compares two sequences for equality.

**Architecture:** A single pure module `MinimalTraceCheck` with two exported functions: `normalize` (sequence normalization) and `check` (normalize + compare). No dependencies beyond `Protocol.Mirror` for the `MirrorStep` type. Tests are pure unit tests, no apalache-mc needed.

**Tech Stack:** Haskell, tasty + tasty-hunit (matching existing test patterns)

---

## File Structure

- **Create:** `src/MinimalTraceCheck.hs` — the module
- **Modify:** `ModelMirrors.cabal` — add `MinimalTraceCheck` to exposed-modules  
- **Create:** `test/MinimalTraceCheckSpec.hs` — tests
- **Modify:** `test/Main.hs` — register new test spec

---

### Task 1: Create the MinimalTraceCheck module

**Files:**
- Create: `src/MinimalTraceCheck.hs`

- [ ] **Step 1: Write the module**

```haskell
module MinimalTraceCheck
  ( normalize
  , check
  ) where

import Protocol.Mirror (MirrorStep (..))

stripTrailingDone :: [MirrorStep] -> [MirrorStep]
stripTrailingDone = reverse . dropWhile isDone . reverse
  where
    isDone MirrorSendAllStepsDone = True
    isDone _ = False

collapsePairs :: [MirrorStep] -> [MirrorStep]
collapsePairs = go
  where
    go [] = []
    go (MirrorRecvReportState i1 _ : MirrorSendStepOk i2 : rest) | i1 == i2 =
      MirrorSendStepOk i2 : go rest
    go (MirrorRecvReportState i1 _ : MirrorSendStepMismatch i2 diff : rest) | i1 == i2 =
      MirrorSendStepMismatch i2 diff : go rest
    go (x : xs) = x : go xs

normalize :: [MirrorStep] -> [MirrorStep]
normalize = collapsePairs . stripTrailingDone

check :: [MirrorStep] -> [MirrorStep] -> Bool
check expected produced = normalize expected == normalize produced
```

- [ ] **Step 2: Verify it compiles (cabal)**

Run: `cabal build all`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/MinimalTraceCheck.hs
git commit -m "feat: add MinimalTraceCheck module"
```

---

### Task 2: Register the module in .cabal

**Files:**
- Modify: `ModelMirrors.cabal`

- [ ] **Step 1: Add `MinimalTraceCheck` to exposed-modules**

Add `MinimalTraceCheck,` to the `exposed-modules` list in the library section. Insert alphabetically after `Engine.Types,`:

```
        Engine.Types,
        MinimalTraceCheck,
        Protocol.Client,
```

- [ ] **Step 2: Verify it still compiles**

Run: `cabal build all`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add ModelMirrors.cabal
git commit -m "build: expose MinimalTraceCheck module"
```

---

### Task 3: Write tests

**Files:**
- Create: `test/MinimalTraceCheckSpec.hs`

- [ ] **Step 1: Write the test module**

```haskell
module MinimalTraceCheckSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Types (StateDiff (..), VarDiff (..))
import MinimalTraceCheck (check, normalize)
import Protocol.Mirror (MirrorStep (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

spec :: TestTree
spec = testGroup "MinimalTraceCheck"
  [ normalizeEmpty
  , normalizeOnlyAllDone
  , normalizeWithTrailingAllDone
  , normalizeCollapseOkPair
  , normalizeCollapseMismatchPair
  , normalizeMultipleCollapses
  , normalizeNoAllDoneInMiddle
  , checkSameTrace
  , checkDifferentTrace
  , checkMismatchVsMatch
  , checkEmptyVsNonEmpty
  ]

-------------------------------------------------------------------------------
-- normalize tests

normalizeEmpty :: TestTree
normalizeEmpty = testCase "normalize empty" $
  normalize [] @?= []

normalizeOnlyAllDone :: TestTree
normalizeOnlyAllDone = testCase "normalize strips sole AllStepsDone" $
  normalize [MirrorSendAllStepsDone] @?= []

normalizeWithTrailingAllDone :: TestTree
normalizeWithTrailingAllDone = testCase "normalize strips trailing AllStepsDone" $
  normalize
    [ MirrorSendInitialState act (Map.singleton (T.pack "x") (VInt 1))
    , MirrorRecvReportState 0 act
    , MirrorSendStepOk 0
    , MirrorSendAllStepsDone
    ]
  @?=
    [ MirrorSendInitialState act (Map.singleton (T.pack "x") (VInt 1))
    , MirrorSendStepOk 0
    ]
  where
    act = T.pack "init"

normalizeCollapseOkPair :: TestTree
normalizeCollapseOkPair = testCase "normalize collapses RecvReport+StepOk" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?=
    [ MirrorSendStepOk 0 ]

normalizeCollapseMismatchPair :: TestTree
normalizeCollapseMismatchPair = testCase "normalize collapses RecvReport+StepMismatch" $ do
  let mismatch = StateMismatch Map.empty Map.empty [ValueMismatch (T.pack "x") (VInt 1) (VInt 2)]
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepMismatch 0 mismatch
    ]
  @?=
    [ MirrorSendStepMismatch 0 mismatch ]

normalizeMultipleCollapses :: TestTree
normalizeMultipleCollapses = testCase "normalize collapses multiple pairs" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    , MirrorSendNextStep (T.pack "tick") Map.empty
    , MirrorRecvReportState 1 (T.pack "tick")
    , MirrorSendStepOk 1
    , MirrorSendAllStepsDone
    ]
  @?=
    [ MirrorSendStepOk 0
    , MirrorSendNextStep (T.pack "tick") Map.empty
    , MirrorSendStepOk 1
    ]

normalizeNoAllDoneInMiddle :: TestTree
normalizeNoAllDoneInMiddle = testCase "normalize keeps AllStepsDone if not trailing" $
  normalize
    [ MirrorSendAllStepsDone
    , MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?=
    [ MirrorSendAllStepsDone
    , MirrorSendStepOk 0
    ]

-------------------------------------------------------------------------------
-- check tests

checkSameTrace :: TestTree
checkSameTrace = testCase "check returns True for identical traces" $ do
  let trace =
        [ MirrorSendInitialState (T.pack "init") (Map.singleton (T.pack "x") (VInt 1))
        , MirrorRecvReportState 0 (T.pack "init")
        , MirrorSendStepOk 0
        , MirrorSendAllStepsDone
        ]
  check trace trace @?= True

checkDifferentTrace :: TestTree
checkDifferentTrace = testCase "check returns False for different traces" $
  check
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepMismatch 0 (StateMismatch Map.empty Map.empty [])
    ]
  @?= False

checkMismatchVsMatch :: TestTree
checkMismatchVsMatch = testCase "check returns False for mismatch vs match" $ do
  let diff = StateMismatch Map.empty Map.empty [ValueMismatch (T.pack "x") (VInt 1) (VInt 2)]
  check
    [ MirrorRecvReportState 0 (T.pack "tick")
    , MirrorSendStepOk 0
    ]
    [ MirrorRecvReportState 0 (T.pack "tick")
    , MirrorSendStepMismatch 0 diff
    ]
  @?= False

checkEmptyVsNonEmpty :: TestTree
checkEmptyVsNonEmpty = testCase "check returns False for empty vs non-empty" $
  check
    []
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?= False
```

Note: `Value` is `Apalache.Types.Value` — need to import it. But wait, `MirrorStep` already uses `Value` through `Protocol.Mirror`. However, to construct `Value` values in tests, we need the import. Let me check what imports are needed.

Actually, `VInt` is from `Apalache.Types`. And `VarDiff`, `StateDiff`, `ValueMismatch` are from `Engine.Types`. Let me add the proper import.

Also `Map.singleton` needs `Data.Map.Strict`. I'll add the import.

Let me check the existing test imports to be safe and adjust.

- [ ] **Step 2: Verify test compiles**

Run: `cabal build ModelMirrors-test`
Expected: Compiles without errors.

- [ ] **Step 3: Run tests**

Run: `cabal test ModelMirrors-test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/MinimalTraceCheckSpec.hs
git commit -m "test: add MinimalTraceCheck tests"
```

---

### Task 4: Register test spec in Main.hs

**Files:**
- Modify: `test/Main.hs`

- [ ] **Step 1: Add import and test group entry**

Add the import:
```haskell
import qualified MinimalTraceCheckSpec
```

Add to the `testGroup` list:
```haskell
  , MinimalTraceCheckSpec.spec
```

- [ ] **Step 2: Verify full test suite passes**

Run: `cabal test ModelMirrors-test`
Expected: All tests pass, including new MinimalTraceCheck tests.

- [ ] **Step 3: Commit**

```bash
git add test/Main.hs
git commit -m "test: register MinimalTraceCheck tests"
```

---

### Task 5: Verify Bazel build

**Files:** (none to modify — Bazel uses globs)

- [ ] **Step 1: Build with Bazel**

Run: `bazel build //...`
Expected: Builds without errors.

- [ ] **Step 2: Run tests with Bazel**

Run: `bazel test //test:ModelMirrors-test`
Expected: Tests pass.

---
