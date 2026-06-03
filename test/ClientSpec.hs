module ClientSpec (spec) where

import Apalache.Types (TraceGenerationConfig (..), ValidateResult (..), Value (..))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Client (Client (..), cannedClient, fixedClient, runClient)
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
  ]

awaitResult :: MVar (Either Text ()) -> IO (Either Text ())
awaitResult = takeMVar

forkClient :: Client MockTransport -> FilePath -> TraceGenerationConfig -> IO (MVar (Either Text ()))
forkClient client specPath tc = do
  mv <- newEmptyMVar
  _ <- forkIO $ runClient client specPath tc >>= putMVar mv
  pure mv

x0 :: Map Text Value
x0 = Map.singleton (T.pack "x") (VInt 0)

x1 :: Map Text Value
x1 = Map.singleton (T.pack "x") (VInt 1)

config :: TraceGenerationConfig
config = TraceGenerationConfig (T.pack "Inv") 10 1

testCorrectClientSucceeds :: TestTree
testCorrectClientSucceeds = testCase "correct client succeeds" $ do
  (cEnd, mEnd) <- newMockTransport
  client <- cannedClient cEnd [x0, x1]
  mv <- forkClient client "spec.tla" config
  recvMsg mEnd >>= \case
    Right (Register _ _) -> pure ()
    other -> assertFailure $ "expected Register, got " ++ show other
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x0
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
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
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
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
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x0
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= x1
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
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
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> s @?= fixedState
    other -> assertFailure $ "expected ReportState, got " ++ show other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
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
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated (SpecInvalid (T.pack "typecheck failed")))
  result <- awaitResult mv
  case result of
    Left e -> e @?= T.pack "typecheck failed"
    Right _ -> assertFailure "expected Left, got Right"
