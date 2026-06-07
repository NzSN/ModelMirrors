module MirrorStepSpec (spec) where

import Apalache.Types (ItfTrace (..), TraceState (..), Value (..))
import Data.ByteString.Char8 qualified as BSC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (traceSteps)
import Engine.Replay (StateDriver (..))
import Engine.Types (Step (..), StateDiff (..), StepCommand (..), VarDiff (..))
import Protocol.Format.Json ()
import Protocol.Mirror (MirrorStep (..), replaySteps, run)
import Protocol.Transport.Core (Transport (..))
import Protocol.Transport.Mock (newMockTransport)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

spec :: TestTree
spec = testGroup "MirrorStepSpec"
  [ testReplayEmpty
  , testReplaySingleMatch
  , testReplaySingleMismatch
  , testReplayTwoStepsBothMatch
  , testReplayFirstMismatch
  , testRunProtocolError
  ]

mkTrace :: [TraceState] -> ItfTrace
mkTrace states = ItfTrace [T.pack "x"] [] Map.empty states

mkState :: Text -> Map Text Value -> TraceState
mkState action vars = TraceState action Map.empty vars

x1, x2 :: Map Text Value
x1 = Map.singleton (T.pack "x") (VInt 1)
x2 = Map.singleton (T.pack "x") (VInt 2)

--------------------------------------------------------------------------------
-- replaySteps tests

testReplayEmpty :: TestTree
testReplayEmpty = testCase "replaySteps empty trace" $ do
  (_, mirrorEnd) <- newMockTransport
  let driver = StateDriver (const (pure Map.empty))
      trace = ItfTrace [] [] Map.empty []
  steps <- replaySteps mirrorEnd driver trace
  steps @?= []

testReplaySingleMatch :: TestTree
testReplaySingleMatch = testCase "replaySteps single step match" $ do
  (_, mirrorEnd) <- newMockTransport
  let s0 = mkState (T.pack "init") x1
      trace = mkTrace [s0]
      driver = StateDriver $ \cmd -> case cmd of
        CmdInitial _ expected -> pure expected
        _ -> pure Map.empty
  steps_ <- pure (traceSteps trace)
  case steps_ of
    [step] -> do
      let act = stepAct step
          vars = stepVars step
      steps <- replaySteps mirrorEnd driver trace
      steps @?= [ MirrorSendInitialState act vars
                , MirrorRecvReportState 0 act
                , MirrorSendStepOk 0
                ]
    _ -> pure ()

testReplaySingleMismatch :: TestTree
testReplaySingleMismatch = testCase "replaySteps single step mismatch" $ do
  (_, mirrorEnd) <- newMockTransport
  let s0 = mkState (T.pack "init") x1
      trace = mkTrace [s0]
      wrong = Map.singleton (T.pack "x") (VInt 999)
      driver = StateDriver (const (pure wrong))
  steps_ <- pure (traceSteps trace)
  case steps_ of
    [step] -> do
      let act = stepAct step
          vars = stepVars step
          varsFiltered = Map.filterWithKey (\k _ -> k /= T.pack "action_taken") vars
          expectedDiff = StateMismatch varsFiltered wrong
            [ValueMismatch (T.pack "x") (VInt 1) (VInt 999)]
      steps <- replaySteps mirrorEnd driver trace
      case steps of
        [ MirrorSendInitialState a v
          , MirrorRecvReportState 0 a'
          , MirrorSendStepMismatch 0 diff
          ] -> do
          a @?= act
          v @?= vars
          a' @?= act
          diff @?= expectedDiff
        _ -> error $ "unexpected steps: " ++ show steps
    _ -> pure ()

testReplayTwoStepsBothMatch :: TestTree
testReplayTwoStepsBothMatch = testCase "replaySteps two steps both match" $ do
  (_, mirrorEnd) <- newMockTransport
  let s0 = mkState (T.pack "init") x1
      s1 = mkState (T.pack "tick") x2
      trace = mkTrace [s0, s1]
      driver = StateDriver $ \cmd -> case cmd of
        CmdInitial _ expected -> pure expected
        CmdNextStep _ _       -> pure (Map.singleton (T.pack "x") (VInt 2))
  steps_ <- pure (traceSteps trace)
  case steps_ of
    [step0, step1] -> do
      let act0 = stepAct step0
          act1 = stepAct step1
          vars0 = stepVars step0
          params1 = stepParams step1
      steps <- replaySteps mirrorEnd driver trace
      steps @?= [ MirrorSendInitialState act0 vars0
                , MirrorRecvReportState 0 act0
                , MirrorSendStepOk 0
                , MirrorSendNextStep act1 params1
                , MirrorRecvReportState 1 act1
                , MirrorSendStepOk 1
                ]
    _ -> pure ()

testReplayFirstMismatch :: TestTree
testReplayFirstMismatch = testCase "replaySteps stops after first mismatch" $ do
  (_, mirrorEnd) <- newMockTransport
  let s0 = mkState (T.pack "init") x1
      s1 = mkState (T.pack "tick") x2
      trace = mkTrace [s0, s1]
      wrong = Map.singleton (T.pack "x") (VInt 999)
      driver = StateDriver $ \cmd -> case cmd of
        CmdInitial _ _ -> pure wrong
        _ -> pure Map.empty
  steps <- replaySteps mirrorEnd driver trace
  length steps @?= 3
  case steps of
    [MirrorSendInitialState{}, MirrorRecvReportState{}, MirrorSendStepMismatch{}] -> pure ()
    _ -> error $ "unexpected steps: " ++ show steps

--------------------------------------------------------------------------------
-- run tests (no apalache needed for error path)

testRunProtocolError :: TestTree
testRunProtocolError = testCase "run returns ProtocolError for bad message" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  send clientEnd (BSC.pack "bad-json")
  result <- run mirrorEnd
  case result of
    [MirrorSendProtocolError _] -> pure ()
    _ -> error $ "expected [MirrorSendProtocolError _], got " ++ show result
