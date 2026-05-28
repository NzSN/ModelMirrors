module Apalache.TraceSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace (..)
  )
import Apalache.Command (generateTraces)

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== TraceSpec ==="
  testTraceContents

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

testTraceContents :: IO ()
testTraceContents = do
  putStrLn "[1] trace contents ..."
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) -> do
      putStrLn $ "  Variables: " ++ show (traceVars trace)
      putStrLn $ "  States:    " ++ show (length (traceStates trace))
      let n = length (traceStates trace)
      if n < 2
        then do
          putStrLn $ "FAIL: expected at least 2 states, got " ++ show n
          exitFailure
        else
          putStrLn $ "  PASS: trace has " ++ show n ++ " states"

      if null (traceVars trace)
        then do
          putStrLn "FAIL: no variables in trace"
          exitFailure
        else
          putStrLn "  PASS: trace has variables"

      case traceStates trace of
        [] -> do
          putStrLn "FAIL: trace has no states"
          exitFailure
        initState : _ -> do
          case Map.lookup (T.pack "hr") initState of
            Just _ -> putStrLn "  PASS: init state contains 'hr'"
            Nothing -> do
              putStrLn "FAIL: init state missing 'hr'"
              exitFailure
    _ -> do
      putStrLn "FAIL: could not get trace for contents test"
      exitFailure
