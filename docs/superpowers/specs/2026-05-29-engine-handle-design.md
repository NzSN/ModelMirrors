# Engine.Handle Design

**Date:** 2026-05-29
**Status:** approved

## Purpose

Add an effect-parametric `EngineM` typeclass so the engine can be instantiated both purely (for testing) and with I/O (for interactive trace replay). The existing pure `Engine.Core` module remains untouched.

## Module Structure

```
src/Engine/
  Core.hs      -- unchanged: traceSteps, diffState (pure)
  Types.hs     -- unchanged: Step, VarDiff, StateDiff
  Handle.hs    -- new: EngineM typeclass
src/Engine.hs  -- updated umbrella: re-exports Engine.Handle too
```

`Engine.Handle` is added to `exposed-modules` in `ModelMirros.cabal`.

No new cabal dependencies.

## Typeclass (`Engine.Handle`)

```haskell
module Engine.Handle (EngineM (..)) where

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> (Step -> m (Map Text Value)) -> m [StateDiff]
```

`replayTrace` takes an ITF trace and a callback that reports the client's actual state for each step. It returns the list of `StateDiff` results.

The caller provides the callback — that's where transport I/O, network calls, or pure mock behavior lives. The engine owns only the stepping logic.

### Default Implementation

The default uses `traceSteps` and `diffState` from `Engine.Core`:

```haskell
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

Behavior:
- Iterates steps in order (0, 1, 2, ...), calling `report` for each.
- Compares expected vs actual via `diffState`.
- Continues on `StatesMatch`, stops on first `StateMismatch`.
- Returns all diffs accumulated up to the stopping point.

### Edge Cases

- Empty trace (0 states) → `pure []`.
- All steps match → returns `[StatesMatch, StatesMatch, ...]` for all steps.
- First step mismatches → returns `[StateMismatch ...]` immediately.
- Callback never returns → the caller's `m` determines semantics (IO would block, pure would be instant).

## Umbrella Update

`src/Engine.hs` re-exports `Engine.Handle`:

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

## Integration

- `Engine.Handle` depends on `Engine.Types` (Step, StateDiff), `Engine.Core` (traceSteps, diffState), and `Apalache.Types` (ItfTrace, Value).
- `Engine.Core` is unchanged — still pure, still testable in isolation.
- No dependency on `Protocol.*` or `Transport.*` — the engine stays independent of I/O mechanisms.

## Out of Scope

- `IO` instance of `EngineM` — callers define their own instances.
- Sending `MirrorMessage` protocol messages — that's the callback's job.
- Protocol state machine driving — not part of the engine.
