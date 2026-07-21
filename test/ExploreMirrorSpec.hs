module ExploreMirrorSpec (spec) where

import Apalache.Rpc.Types (ApalacheSpec, mkSpecFromFile, mkSpecFromSource)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException, catch)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Apalache.Types (Value (..))
import Protocol.Client (exploreSession, fixedClient, hourClockClient, runClientExplore)
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Mirror (MirrorStep (..), run)
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "ExploreMirrorSpec"
  [ testExploreHappyPath
  , testExploreMismatch
  , testExploreRegisterError
  , testExploreSession
  , testExploreSessionRegisterError
  ]

hcSpec :: IO ApalacheSpec
hcSpec = mkSpecFromFile "test/specs/HourClock.tla"

testExploreHappyPath :: TestTree
testExploreHappyPath = testCase "explore: hourClockClient matches symbolic states" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  client <- hourClockClient clientEnd
  result <- runClientExplore client spec' [T.pack "Inv"] [] 4
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right _ -> pure ()
  steps <- readMVar mv
  assertBool "mirror produced steps" (not (null steps))
  assertBool "no mismatches"
    (not (any (\case MirrorSendStepMismatch{} -> True; _ -> False) steps))
  assertBool "no protocol errors"
    (not (any (\case MirrorSendProtocolError{} -> True; _ -> False) steps))
  assertBool "ends with AllStepsDone"
    (case reverse steps of
      (MirrorSendAllStepsDone : _) -> True
      _ -> False)

testExploreMismatch :: TestTree
testExploreMismatch = testCase "explore: divergent client state yields StepMismatch" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  let bogus = Map.singleton (T.pack "hr") (VInt 99) :: Map Text Value
      client = fixedClient clientEnd bogus
  result <- runClientExplore client spec' [T.pack "Inv"] [] 4
  case result of
    Left _ -> pure ()
    Right _ -> assertFailure "client unexpectedly succeeded with bogus state"
  steps <- readMVar mv
  assertBool "mismatch reported"
    (any (\case MirrorSendStepMismatch{} -> True; _ -> False) steps)

testExploreRegisterError :: TestTree
testExploreRegisterError = testCase "explore: malformed spec yields RegisterError" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  client <- hourClockClient clientEnd
  result <- runClientExplore client (mkSpecFromSource (T.pack "garbage not a spec")) [] [] 4
  case result of
    Left _ -> pure ()
    Right _ -> assertFailure "client unexpectedly succeeded with malformed spec"
  steps <- readMVar mv
  assertBool "register error reported"
    (any (\case MirrorSendRegisterError{} -> True; _ -> False) steps)

recv :: MockTransport -> IO (Either String MirrorMessage)
recv = recvMsg

isTransStatus :: Text -> Either String MirrorMessage -> Bool
isTransStatus s (Right (ExploreTransitionStatus x)) = x == s
isTransStatus s (Right (ExploreAssumeStatus x)) = x == s
isTransStatus _ _ = False

testExploreSession :: TestTree
testExploreSession = testCase "session: client drives interactive symbolic checking" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  r <- exploreSession clientEnd spec' [T.pack "Inv"] []
  (nInit, nNext, nInv) <- case r of
    Left err -> assertFailure ("exploreSession failed: " ++ T.unpack err)
    Right counts -> pure counts
  assertBool "one init transition" (nInit == 1)
  assertBool "at least one next transition" (nNext >= 1)
  assertBool "one state invariant" (nInv == 1)

  sendMsg clientEnd (ExploreAssumeTransition 0)
  r1 <- recv clientEnd
  assertBool ("assumeTransition: " ++ show r1) (isTransStatus (T.pack "ENABLED") r1)

  sendMsg clientEnd ExploreNextStep
  r2 <- recv clientEnd
  assertBool ("nextStep: " ++ show r2)
    (case r2 of Right (ExploreStepDone 1) -> True; _ -> False)

  sendMsg clientEnd ExploreQueryState
  r3 <- recv clientEnd
  hrVal <- case r3 of
    Right (ExploreState st) -> pure (Map.lookup (T.pack "hr") st)
    _ -> assertFailure ("queryState: " ++ show r3)

  sendMsg clientEnd (ExploreCheckInvariant 0)
  r4 <- recv clientEnd
  assertBool ("checkInvariant: " ++ show r4)
    (case r4 of Right (ExploreInvariantStatus s) -> s == T.pack "SATISFIED"; _ -> False)

  case hrVal of
    Nothing -> assertFailure "queried state has no hr"
    Just v -> do
      sendMsg clientEnd (ExploreAssumeState (Map.singleton (T.pack "hr") v))
      r5 <- recv clientEnd
      assertBool ("assumeState: " ++ show r5) (isTransStatus (T.pack "ENABLED") r5)

  sendMsg clientEnd (ExploreAssumeTransition 999)
  r6 <- recv clientEnd
  assertBool ("invalid tid: " ++ show r6)
    (case r6 of Right (ProtocolError _) -> True; _ -> False)

  sendMsg clientEnd (ExploreRollback 0)
  r7 <- recv clientEnd
  assertBool ("rollback: " ++ show r7)
    (case r7 of Right (ExploreRollbackDone 0) -> True; _ -> False)

  sendMsg clientEnd ExploreDone
  r8 <- recv clientEnd
  assertBool ("done: " ++ show r8)
    (case r8 of Right ExploreSessionDone -> True; _ -> False)

  steps <- readMVar mv
  assertBool "session registered"
    (any (\case MirrorRecvRegisterExploreSession{} -> True; _ -> False) steps)
  let cmds = length [ () | MirrorRecvExploreCmd _ <- steps ]
  assertBool ("explorer commands forwarded: " ++ show cmds) (cmds >= 7)

testExploreSessionRegisterError :: TestTree
testExploreSessionRegisterError = testCase "session: malformed spec yields RegisterError" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  r <- exploreSession clientEnd (mkSpecFromSource (T.pack "garbage not a spec")) [] []
  case r of
    Left _ -> pure ()
    Right _ -> assertFailure "session unexpectedly opened with malformed spec"
  steps <- readMVar mv
  assertBool "register error reported"
    (any (\case MirrorSendRegisterError{} -> True; _ -> False) steps)
