module Apalache.TypesSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace (..)
  , TraceState (..)
  , Value (..)
  )
import Apalache.Command (generateTraces)

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool, assertFailure)

spec :: TestTree
spec = testGroup "TypesSpec"
  [ testReadTrace
  , testFindTraces
  , testItfTraceStructure
  , testStateValues
  ]

specFile :: FilePath
specFile = "test/specs/HourClock.tla"

config :: ApalacheConfig
config = ApalacheConfig
  { specPath      = specFile
  , initPredicate = Nothing
  , nextPredicate = Nothing
  , constInit     = Nothing
  , invariant     = T.pack "TraceComplete"
  , lengthBound   = 13
  , paramVarNames = T.empty
  }

traceConfig :: TraceGenerationConfig
traceConfig = TraceGenerationConfig
  { numTraces = 1
  , view      = Nothing
  }

testReadTrace :: TestTree
testReadTrace = testCase "readTrace" $ do
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) -> do
      let n = length (traceStates trace)
      assertBool "readTrace parsed 0 states" (n > 0)
    _ -> assertFailure "could not parse trace"

testFindTraces :: TestTree
testFindTraces = testCase "findTraces" $ do
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated traces) ->
      assertBool "findTraces found no trace files" (length traces > 0)
    _ -> assertFailure "could not generate traces"

testItfTraceStructure :: TestTree
testItfTraceStructure = testCase "ItfTrace structure" $ do
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
      traceVars trace @?= expectedVars
      length (traceStates trace) @?= 14
    _ -> assertFailure "could not get trace for structure test"

testStateValues :: TestTree
testStateValues = testCase "state values" $ do
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) ->
      case traceStates trace of
        initState : _ -> do
          actionTake initState @?= T.pack "init"
          let vars = stateVars initState
          case Map.lookup (T.pack "ticked") vars of
            Just (VBool False) -> pure ()
            Just v -> assertFailure $ "expected VBool False, got " ++ show v
            Nothing -> assertFailure "ticked not found"
          case Map.lookup (T.pack "hr") vars of
            Just (VInt _) -> pure ()
            Just v -> assertFailure $ "expected VInt, got " ++ show v
            Nothing -> assertFailure "hr not found"
          case Map.lookup (T.pack "nondet_picks") vars of
            Just (VRecord _) -> pure ()
            Just v -> assertFailure $ "expected VRecord, got " ++ show v
            Nothing -> assertFailure "nondet_picks not found"
        [] -> assertFailure "trace has no states"
    _ -> assertFailure "could not get trace for value test"
