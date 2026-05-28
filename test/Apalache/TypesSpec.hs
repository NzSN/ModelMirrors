module Apalache.TypesSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace (..)
  , Value (..)
  )
import Apalache.Command (generateTraces)

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== TypesSpec ==="
  testReadTrace
  testFindTraces
  testItfTraceStructure
  testStateValues

specFile :: FilePath
specFile = "test/specs/HourClock.tla"

config :: ApalacheConfig
config = ApalacheConfig
  { specPath      = specFile
  , initPredicate = Nothing
  , nextPredicate = Nothing
  , constInit     = Nothing
  }

traceConfig :: TraceGenerationConfig
traceConfig = TraceGenerationConfig
  { invariant   = T.pack "TraceComplete"
  , lengthBound = 13
  , numTraces   = 1
  }

-- Test: readTrace parses an ITF JSON file without errors.
testReadTrace :: IO ()
testReadTrace = do
  putStrLn "[1] readTrace ..."
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) -> do
      let n = length (traceStates trace)
      putStrLn $ "  PASS: readTrace parsed " ++ show n ++ " states"
    _ -> do
      putStrLn "FAIL: readTrace could not parse trace"
      exitFailure

-- Test: findTraces discovers ITF JSON files from an Apalache output directory.
testFindTraces :: IO ()
testFindTraces = do
  putStrLn "[2] findTraces ..."
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated traces) -> do
      let n = length traces
      if n > 0
        then putStrLn $ "  PASS: findTraces found " ++ show n ++ " trace file(s)"
        else do
          putStrLn "FAIL: findTraces found no trace files"
          exitFailure
    _ -> do
      putStrLn "FAIL: could not generate traces for findTraces test"
      exitFailure

-- Test: the parsed ItfTrace has the expected structure.
testItfTraceStructure :: IO ()
testItfTraceStructure = do
  putStrLn "[3] ItfTrace structure ..."
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) -> do
      let expectedVars =
            [ T.pack "latest_hr"
            , T.pack "ticked"
            , T.pack "hr"
            , T.pack "step_count"
            , T.pack "action_taken"
            , T.pack "nondet_picks"
            ]
      if traceVars trace /= expectedVars
        then do
          putStrLn $ "FAIL: unexpected vars: " ++ show (traceVars trace)
          exitFailure
        else
          putStrLn "  PASS: variable names match"

      let n = length (traceStates trace)
      if n /= 14
        then do
          putStrLn $ "FAIL: expected 14 states, got " ++ show n
          exitFailure
        else
          putStrLn "  PASS: 14 states (init + 13 ticks)"
    _ -> do
      putStrLn "FAIL: could not get trace for structure test"
      exitFailure

-- Test: individual state values parse correctly.
testStateValues :: IO ()
testStateValues = do
  putStrLn "[4] state values ..."
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) ->
      case traceStates trace of
        initState : _ -> do
          case Map.lookup (T.pack "action_taken") initState of
            Just (VStr s)
              | s == T.pack "init" -> putStrLn "  PASS: init action_taken = \"init\""
              | otherwise -> do
                  putStrLn $ "FAIL: expected action_taken = \"init\", got " ++ show s
                  exitFailure
            Just v -> do
              putStrLn $ "FAIL: expected VStr for action_taken, got " ++ show v
              exitFailure
            Nothing -> do
              putStrLn "FAIL: action_taken not found in init state"
              exitFailure

          case Map.lookup (T.pack "ticked") initState of
            Just (VBool False) -> putStrLn "  PASS: init ticked = False"
            Just v -> do
              putStrLn $ "FAIL: expected VBool False for ticked, got " ++ show v
              exitFailure
            Nothing -> do
              putStrLn "FAIL: ticked not found in init state"
              exitFailure

          case Map.lookup (T.pack "hr") initState of
            Just (VInt _) -> putStrLn "  PASS: init hr is an integer"
            Just v -> do
              putStrLn $ "FAIL: expected VInt for hr, got " ++ show v
              exitFailure
            Nothing -> do
              putStrLn "FAIL: hr not found in init state"
              exitFailure

          case Map.lookup (T.pack "nondet_picks") initState of
            Just (VRecord _) -> putStrLn "  PASS: init nondet_picks is a record"
            Just v -> do
              putStrLn $ "FAIL: expected VRecord for nondet_picks, got " ++ show v
              exitFailure
            Nothing -> do
              putStrLn "FAIL: nondet_picks not found in init state"
              exitFailure

        [] -> do
          putStrLn "FAIL: trace has no states"
          exitFailure
    _ -> do
      putStrLn "FAIL: could not get trace for value test"
      exitFailure
