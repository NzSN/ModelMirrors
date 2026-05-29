# Trace Engine Design

**Date:** 2026-05-29
**Status:** approved

## Purpose

Provide a pure, lazy engine for stepping through ITF traces and comparing expected states against actual states. The engine produces a lazy list of indexed steps from a trace and provides a function to diff two states (expected vs. actual) with structured difference reporting.

The engine is pure — it has no knowledge of transport, protocol, or I/O. The caller is responsible for driving communication and handling results.

## Module Structure

Three new source files, plus an umbrella re-export module:

```
src/Engine.hs              -- re-exports Engine.Types + Engine.Core
src/Engine/Types.hs        -- Step, VarDiff, StateDiff
src/Engine/Core.hs         -- traceSteps, diffState
```

`Engine` is added to `exposed-modules` in `ModelMirros.cabal`.

The engine has no dependency on `Protocol.*`. It does depend on `Apalache.Types` for `Value` and `ItfTrace`. The `Map` and `Text` dependencies are already in the package.

## Types (`Engine.Types`)

### Step

```haskell
data Step = Step
  { stepIdx  :: !Int
  , stepVars :: !(Map Text Value)
  }
```

A single step in a trace: its 0-based index and the variables-to-values mapping for that state. The first state in a trace (index 0) is the initial state; subsequent states are the result of each transition.

### VarDiff

```haskell
data VarDiff
  = ValueMismatch !Text !Value !Value   -- varName expected actual
  | MissingVar    !Text !Value          -- varName expected (absent from actual)
  | ExtraVar      !Text !Value          -- varName actual (absent from expected)
```

Represents a single variable-level difference between expected and actual states. Three variants:

- **ValueMismatch**: variable exists in both maps but with different values.
- **MissingVar**: variable exists in expected state but not in actual state.
- **ExtraVar**: variable exists in actual state but not in expected state.

`VNull` is a legitimate `Value` and never used as a sentinel for absence.

### StateDiff

```haskell
data StateDiff
  = StatesMatch
  | StateMismatch
      !(Map Text Value)   -- expected state
      !(Map Text Value)   -- actual state
      ![VarDiff]           -- differences found
```

Result of comparing two states. `StatesMatch` when the two maps are identical. `StateMismatch` carries both full maps for context plus the list of per-variable differences. An empty diff list never occurs in `StateMismatch`.

## Core API (`Engine.Core`)

### traceSteps

```haskell
traceSteps :: ItfTrace -> [Step]
```

Produces a lazy list of `Step` values from an `ItfTrace`. Each state in the trace is paired with its 0-based index.

Implementation: `zipWith` over `traceStates trace` with ascending indices.

### diffState

```haskell
diffState :: Map Text Value -> Map Text Value -> StateDiff
```

Compares two state maps and reports differences.

Algorithm:
1. Collect the set union of keys from both maps.
2. For each key:
   - Present in both maps with equal values → skip.
   - Present in both maps with different values → `ValueMismatch`.
   - Only in expected → `MissingVar`.
   - Only in actual → `ExtraVar`.
3. If no differences accumulated → `StatesMatch`, otherwise → `StateMismatch`.

Edge cases:
- Two empty maps → `StatesMatch`.
- Same map → `StatesMatch`.
- Map equality is determined by `==` on `Value`, which is derived.

## Integration

- `Apalache.Core` does NOT re-export `Engine` — the engine is a separate subsystem.
- `Engine.Types` imports `Value` from `Apalache.Types`; no circular dependency.
- No new cabal dependencies required.

## Out of Scope

- Protocol state machine driving — this is just the pure engine.
- JSON serialization for `Step`, `VarDiff`, `StateDiff` — not needed yet.
- Transport/IO integration — caller's responsibility.
