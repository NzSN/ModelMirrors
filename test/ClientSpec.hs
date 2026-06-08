module ClientSpec (spec) where

import Apalache.Command (generateTraces)
import Apalache.Types
  ( ApalacheConfig (..)
  , ItfTrace (..)
  , TraceState (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ValidateResult (..)
  , Value (..)
  )
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (forM_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Client (Client (..), cannedClient, fixedClient, hourClockClient, runClient)
import Protocol.Core
import Protocol.Format.Json ()
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertFailure)

spec :: TestTree
spec = testGroup "ClientSpec"
  [ testCorrectClientSucceeds
  , testMismatchDetected
  , testCannedClient
  , testFixedClient
  , testSpecInvalid
  , testHourClock
  ]

awaitResult :: MVar (Either Text ()) -> IO (Either Text ())
awaitResult = takeMVar

forkClient :: Client MockTransport -> ApalacheConfig -> TraceGenerationConfig -> IO (MVar (Either Text ()))
forkClient client apCfg' tc' = do
  mv <- newEmptyMVar
  _ <- forkIO $ runClient client apCfg' tc' >>= putMVar mv
  pure mv

x0 :: Map Text Value
x0 = Map.singleton (T.pack "x") (VInt 0)

x1 :: Map Text Value
x1 = Map.singleton (T.pack "x") (VInt 1)

config :: TraceGenerationConfig
config = TraceGenerationConfig 1 Nothing

apCfg :: ApalacheConfig
apCfg = ApalacheConfig "spec.tla" Nothing Nothing Nothing (T.pack "Inv") 10 T.empty

testCorrectClientSucceeds :: TestTree
testCorrectClientSucceeds = testCase "correct client succeeds" $ do
  (cEnd, mEnd) <- newMockTransport
  client <- cannedClient cEnd [x0, x1]
  mv <- forkClient client apCfg config
  recvMsg mEnd >>= \case
    Right (Register _ _) -> pure ()
    other -> assertFailure $ "expected Register, got " ++ show other
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x0
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x1
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  result @?= Right ()

testMismatchDetected :: TestTree
testMismatchDetected = testCase "mismatch detected" $ do
  (cEnd, mEnd) <- newMockTransport
  let client = fixedClient cEnd (Map.singleton (T.pack "x") (VInt 999))
  mv <- forkClient client apCfg config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init") Map.empty)
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (StepMismatch x0 (Map.singleton (T.pack "x") (VInt 999)))
  result <- awaitResult mv
  case result of
    Left _ -> pure ()
    Right _ -> assertFailure "expected mismatch error, got Right"

testCannedClient :: TestTree
testCannedClient = testCase "cannedClient responses in order" $ do
  (cEnd, mEnd) <- newMockTransport
  let responses = [x0, x1, Map.singleton (T.pack "x") (VInt 2)]
  client <- cannedClient cEnd responses
  mv <- forkClient client apCfg config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x0
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x1
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= Map.singleton (T.pack "x") (VInt 2)
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  result @?= Right ()

testFixedClient :: TestTree
testFixedClient = testCase "fixedClient always returns same state" $ do
  (cEnd, mEnd) <- newMockTransport
  let fixedState = Map.singleton (T.pack "y") (VInt 42)
      client = fixedClient cEnd fixedState
  mv <- forkClient client apCfg config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= fixedState
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance") Map.empty)
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= fixedState
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  result @?= Right ()

testSpecInvalid :: TestTree
testSpecInvalid = testCase "SpecInvalid returned as error" $ do
  (cEnd, mEnd) <- newMockTransport
  let client = fixedClient cEnd Map.empty
  mv <- forkClient client apCfg config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated (SpecInvalid (T.pack "typecheck failed")))
  result <- awaitResult mv
  case result of
    Left e -> e @?= T.pack "typecheck failed"
    Right _ -> assertFailure "expected Left, got Right"

hcApalacheConfig :: ApalacheConfig
hcApalacheConfig = ApalacheConfig
  { specPath      = "test/specs/HourClock.tla"
  , initPredicate = Nothing
  , nextPredicate = Nothing
  , constInit     = Nothing
  , invariant     = T.pack "TraceComplete"
  , lengthBound   = 13
  , paramVarNames = T.empty
  }

hcTraceConfig :: TraceGenerationConfig
hcTraceConfig = TraceGenerationConfig
  { numTraces = 1
  , view      = Nothing
  }

testHourClock :: TestTree
testHourClock = testCase "hourClockClient passes verification" $ do
  traceRes <- generateTraces hcApalacheConfig hcTraceConfig
  case traceRes of
    Left err -> assertFailure $ "generateTraces error: " ++ show err
    Right (GenerationError e) -> assertFailure $ "trace generation error: " ++ show e
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated (trace : _)) -> do
      let states = traceStates trace
      assertFailureIf (null states) "trace has no states"

      (cEnd, mEnd) <- newMockTransport
      client <- hourClockClient cEnd
      mv <- forkClient client hcApalacheConfig hcTraceConfig

      recvMsg mEnd >>= \case
        Right (Register _ _) -> pure ()
        other -> assertFailure $ "expected Register, got " ++ show other

      sendMsg mEnd (SpecValidated SpecValid)

      forM_ (zip [0 :: Int ..] states) $ \(i, ts) -> do
        let action = actionTake ts
            state  = Map.union (parameters ts) (stateVars ts)
        if i == 0
          then sendMsg mEnd (InitialState action state)
          else sendMsg mEnd (NextStep action Map.empty)

        resp <- recvMsg mEnd
        case resp of
          Right (ReportState s) -> stripMeta s @?= stripMeta state
          other -> assertFailure $ "expected ReportState at step " ++ show i ++ ", got " ++ show other

        sendMsg mEnd StepOk

      sendMsg mEnd AllStepsDone
      result <- awaitResult mv
      result @?= Right ()

assertFailureIf :: Bool -> String -> IO ()
assertFailureIf cond msg = if cond then assertFailure msg else pure ()

stripMeta :: Map Text Value -> Map Text Value
stripMeta = Map.filterWithKey (\k _ -> T.length k == 0 || (T.head k /= '#' && k /= T.pack "action_taken"))
