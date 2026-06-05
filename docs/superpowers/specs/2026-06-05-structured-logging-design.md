# Structured Logging System for ModelMirrors

## Design

### Purpose

Operational observability for the mirror process. Structured JSON-line logs written to stderr and/or file. stdout is the JSON protocol channel and is never touched by logging. Zero new dependencies.

### Module structure

New module: `src/Engine/Log.hs`. No other new files. Changes to existing files are wiring only.

### Data types

```haskell
data Severity = Debug | Info | Warn | Error
  deriving (Show, Eq, Ord, Enum, Bounded, ToJSON, FromJSON)

data LogEntry = LogEntry
  { entryTimestamp :: !UTCTime
  , entrySeverity  :: !Severity
  , entryModule    :: !Text
  , entryMessage   :: !Text
  , entryMetadata  :: ![(Text, Text)]
  }

data LogEnv = LogEnv
  { logThreshold :: !Severity
  , logSinks     :: ![Handle]          -- stderr + optional file handle(s)
  }
```

`LogEntry` has a `ToJSON` instance producing one JSON line:

Timestamps are ISO 8601 with milliseconds, UTC (`formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ"`). Example output line:

```json
{"timestamp":"2026-06-05T10:30:00.123Z","severity":"info","module":"Apalache.Command","message":"trace generation started","metadata":{"invariant":"TraceComplete","length":"13"}}
```

### Functions (Engine.Log)

```haskell
logMsgIO :: LogEnv -> Severity -> Text -> [(Text, Text)] -> IO ()

withLogEnv :: Maybe FilePath -> Severity -> (LogEnv -> IO a) -> IO a
```

`logMsgIO` filters by threshold, formats `LogEntry`, serializes to JSON, and writes to all sinks atomically (`hPutStrLn` + `hFlush` per sink).

`withLogEnv` opens the log file handle (if path given) with `openFile`, brackets the action, and closes the handle on exit. stderr is always included. If the file path is specified but cannot be opened, the process fails with an error message to stderr — fail fast, no silent fallback.

### EngineM changes

Add one method to the existing `EngineM` typeclass in `Engine/Replay.hs`:

```haskell
class EngineM m where
  onStepResult :: StepResult -> m ()
  logMsg       :: Severity -> Text -> [(Text, Text)] -> m ()
```

The IO instance (`stdioJSONDriver` in `Engine/Interactive.hs`) is extended to accept `LogEnv` and dispatch `logMsgIO` calls. Signature becomes:

```haskell
stdioJSONDriver :: LogEnv -> StateDriver IO
```

`StateDriver` is unchanged.

Functions that use `EngineM m` (notably `replayTrace`) get `logMsg` calls through the constraint with no signature changes.

### Pre-engine logging

`validateSpec` and `generateTraces` in `Apalache.Command.hs` don't use `EngineM`. They receive `LogEnv` directly as an additional parameter and call `logMsgIO`:

```haskell
generateTraces :: LogEnv -> ApalacheConfig -> TraceGenerationConfig -> IO (...)
validateSpec   :: LogEnv -> ApalacheConfig -> Int -> IO (...)
```

### Log points

Pre-engine (`Apalache.Command`):

| Event | Severity | Metadata |
|---|---|---|
| typecheck invoked | Info | spec path |
| typecheck/check failed | Error | exit code, output |
| trace generation invoked | Info | invariant, length, count |
| trace generation failed (no output dir) | Error | apalache output |
| trace generation failed (no traces) | Error | output directory |
| traces generated | Info | trace count |

Engine (`Engine.Interactive`):

| Event | Severity | Metadata |
|---|---|---|
| step started | Debug | action, step index |
| unexpected protocol message | Warn | raw message content |
| step ok | Debug | — |
| state mismatch | Debug | diff summary |

I/O layer (`Protocol.Transport.Stdio`):

| Event | Severity | Metadata |
|---|---|---|
| stdin read IOException | Warn | exception message |

Trace parsing (`Apalache.Trace`):

| Event | Severity | Metadata |
|---|---|---|
| .itf.json parse failure | Warn | file path |

### Configuration

The mirror process is short-lived (one invocation per spec). Logging config comes from CLI flags or environment variables, not from the protocol `Register` message:

- `--log-file PATH` or `MODELMIRROR_LOG_FILE` — write logs to file (optional)
- `--log-level LEVEL` or `MODELMIRROR_LOG_LEVEL` — `debug` | `info` | `warn` | `error` (default: `info`)

stderr logging is always active regardless of `--log-file`.

### Output channel isolation

- stdout: JSON protocol channel (untouched)
- stderr: structured log output (always)
- file: structured log output (if `--log-file` specified)

### Testing

**EngineSpec (pure):** Create a test `EngineM` instance backed by an `IORef [LogEntry]`. Run `replayTrace` with a test trace and verify log entries appear at correct steps with correct metadata. No subprocess, no I/O.

**Integration test (MainSpec):** Pass `--log-file` to a temp file. Run a full `runMirror` test. Verify the file exists, contains valid JSON lines, and minimally has an `info` entry for trace generation.

### Non-goals

- No log rotation (process is too short-lived)
- No structured event types (free-form message + metadata is sufficient)
- No metrics, no telemetry, no sampling
- No log shipping (file + stderr only)
- No changes to `Protocol.Client` (client-side logging is out of scope)
