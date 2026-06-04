# Apalache Module Design

## Overview

The `Apalache` module wraps calls to the `apalache-mc` CLI tool. It has three responsibilities:

1. **Validate** a TLA+ specification (check parse, type, and soundness).
2. **Generate** ITF traces from a validated specification for trace replay.
3. **Read and parse** ITF trace JSON files that Apalache produces.

## Module Structure

```
src/Apalache/
  Types.hs       -- Core data types
  Command.hs     -- Invoke apalache-mc, parse output
  Trace.hs       -- Parse ITF trace JSON files
```

## Core Types (`Types.hs`)

### `ApalacheConfig`

Configuration shared across validate and trace-generation runs.

```haskell
data ApalacheConfig = ApalacheConfig
  { specPath       :: !FilePath         -- Path to the .tla spec file
  , initPredicate  :: !(Maybe Text)     -- --init, defaults to "Init"
  , nextPredicate  :: !(Maybe Text)     -- --next, defaults to "Next"
  , constInit      :: !(Maybe Text)     -- --cinit, optional constant initializer
  }
```

### `ValidateResult`

Result of `validateSpec`. Maps to step 2 of the Mirror Protocol (spec soundness check).

```haskell
data ValidateResult
  = SpecValid
      -- ^ Specification passed typechecking and model checking.
  | SpecInvalid !Text
      -- ^ Specification is unsound. Contains the error message from Apalache.
```

### `TraceGenerationConfig`

Parameters controlling how traces are generated. Corresponds to the trace configuration in step 1 of the Mirror Protocol (number of traces, length of traces, etc.).

```haskell
data TraceGenerationConfig = TraceGenerationConfig
  { invariant   :: !Text       -- Invariant to check, e.g. "TypeOK"
  , lengthBound :: !Int        -- --length (max Next steps), default 10
  , numTraces   :: !Int        -- --max-error, how many traces to generate, default 1
  }
```

### `TraceGenerationResult`

Result of `generateTraces`. Contains the parsed ITF traces ready for replay (protocol steps 3-8).

```haskell
data TraceGenerationResult
  = TracesGenerated ![ItfTrace]
      -- ^ Traces successfully generated and parsed.
  | GenerationError !Text
      -- ^ Failed to generate or parse traces.
```

### `ApalacheError`

Shared error type used across the module.

```haskell
data ApalacheError = ApalacheError !Text
  -- ^ Apalache itself failed (tool not installed, crashed, etc.).
```

### `ItfTrace`

A parsed ITF trace produced by Apalache.

```haskell
data ItfTrace = ItfTrace
  { traceVars   :: ![Text]             -- Variable names (order-preserving from JSON "vars" field)
  , traceStates :: ![Map Text Value]   -- Sequence of states, each mapping variable name to its value
  }
```

### `Value`

Represents a TLA+ value as found in ITF trace JSON.

```haskell
data Value
  = VInt    !Integer
  | VBool   !Bool
  | VStr    !Text
  | VSet    ![Value]            -- TLA+ sets: {a, b, c} represented as JSON arrays
  | VTuple  ![Value]            -- TLA+ tuples: <<a, b>> represented as JSON arrays
  | VRecord !(Map Text Value)   -- TLA+ records: [x |-> a, y |-> b]
  | VNull                       -- Null/missing value
```

## Core Functions

### `Command.hs`

Wraps process invocation and output parsing. Two main operations: validate and generate traces.

```haskell
-- | Validate a TLA+ specification.
-- Runs: apalache-mc typecheck <spec>  then  apalache-mc check --length=<bound> <spec>
-- Pure spec validation — does NOT generate trace files.
validateSpec :: ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)

-- | Generate ITF traces from a validated specification.
-- Runs: apalache-mc check --inv=<inv> --length=<bound> --max-error=<n> --output-traces <spec>
-- Returns parsed traces ready for the replay loop.
generateTraces :: ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError TraceGenerationResult)
```

#### `validateSpec` Implementation Sketch

1. First run `apalache-mc typecheck <spec.tla>` to catch parse/type errors early.
2. If typecheck passes, run `apalache-mc check --length=<bound> <spec.tla>` for soundness.
3. Neither step enables `--output-traces` — no trace files are written.
4. Parse exit code:
   - `ExitSuccess` → `Right SpecValid`
   - `ExitFailure n` with parse/type error → `Right (SpecInvalid <message>)`
   - Process crashed (cannot find `apalache-mc`) → `Left (ApalacheError <message>)`

#### `generateTraces` Implementation Sketch

1. Build CLI args: `["check", "--inv="<>inv, "--length="<>len, "--max-error="<>n, "--output-traces", specPath]`
2. Run `apalache-mc` via `System.Process.readProcessWithExitCode`.
3. On `ExitFailure` (counterexamples found): discover the output directory from Apalache's output, find `violation*.itf.json` files → `Right (TracesGenerated traces)`
4. On `ExitSuccess` (spec valid, no violations): look for example trace files in output dir → `Right (TracesGenerated traces)`
5. On unexpected crash → `Left (ApalacheError <message>)`

#### `generateTraces` — CLI Argument Mapping

| Config Field | CLI Flag |
|---|---|
| `specPath` | positional argument |
| `invariant` | `--inv=<value>` |
| `lengthBound` | `--length=<value>` |
| `numTraces` | `--max-error=<value>` |
| `initPredicate` | `--init=<value>` (if set) |
| `nextPredicate` | `--next=<value>` (if set) |
| `constInit` | `--cinit=<value>` (if set) |
| (always) | `--output-traces` |

`--output-traces` is always set because ITF traces are the output of this operation.

### `Trace.hs`

Parses ITF trace JSON files.

```haskell
-- | Read and parse a single ITF trace file (`.itf.json`).
readTrace :: FilePath -> IO ItfTrace

-- | Find and parse all ITF trace files in an Apalache output directory.
-- Looks for files matching `violation*.itf.json`.
findTraces :: FilePath -> IO [ItfTrace]
```

#### ITF JSON Format

Example ITF trace file produced by Apalache:

```json
{
  "#meta": {
    "format": "ITF",
    "format-description": "https://apalache-mc.org/docs/adr/015adr-trace.html",
    "description": "Created by Apalache",
    "source": "apalache"
  },
  "vars": ["x", "y"],
  "states": [
    { "x": { "#bigint": "0" }, "y": { "#bigint": "10" } },
    { "x": { "#bigint": "1" }, "y": { "#bigint": "10" } },
    { "x": { "#bigint": "2" }, "y": { "#bigint": "5"  } }
  ]
}
```

**Key observations about ITF encoding:**
- Big integers use `{ "#bigint": "123" }` wrappers
- Booleans are JSON `true`/`false`
- Strings are JSON strings
- Sets are JSON arrays (e.g. `[1, 2, 3]`)
- Tuples use `[ { "#tup": 0 }, { "#tup": 1 } ]`
- Records use JSON objects with field names as keys
- Each state is a JSON object mapping variable names to values
- The `#meta` key in states and the top-level `#meta` should be filtered out

#### Aeson JSON Instances

`Value` will need `FromJSON`/`ToJSON` instances. The `FromJSON` instance must handle the `#bigint`, `#tup`, and other special encodings:

```haskell
instance FromJSON Value where
  parseJSON (Object o)
    | Just (String n) <- lookup "#bigint" o = VInt <$> parseRead n
    | Just (Array a)  <- lookup "#tup" o    = ...  -- tuple encoding
    | otherwise                             = VRecord <$> ...
  parseJSON (Array a)  = VSet <$> ...
  parseJSON (Bool b)   = pure $ VBool b
  parseJSON (String s) = pure $ VStr s
  parseJSON Null       = pure VNull
```

## Dependencies

The following dependencies must be added to `ModelMirrors.cabal` in the library's `build-depends`:

```cabal
build-depends:
    base        ^>=4.22.0.0,
    process     ^>=1.6,          -- subprocess invocation (readProcessWithExitCode)
    aeson       ^>=2.2,          -- JSON parsing for ITF traces
    text        ^>=2.1,          -- Text type
    bytestring  ^>=0.12,         -- ByteString for process I/O
    containers  ^>=0.7,          -- Map for trace states
    directory   ^>=1.3,          -- Finding ITF trace files in output dirs
    filepath    ^>=1.5,          -- Path manipulation
```

## Mapping to Mirror Protocol (README Steps)

| Protocol Step | Module | Function |
|---|---|---|
| 1. Client registers spec + trace config | (IPC layer, later) | Receives `ApalacheConfig` + `TraceGenerationConfig` over IPC |
| 2. Mirror validates spec with Apalache | `Command.hs` | `validateSpec` → `Either ApalacheError ValidateResult` |
| 3. Mirror generates ITF traces | `Command.hs` | `generateTraces` → `Either ApalacheError TraceGenerationResult` |
| 4-8. Mirror replays traces step-by-step | `Trace.hs` | `findTraces` / `readTrace` feed `ItfTrace` into replay loop |
| 9. Report correctness | (IPC layer, later) | Sends result back to client |

## Exposed Module

All three modules will be re-exported from a single top-level module:

```haskell
-- src/Apalache.hs
module Apalache
  ( module Apalache.Types
  , module Apalache.Command
  , module Apalache.Trace
  ) where

import Apalache.Types
import Apalache.Command
import Apalache.Trace
```

This module will be added to `exposed-modules` in the cabal file.

## Edge Cases

| Scenario | Handling |
|---|---|
| `apalache-mc` not installed | `readProcessWithExitCode` throws `IOException` → `Left (ApalacheError "...")` |
| Spec has parse/type errors (validate) | `typecheck` exits non-zero → `Right (SpecInvalid <message>)` |
| Spec has parse/type errors (generate) | `check` exits non-zero before trace writing → `Left (ApalacheError <message>)` |
| Spec is sound but no violation (generate) | Apalache writes example traces with `--output-traces` → `Right (TracesGenerated traces)` |
| Output directory contains no ITF traces | `findTraces` returns `[]` → `Left (ApalacheError "no trace files found")` |
| ITF trace JSON is malformed | `readTrace` throws; `generateTraces` catches and wraps → `Left (ApalacheError "...")` |
| Very long `lengthBound` (e.g. 100) | Apalache may run indefinitely; future addition: optional timeout via `System.Timeout` |
