module Apalache.TraceSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace (..)
  , TraceState (..)
  )
import Apalache.Command (generateTraces)

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "TraceSpec" [testTraceContents]

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
  { invariant      = T.pack "TraceComplete"
  , lengthBound    = 13
  , numTraces      = 1
  , view           = Nothing
  , cinit          = Nothing
  , paramVarNames  = T.empty
  }

testTraceContents :: TestTree
testTraceContents = testCase "trace contents" $ do
  result <- generateTraces config traceConfig
  case result of
    Right (TracesGenerated (trace : _)) -> do
      let n = length (traceStates trace)
      assertBool "expected at least 2 states" (n >= 2)
      assertBool "no variables in trace" (not (null (traceVars trace)))
      case traceStates trace of
        initState : _ ->
          assertBool "init state missing hr" (Map.member (T.pack "hr") (stateVars initState))
        [] -> assertFailure "trace has no states"
    _ -> assertFailure "could not get trace for contents test"
