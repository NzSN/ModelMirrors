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
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== ClientSpec ==="
  testCorrectClientSucceeds
  testMismatchDetected
  testCannedClient
  testFixedClient
  testSpecInvalid

expect :: (Eq a, Show a) => a -> a -> String -> IO ()
expect actual expected label = do
  if actual == expected
    then putStrLn $ "  PASS: " ++ label
    else do
      putStrLn $ "  FAIL: " ++ label
      putStrLn $ "    expected: " ++ show expected
      putStrLn $ "    got:      " ++ show actual
      exitFailure

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

testCorrectClientSucceeds :: IO ()
testCorrectClientSucceeds = do
  putStrLn "[1] correct client completes successfully"
  (cEnd, mEnd) <- newMockTransport
  client <- cannedClient cEnd [x0, x1]
  mv <- forkClient client "spec.tla" config
  recvMsg mEnd >>= \case
    Right (Register _ _) -> pure ()
    other                -> unexpected "Register" other
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s x0 "client reported initial state"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s x1 "client reported next state"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  expect result (Right ()) "client returned Right ()"

testMismatchDetected :: IO ()
testMismatchDetected = do
  putStrLn "[2] mismatch is detected when client returns wrong state"
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
    Left e  -> putStrLn $ "  PASS: client got error: " ++ T.unpack e
    Right _ -> do
      putStrLn "  FAIL: expected mismatch error"
      exitFailure

testCannedClient :: IO ()
testCannedClient = do
  putStrLn "[3] cannedClient returns pre-canned responses in order"
  (cEnd, mEnd) <- newMockTransport
  let responses = [x0, x1, Map.singleton (T.pack "x") (VInt 2)]
  client <- cannedClient cEnd responses
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s x0 "canned[0]"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s x1 "canned[1]"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s (Map.singleton (T.pack "x") (VInt 2)) "canned[2]"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  expect result (Right ()) "canned client completed"

testFixedClient :: IO ()
testFixedClient = do
  putStrLn "[4] fixedClient always returns the same state"
  (cEnd, mEnd) <- newMockTransport
  let fixedState = Map.singleton (T.pack "y") (VInt 42)
      client = fixedClient cEnd fixedState
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated SpecValid)
  sendMsg mEnd (InitialState (T.pack "Init"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s fixedState "fixed returns same state"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd (NextStep (T.pack "Advance"))
  recvMsg mEnd >>= \case
    Right (ReportState s) -> expect s fixedState "fixed returns same state again"
    other                 -> unexpected "ReportState" other
  sendMsg mEnd StepOk
  sendMsg mEnd AllStepsDone
  result <- awaitResult mv
  expect result (Right ()) "fixed client completed"

testSpecInvalid :: IO ()
testSpecInvalid = do
  putStrLn "[5] SpecInvalid is returned as an error"
  (cEnd, mEnd) <- newMockTransport
  let client = fixedClient cEnd Map.empty
  mv <- forkClient client "spec.tla" config
  (_ :: Either String ClientMessage) <- recvMsg mEnd
  sendMsg mEnd (SpecValidated (SpecInvalid (T.pack "typecheck failed")))
  result <- awaitResult mv
  case result of
    Left e | T.pack "typecheck failed" == e ->
      putStrLn "  PASS: got expected error"
    Left e -> do
      putStrLn $ "  FAIL: unexpected error: " ++ T.unpack e
      exitFailure
    Right _ -> do
      putStrLn "  FAIL: expected Left, got Right"
      exitFailure

unexpected :: Show a => String -> a -> IO ()
unexpected label msg = do
  putStrLn $ "  FAIL: expected " ++ label ++ ", got: " ++ show msg
  exitFailure
