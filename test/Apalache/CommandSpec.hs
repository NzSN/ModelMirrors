module Apalache.CommandSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ValidateResult (..)
  )
import Apalache.Command (validateSpec, generateTraces)

import qualified Data.Text as T
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== CommandSpec ==="
  testValidateSpec
  testGenerateTraces

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

testValidateSpec :: IO ()
testValidateSpec = do
  putStrLn "[1] validateSpec ..."
  result <- validateSpec config 1
  case result of
    Left err -> do
      putStrLn $ "FAIL: validateSpec returned error: " ++ show err
      exitFailure
    Right SpecValid ->
      putStrLn "  PASS: spec is valid"
    Right (SpecInvalid msg) -> do
      putStrLn $ "FAIL: spec is invalid: " ++ show msg
      exitFailure

testGenerateTraces :: IO ()
testGenerateTraces = do
  putStrLn "[2] generateTraces with TraceComplete ..."
  result <- generateTraces config traceConfig
  case result of
    Left err -> do
      putStrLn $ "FAIL: generateTraces returned error: " ++ show err
      exitFailure
    Right (GenerationError msg) -> do
      putStrLn $ "FAIL: trace generation error: " ++ show msg
      exitFailure
    Right (TracesGenerated traces) -> do
      if null traces
        then do
          putStrLn "FAIL: no traces generated"
          exitFailure
        else
          putStrLn $ "  PASS: generated " ++ show (length traces) ++ " trace(s)"
