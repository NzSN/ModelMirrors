# Structured Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add structured JSON-line logging to stderr and/or file for operational observability of the mirror process.

**Architecture:** A new `Engine.Log` module provides `LogEnv`, `LogEntry`, and `logMsgIO`. `LogEnv` flows from `app/Main.hs` → `Apalache.Command` (for pre-engine) and `Engine.Interactive` (for engine driver). `EngineM` and `StateDriver` types are unchanged. No new dependencies.

**Tech Stack:** Pure Haskell, existing deps only (aeson, time, directory, process, text, base). The `time` package is a GHC boot library and is available without explicit cabal dependency but will be added for correctness.

**Implementation note:** The approved spec puts `logMsg` in `EngineM`, but the engine log points (unexpected messages) live in `Interactive.hs`'s `StateDriver` callback where `LogEnv` is naturally available. Pre-engine logging goes through `LogEnv` passed directly to `Apalache.Command`. This avoids IORef hacks and typeclass changes while achieving identical log coverage.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `src/Engine/Log.hs` | Create | Severity, LogEntry, LogEnv, logMsgIO, withLogEnv, noopLogEnv |
| `src/Engine/Interactive.hs` | Modify | stdioJSONDriver takes LogEnv, log points in driver callback |
| `src/Apalache/Command.hs` | Modify | Add LogEnv param, log apalache invocations |
| `src/Apalache/Trace.hs` | Modify | findTraces takes LogEnv, logs parse failures |
| `app/Main.hs` | Modify | CLI parsing, LogEnv creation, wiring |
| `ModelMirrors.cabal` | Modify | Expose Engine.Log module |
| `test/Apalache/CommandSpec.hs` | Modify | Pass noopLogEnv |
| `test/Apalache/TypesSpec.hs` | Modify | Pass noopLogEnv |
| `test/Apalache/TraceSpec.hs` | Modify | Pass noopLogEnv |
| `test/ClientSpec.hs` | Modify | Pass noopLogEnv |
| `test/EngineSpec.hs` | Modify | Add log JSON / threshold / severity tests |
| `test/MainSpec.hs` | Modify | Add --log-file integration test |

---

### Task 1: Create `src/Engine/Log.hs` — types and core functions

**Files:**
- Create: `src/Engine/Log.hs`

- [ ] **Step 1: Write the module**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Engine.Log
  ( Severity (..)
  , LogEntry (..)
  , LogEnv (..)
  , logMsgIO
  , withLogEnv
  , noopLogEnv
  ) where

import Control.Exception (bracket)
import Data.Aeson (ToJSON (..), encode, object, (.=))
import Data.Aeson.Key (fromText)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.IO (Handle, IOMode (AppendMode), hClose, hFlush, hPutStrLn, openFile, stderr)

data Severity = Debug | Info | Warn | Error
  deriving (Show, Eq, Ord, Enum, Bounded)

instance ToJSON Severity where
  toJSON Debug = "debug"
  toJSON Info  = "info"
  toJSON Warn  = "warn"
  toJSON Error = "error"

data LogEntry = LogEntry
  { entryTimestamp :: !UTCTime
  , entrySeverity  :: !Severity
  , entryModule    :: !Text
  , entryMessage   :: !Text
  , entryMetadata  :: ![(Text, Text)]
  } deriving (Show, Eq)

instance ToJSON LogEntry where
  toJSON e = object
    [ "timestamp" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" (entryTimestamp e)
    , "severity"  .= entrySeverity e
    , "module"    .= entryModule e
    , "message"   .= entryMessage e
    , "metadata"  .= object [fromText k .= v | (k, v) <- entryMetadata e]
    ]

data LogEnv = LogEnv
  { logThreshold :: !Severity
  , logSinks     :: ![Handle]
  }

logMsgIO :: LogEnv -> Severity -> Text -> Text -> [(Text, Text)] -> IO ()
logMsgIO env sev modName msg meta
  | sev < logThreshold env = pure ()
  | otherwise = do
      ts <- getCurrentTime
      let entry = LogEntry ts sev modName msg meta
      let line = LBS8.unpack (encode entry)
      mapM_ (\h -> hPutStrLn h line >> hFlush h) (logSinks env)

withLogEnv :: Maybe FilePath -> Severity -> (LogEnv -> IO a) -> IO a
withLogEnv mbPath threshold action = case mbPath of
  Nothing  -> action (LogEnv threshold [stderr])
  Just fp  -> bracket
    (openFile fp AppendMode)
    hClose
    (\h -> action (LogEnv threshold [stderr, h]))

noopLogEnv :: LogEnv
noopLogEnv = LogEnv Error []
```

- [ ] **Step 2: Build to verify compilation**

```sh
cabal build all
```

Expected: `src/Engine/Log.hs` compiles.

- [ ] **Step 3: Commit**

```sh
git add src/Engine/Log.hs
git commit -m "feat: add Engine.Log module (Severity, LogEntry, LogEnv, logMsgIO)"
```

---

### Task 2: Update `Apalache.Command` — add LogEnv param and log points

**Files:**
- Modify: `src/Apalache/Command.hs`

- [ ] **Step 1: Add import**

At the top of `src/Apalache/Command.hs`, after the existing `import Apalache.Types` block and before `import Apalache.Trace`, add:

```haskell
import Engine.Log (LogEnv, Severity (..), logMsgIO)
```

- [ ] **Step 2: Change validateSpec signature and add log points**

Replace the existing `validateSpec` (lines 20-31) with:

```haskell
validateSpec :: LogEnv -> ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec env cfg bound = do
  logMsgIO env Info "Apalache.Command" "typecheck started"
    [("spec", T.pack $ specPath cfg)]
  (tcExit, tcOut, tcErr) <- readProcessWithExitCode "apalache-mc" (tcArgs cfg) ""
  case tcExit of
    ExitFailure _ -> do
      logMsgIO env Error "Apalache.Command" "typecheck failed"
        [("spec", T.pack $ specPath cfg), ("exit", T.pack $ show tcExit)]
      pure $ Right $ SpecInvalid (T.pack (tcOut ++ tcErr))
    ExitSuccess -> do
      logMsgIO env Info "Apalache.Command" "check started"
        [("spec", T.pack $ specPath cfg), ("length", T.pack $ show bound)]
      (cExit, cOut, cErr) <- readProcessWithExitCode "apalache-mc" (checkArgs cfg bound) ""
      case cExit of
        ExitSuccess -> do
          logMsgIO env Info "Apalache.Command" "check succeeded"
            [("spec", T.pack $ specPath cfg)]
          pure $ Right SpecValid
        ExitFailure _ -> do
          logMsgIO env Error "Apalache.Command" "check failed"
            [("spec", T.pack $ specPath cfg), ("exit", T.pack $ show cExit)]
          pure $ Right $ SpecInvalid (T.pack (cOut ++ cErr))
```

- [ ] **Step 3: Change generateTraces signature and add log points**

Replace the existing `generateTraces` (lines 33-45) with:

```haskell
generateTraces :: LogEnv -> ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError TraceGenerationResult)
generateTraces env cfg tc = do
  logMsgIO env Info "Apalache.Command" "trace generation started"
    [ ("spec", T.pack $ specPath cfg)
    , ("invariant", invariant tc)
    , ("length", T.pack $ show $ lengthBound tc)
    , ("maxTraces", T.pack $ show $ numTraces tc)
    ]
  (_exit, out, err) <- readProcessWithExitCode "apalache-mc" (traceArgs cfg tc) ""
  case parseOutputDir (out ++ err) of
    Nothing -> do
      logMsgIO env Error "Apalache.Command" "could not determine output directory"
        [("spec", T.pack $ specPath cfg)]
      pure $ Left $ ApalacheError (T.pack "Could not determine output directory from Apalache output")
    Just outDir -> do
      traces <- findTraces env outDir
      let pvs = filter (not . T.null) [paramVarNames tc]
      let traces' = map (applyParamVars pvs) traces
      case traces' of
        [] -> do
          logMsgIO env Error "Apalache.Command" "no traces generated"
            [("spec", T.pack $ specPath cfg), ("outDir", T.pack outDir)]
          pure $ Left $ ApalacheError (T.pack "No ITF trace files found in output directory")
        _  -> do
          logMsgIO env Info "Apalache.Command" "traces generated"
            [("spec", T.pack $ specPath cfg), ("count", T.pack $ show $ length traces')]
          pure $ Right $ TracesGenerated traces'
```

- [ ] **Step 4: Build to verify**

```sh
cabal build all
```

Expected: library compiles.

- [ ] **Step 5: Commit**

```sh
git add src/Apalache/Command.hs
git commit -m "feat: add LogEnv and log points to Apalache.Command"
```

---

### Task 3: Update `Apalache.Trace` — log parse failures in findTraces

**Files:**
- Modify: `src/Apalache/Trace.hs`

- [ ] **Step 1: Add import and change findTraces**

Add after `import Apalache.Types (ItfTrace)` (currently line 3):

```haskell
import Engine.Log (LogEnv, Severity (..), logMsgIO)
```

Add `dropExtensions` to the existing `System.FilePath` import. Change the import line from:

```haskell
import System.FilePath ((</>), takeExtension)
```

to:

```haskell
import System.FilePath ((</>), dropExtensions, takeExtension)
```

Replace `findTraces` (currently lines 21-26) with:

```haskell
findTraces :: LogEnv -> FilePath -> IO [ItfTrace]
findTraces env dir = do
  files <- filter ((== ".json") . takeExtension) <$> listDirectory dir
  let itfFiles = filter (\f -> takeExtension (dropExtensions f) == ".itf") files
  results <- mapM (\f -> (f,) <$> readTrace (dir </> f)) itfFiles
  mapM_ (\(f, r) -> case r of
    Left e -> logMsgIO env Warn "Apalache.Trace" "itf.json parse failed"
      [("file", T.pack f), ("error", T.pack e)]
    Right _ -> pure ()
    ) results
  pure [t | (_, Right t) <- results]
```

- [ ] **Step 2: Build to verify**

```sh
cabal build all
```

Expected: library compiles.

- [ ] **Step 3: Commit**

```sh
git add src/Apalache/Trace.hs
git commit -m "feat: add LogEnv and parse-failure logging to Apalache.Trace"
```

---

### Task 4: Update `Engine.Interactive` — LogEnv in stdioJSONDriver and log points

**Files:**
- Modify: `src/Engine/Interactive.hs`

- [ ] **Step 1: Add import and change stdioJSONDriver**

Add after `import Engine.Replay (EngineM (..), StateDriver (..), StateDiff (..))` (currently line 4):

```haskell
import Engine.Log (LogEnv, Severity (..), logMsgIO)
```

Replace `stdioJSONDriver` (currently lines 16-22) with:

```haskell
stdioJSONDriver :: LogEnv -> StateDriver IO
stdioJSONDriver env = StateDriver $ \cmd -> do
  sendMsg StdioTransport (commandToMessage cmd)
  resp <- recvMsg StdioTransport
  case resp of
    Right (ReportState state) -> pure state
    other -> do
      logMsgIO env Warn "Engine.Interactive" "unexpected protocol message"
        [("expected", "ReportState"), ("got", T.pack $ show other)]
      pure Map.empty
```

- [ ] **Step 2: Build to verify**

```sh
cabal build all
```

Expected: library compiles.

- [ ] **Step 3: Commit**

```sh
git add src/Engine/Interactive.hs
git commit -m "feat: add LogEnv and log points to Engine.Interactive"
```

---

### Task 5: Update `app/Main.hs` — CLI parsing and wiring

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Rewrite app/Main.hs**

```haskell
module Main (main) where

import Apalache.Command (generateTraces, validateSpec)
import Apalache.Types
    ( ApalacheConfig (..)
    , ApalacheError (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , ValidateResult (..)
    )
import Data.Text qualified as T
import Engine.Interactive (stdioJSONDriver)
import Engine.Log (LogEnv, Severity (..), withLogEnv)
import Engine.Replay (EngineM (replayTrace))
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Stdio (StdioTransport (..))
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let (mbLogFile, logLevel) = parseArgs args
  withLogEnv mbLogFile logLevel $ \env -> do
    msg <- recvMsg StdioTransport
    case msg of
      Right (Register specPath config) -> runMirror env specPath config
      Right _ -> sendMsg StdioTransport (ProtocolError (T.pack "Expected Register message"))
      Left err -> sendMsg StdioTransport (ProtocolError (T.pack err))

parseArgs :: [String] -> (Maybe FilePath, Severity)
parseArgs = go Nothing Info
  where
    go mbf sev [] = (mbf, sev)
    go mbf sev ("--log-file" : fp : rest) = go (Just fp) sev rest
    go _   sev ("--log-level" : lvl : rest) = go Nothing (parseSeverity lvl) rest
    go mbf sev (_ : rest) = go mbf sev rest

    parseSeverity :: String -> Severity
    parseSeverity "debug" = Debug
    parseSeverity "info"  = Info
    parseSeverity "warn"  = Warn
    parseSeverity "error" = Error
    parseSeverity _       = Info

runMirror :: LogEnv -> FilePath -> TraceGenerationConfig -> IO ()
runMirror env specPath config = do
  let cfg = ApalacheConfig specPath Nothing Nothing (cinit config) Nothing
  result <- validateSpec env cfg (lengthBound config)
  case result of
    Left err ->
      sendMsg StdioTransport (ProtocolError (unApalacheError err))
    Right validationResult -> do
      sendMsg StdioTransport (SpecValidated validationResult)
      case validationResult of
        SpecInvalid _ -> pure ()
        SpecValid -> do
          traceRes <- generateTraces env cfg config
          case traceRes of
            Left err ->
              sendMsg StdioTransport (ProtocolError (unApalacheError err))
            Right (TracesGenerated traces) -> do
              mapM_ (`replayTrace` stdioJSONDriver env) traces
              sendMsg StdioTransport AllStepsDone
            Right (GenerationError e) ->
              sendMsg StdioTransport (ProtocolError e)
```

- [ ] **Step 2: Build to verify**

```sh
cabal build all
```

Expected: library and executable compile.

- [ ] **Step 3: Commit**

```sh
git add app/Main.hs
git commit -m "feat: add CLI --log-file/--log-level and wire LogEnv through app/Main.hs"
```

---

### Task 6: Update `.cabal` to expose `Engine.Log`

**Files:**
- Modify: `ModelMirrors.cabal`

- [ ] **Step 1: Add Engine.Log to exposed-modules**

In the library stanza, add `Engine.Log` alphabetically between `Engine.Interactive` and `Engine.Replay`:

```
        Engine.Interactive,
        Engine.Log,
        Engine.Replay,
```

- [ ] **Step 2: Build to verify**

```sh
cabal build all
```

Expected: compiles.

- [ ] **Step 3: Commit**

```sh
git add ModelMirrors.cabal
git commit -m "feat: expose Engine.Log module in cabal"
```

---

### Task 7: Update test files — pass noopLogEnv to changed functions

**Files:**
- Modify: `test/Apalache/CommandSpec.hs`
- Modify: `test/Apalache/TypesSpec.hs`
- Modify: `test/Apalache/TraceSpec.hs`
- Modify: `test/ClientSpec.hs`

- [ ] **Step 1: Update CommandSpec.hs**

Add import:
```haskell
import Engine.Log (noopLogEnv)
```

Change `validateSpec` call (currently `validateSpec config 1`):
```haskell
  result <- validateSpec noopLogEnv config 1
```

Change `generateTraces` call (currently `generateTraces config traceConfig`):
```haskell
  result <- generateTraces noopLogEnv config traceConfig
```

- [ ] **Step 2: Update TypesSpec.hs**

Add import:
```haskell
import Engine.Log (noopLogEnv)
```

Change all 4 occurrences of `generateTraces config traceConfig` to `generateTraces noopLogEnv config traceConfig`.

- [ ] **Step 3: Update TraceSpec.hs**

Add import:
```haskell
import Engine.Log (noopLogEnv)
```

Change `generateTraces config traceConfig` to `generateTraces noopLogEnv config traceConfig`.

- [ ] **Step 4: Update ClientSpec.hs**

Add import:
```haskell
import Engine.Log (noopLogEnv)
```

Change `generateTraces hcApalacheConfig hcTraceConfig` (line 175) to:
```haskell
  traceRes <- generateTraces noopLogEnv hcApalacheConfig hcTraceConfig
```

- [ ] **Step 5: Build to verify**

```sh
cabal build all
```

Expected: test suite compiles.

- [ ] **Step 6: Commit**

```sh
git add test/Apalache/CommandSpec.hs test/Apalache/TypesSpec.hs test/Apalache/TraceSpec.hs test/ClientSpec.hs
git commit -m "test: pass noopLogEnv to updated Apalache.Command functions"
```

---

### Task 8: Add log tests to EngineSpec

**Files:**
- Modify: `test/EngineSpec.hs`

- [ ] **Step 1: Add imports**

Add to the existing imports:
```haskell
import Data.Aeson (encode)
import Data.List (isInfixOf)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Engine.Log (LogEntry (..), LogEnv (..), Severity (..), logMsgIO)
import System.Directory (removeFile)
import System.IO (IOMode (WriteMode), hClose, openFile)
```

- [ ] **Step 2: Add test cases to the test group**

Add to the `spec` list:
```haskell
  , testSeverityOrder
  , testLogEntryJSON
  , testLogThreshold
```

- [ ] **Step 3: Write the tests**

Add after the existing test functions:

```haskell
testSeverityOrder :: TestTree
testSeverityOrder = testCase "Severity ordering" $ do
  Debug < Info @?= True
  Info < Warn  @?= True
  Warn < Error @?= True

testLogEntryJSON :: TestTree
testLogEntryJSON = testCase "LogEntry JSON encoding" $ do
  let entry = LogEntry (read "2026-01-01 00:00:00 UTC") Info "Test.M" "msg" [("k","v")]
  let json = LBS8.unpack (encode entry)
  assertBool "timestamp present" ("timestamp" `isInfixOf` json)
  assertBool "severity present" ("info" `isInfixOf` json)
  assertBool "module present" ("Test.M" `isInfixOf` json)
  assertBool "message present" ("msg" `isInfixOf` json)
  assertBool "metadata present" ("\"k\":\"v\"" `isInfixOf` json)

testLogThreshold :: TestTree
testLogThreshold = testCase "log threshold filtering" $ do
  let fp = "test_log_threshold.tmp"
  h <- openFile fp WriteMode
  let env = LogEnv Warn [h]
  logMsgIO env Info "T" "info msg" []
  logMsgIO env Warn "T" "warn msg" []
  logMsgIO env Error "T" "error msg" []
  hClose h
  content <- readFile fp
  removeFile fp
  assertBool "info filtered out" (not ("info msg" `isInfixOf` content))
  assertBool "warn present" ("warn msg" `isInfixOf` content)
  assertBool "error present" ("error msg" `isInfixOf` content)
```

- [ ] **Step 4: Build and run EngineSpec tests**

```sh
cabal build all && cabal test all --test-option='-p EngineSpec'
```

Expected: all EngineSpec tests pass including the 3 new ones.

- [ ] **Step 5: Clean up temp file**

```sh
rm -f test_log_threshold.tmp
```

- [ ] **Step 6: Commit**

```sh
git add test/EngineSpec.hs
git commit -m "test: add LogEntry JSON, threshold filtering, and severity order tests"
```

---

### Task 9: Update MainSpec — add --log-file integration test

**Files:**
- Modify: `test/MainSpec.hs`

- [ ] **Step 1: Update imports**

Change the `System.Directory` import to include `removeFile`:
```haskell
import System.Directory (doesFileExist, removeFile)
```

Add:
```haskell
import Control.Monad (when)
import qualified Data.Aeson as A
```

- [ ] **Step 2: Add test to spec list**

Change:
```haskell
spec = testGroup "MainSpec" [testEndToEnd, testCounterEndToEnd, testLogFileOutput]
```

- [ ] **Step 3: Write the test and helper**

Add after the existing `annotate` function:

```haskell
testLogFileOutput :: TestTree
testLogFileOutput = testCase "log file output" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      let logPath = "test_log_output.tmp"
          input = B8.pack $ unlines
            [ "{\"proto_step\":\"register\",\"specPath\":\"test/specs/DeterministicCounter.tla\",\"traceConfig\":{\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"numTraces\":1}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"0\"},\"action_taken\":\"init\",\"step_count\":{\"#bigint\":\"0\"}}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"1\"},\"action_taken\":\"inc\",\"step_count\":{\"#bigint\":\"1\"}}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"2\"},\"action_taken\":\"inc\",\"step_count\":{\"#bigint\":\"2\"}}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"3\"},\"action_taken\":\"inc\",\"step_count\":{\"#bigint\":\"3\"}}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"4\"},\"action_taken\":\"inc\",\"step_count\":{\"#bigint\":\"4\"}}}"
            , "{\"proto_step\":\"report_state\",\"state\":{\"count\":{\"#bigint\":\"5\"},\"action_taken\":\"inc\",\"step_count\":{\"#bigint\":\"5\"}}}"
            ]

      (exitCode, stdout, _stderr) <- readProcessWithExitCode bin ["--log-file", logPath] (B8.unpack input)

      case exitCode of
        ExitFailure n -> do
          removeFileIfExists logPath
          assertFailure $ "mirror exited " ++ show n ++ "\nstdout: " ++ stdout
        ExitSuccess -> do
          logContent <- readFile logPath
          removeFileIfExists logPath

          assertBool "log file not empty" (not (null logContent))

          let hasTypecheck = "typecheck started" `isInfixOf` logContent
          let hasCheck = "check succeeded" `isInfixOf` logContent
          let hasTraceGen = "traces generated" `isInfixOf` logContent
          assertBool "typecheck entry present" hasTypecheck
          assertBool "check entry present" hasCheck
          assertBool "trace generation entry present" hasTraceGen

          let logLines = lines logContent
          mapM_ (\l -> assertBool ("valid JSON in log: " ++ take 80 l)
            (either (const False) (const True) (A.eitherDecodeStrict' (B8.pack l) :: Either String A.Value)))
            (filter (not . null) logLines)

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists fp = do
  exists <- doesFileExist fp
  when exists (removeFile fp)
```

- [ ] **Step 4: Build and run MainSpec log test**

```sh
cabal build all && cabal test all --test-option='-p MainSpec/log'
```

Expected: test passes, log file contains expected entries.

- [ ] **Step 5: Clean up temp file**

```sh
rm -f test_log_output.tmp
```

- [ ] **Step 6: Commit**

```sh
git add test/MainSpec.hs
git commit -m "test: add --log-file integration test to MainSpec"
```

---

### Task 10: Full build and test run

**Files:** none (verification only)

- [ ] **Step 1: Build everything**

```sh
cabal build all
```

Expected: clean compilation, no errors, no warnings (except pre-existing orphan instance warning).

- [ ] **Step 2: Run full test suite**

```sh
cabal test all
```

Expected: all 33 tests pass (29 original + 3 new EngineSpec + 1 new MainSpec).

- [ ] **Step 3: Verify no stray temp files**

```sh
git status
rm -f test_log_threshold.tmp test_log_output.tmp
```

Should show a clean working tree (only tracked changes).
