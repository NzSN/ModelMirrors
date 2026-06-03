module EngineSpec (spec) where

import Apalache.Types (ItfTrace (..), TraceState (..), Value (..))
import Engine.Core (traceSteps, diffState)
import Engine.Replay (EngineM (..), StateDriver (..))
import Engine.Types (Step (..), StepCommand (..), StateDiff (..), VarDiff (..))

import Data.Functor.Identity (runIdentity)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool, assertFailure)

spec :: TestTree
spec = testGroup "EngineSpec"
  [ testTraceStepsEmpty
  , testTraceStepsOne
  , testTraceStepsTwo
  , testDiffEmptyMaps
  , testDiffIdentical
  , testDiffValueMismatch
  , testDiffMissingVar
  , testDiffExtraVar
  , testDiffMixed
  , testReplayEmpty
  , testReplayAllMatch
  , testReplayFirstMismatch
  , testReplaySecondMismatch
  ]

----------------------------------------------------------------------
-- traceSteps tests

testTraceStepsEmpty :: TestTree
testTraceStepsEmpty = testCase "traceSteps empty" $ do
  let trace = ItfTrace [] [] Map.empty []
  assertBool "empty trace yields empty list" (null (traceSteps trace))

testTraceStepsOne :: TestTree
testTraceStepsOne = testCase "traceSteps single state" $ do
  let s0 = TraceState (T.pack "init") Map.empty (Map.singleton (T.pack "x") (VInt 1))
      trace = ItfTrace [T.pack "x"] [] Map.empty [s0]
  case traceSteps trace of
    [Step 0 act params m] -> do
      act @?= T.pack "init"
      params @?= Map.empty
      m @?= Map.fromList [(T.pack "action_taken", VStr (T.pack "init")), (T.pack "x", VInt 1)]
    other -> assertFailure $ "expected one step, got " ++ show (length other)

testTraceStepsTwo :: TestTree
testTraceStepsTwo = testCase "traceSteps two states" $ do
  let s0 = TraceState (T.pack "init") Map.empty (Map.singleton (T.pack "x") (VInt 1))
      s1 = TraceState (T.pack "advance") Map.empty (Map.singleton (T.pack "x") (VInt 2))
      trace = ItfTrace [T.pack "x"] [] Map.empty [s0, s1]
  case traceSteps trace of
    [Step 0 a0 p0 m0, Step 1 a1 p1 m1] -> do
      a0 @?= T.pack "init"
      p0 @?= Map.empty
      m0 @?= Map.fromList [(T.pack "action_taken", VStr (T.pack "init")), (T.pack "x", VInt 1)]
      a1 @?= T.pack "advance"
      p1 @?= Map.empty
      m1 @?= Map.fromList [(T.pack "action_taken", VStr (T.pack "advance")), (T.pack "x", VInt 2)]
    other -> assertFailure $ "expected two steps, got " ++ show (length other)

----------------------------------------------------------------------
-- diffState tests

testDiffEmptyMaps :: TestTree
testDiffEmptyMaps = testCase "diffState empty maps" $ do
  diffState Map.empty (Map.empty :: Map Text Value) @?= StatesMatch

testDiffIdentical :: TestTree
testDiffIdentical = testCase "diffState identical maps" $ do
  let m = Map.fromList [(T.pack "a", VInt 1), (T.pack "b", VBool True)]
  diffState m m @?= StatesMatch

testDiffValueMismatch :: TestTree
testDiffValueMismatch = testCase "diffState value mismatch" $ do
  let expected = Map.singleton (T.pack "x") (VInt 1)
      actual   = Map.singleton (T.pack "x") (VInt 2)
  diffState expected actual @?=
    StateMismatch expected actual [ValueMismatch (T.pack "x") (VInt 1) (VInt 2)]

testDiffMissingVar :: TestTree
testDiffMissingVar = testCase "diffState missing variable" $ do
  let expected = Map.singleton (T.pack "x") (VInt 1)
  diffState expected Map.empty @?=
    StateMismatch expected Map.empty [MissingVar (T.pack "x") (VInt 1)]

testDiffExtraVar :: TestTree
testDiffExtraVar = testCase "diffState extra variable" $ do
  let s = VStr (T.pack "bonus")
      actual = Map.singleton (T.pack "y") s
  diffState Map.empty actual @?=
    StateMismatch Map.empty actual [ExtraVar (T.pack "y") s]

testDiffMixed :: TestTree
testDiffMixed = testCase "diffState mixed differences" $ do
  let expected = Map.fromList [(T.pack "a", VInt 1), (T.pack "b", VBool True)]
      actual   = Map.fromList [(T.pack "a", VInt 99), (T.pack "c", VStr (T.pack "hello"))]
  case diffState expected actual of
    StateMismatch _ _ diffs -> length diffs @?= 3
    other -> assertFailure $ "expected StateMismatch, got " ++ show other

----------------------------------------------------------------------
-- replayTrace tests

testReplayEmpty :: TestTree
testReplayEmpty = testCase "replayTrace empty" $ do
  let trace = ItfTrace [] [] Map.empty []
      report = StateDriver (\_ -> pure (Map.empty :: Map Text Value))
      result = runIdentity (replayTrace trace report)
  assertBool "empty trace yields empty list" (null result)

testReplayAllMatch :: TestTree
testReplayAllMatch = testCase "replayTrace all match" $ do
  let s0 = TraceState (T.pack "init") Map.empty (Map.singleton (T.pack "x") (VInt 1))
      s1 = TraceState (T.pack "advance") Map.empty (Map.singleton (T.pack "x") (VInt 2))
      trace = ItfTrace [T.pack "x"] [] Map.empty [s0, s1]
      report = StateDriver $ \cmd -> pure $ case cmd of
        CmdInitial _ _ -> (Map.singleton (T.pack "x") (VInt 1) :: Map Text Value)
        CmdNextStep _ _ -> Map.singleton (T.pack "x") (VInt 2)
  runIdentity (replayTrace trace report) @?= [StatesMatch, StatesMatch]

testReplayFirstMismatch :: TestTree
testReplayFirstMismatch = testCase "replayTrace first mismatch" $ do
  let s0 = TraceState (T.pack "init") Map.empty (Map.singleton (T.pack "x") (VInt 1))
      s1 = TraceState (T.pack "advance") Map.empty (Map.singleton (T.pack "x") (VInt 2))
      trace = ItfTrace [T.pack "x"] [] Map.empty [s0, s1]
      report = StateDriver (\_ -> pure (Map.singleton (T.pack "x") (VInt 999)))
  case runIdentity (replayTrace trace report) of
    [StateMismatch{}] -> pure ()
    other -> assertFailure $ "expected [StateMismatch], got " ++ show other

testReplaySecondMismatch :: TestTree
testReplaySecondMismatch = testCase "replayTrace second mismatch" $ do
  let s0 = TraceState (T.pack "init") Map.empty (Map.singleton (T.pack "x") (VInt 1))
      s1 = TraceState (T.pack "advance") Map.empty (Map.singleton (T.pack "x") (VInt 2))
      trace = ItfTrace [T.pack "x"] [] Map.empty [s0, s1]
      report = StateDriver $ \case
        CmdInitial _ _ -> pure (Map.singleton (T.pack "x") (VInt 1))
        CmdNextStep _ _ -> pure (Map.singleton (T.pack "x") (VInt 999))
  case runIdentity (replayTrace trace report) of
    [StatesMatch, StateMismatch{}] -> pure ()
    other -> assertFailure $ "expected [StatesMatch, StateMismatch], got " ++ show other
