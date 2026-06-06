module Apalache.CommandSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ValidateResult (..)
  )
import Apalache.Command (validateSpec, generateTraces)

import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "CommandSpec"
  [ testValidateSpec
  , testGenerateTraces
  ]

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

testValidateSpec :: TestTree
testValidateSpec = testCase "validateSpec" $ do
  result <- validateSpec config 1
  case result of
    Left err -> assertFailure $ "validateSpec returned error: " ++ show err
    Right SpecValid -> pure ()
    Right (SpecInvalid msg) -> assertFailure $ "spec is invalid: " ++ show msg

testGenerateTraces :: TestTree
testGenerateTraces = testCase "generateTraces with TraceComplete" $ do
  result <- generateTraces config traceConfig
  case result of
    Left err -> assertFailure $ "generateTraces returned error: " ++ show err
    Right (GenerationError msg) -> assertFailure $ "trace generation error: " ++ show msg
    Right (TracesGenerated traces) ->
      assertBool "no traces generated" (not (null traces))
