{-# LANGUAGE OverloadedStrings #-}
module MirrorProtocolSpec (spec) where

import Apalache.Command (generateTraces)
import Apalache.Types
    ( ApalacheConfig (..)
    , ItfTrace (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , TraceState (..)
    , Value (..)
    )
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch)
import Control.Monad (unless)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Mirror (runMirror)
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "MirrorProtocolSpec"
  [ testProtocolTraceGenerated
  , testMirrorFollowsProtocol
  ]

hcTraceConfig :: TraceGenerationConfig
hcTraceConfig = TraceGenerationConfig
  { invariant      = T.pack "TraceComplete"
  , lengthBound    = 13
  , numTraces      = 1
  , view           = Nothing
  , cinit          = Nothing
  , paramVarNames  = T.empty
  }

testProtocolTraceGenerated :: TestTree
testProtocolTraceGenerated = testCase "MirrorProtocolServer generates traces" $ do
  let cfg = ApalacheConfig
        { specPath      = "specs/MirrorProtocolServer.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
        }
      tc = TraceGenerationConfig
        { invariant      = T.pack "TraceComplete"
        , lengthBound    = 20
        , numTraces      = 1
        , view           = Nothing
        , cinit          = Nothing
        , paramVarNames  = T.empty
        }
  traceRes <- generateTraces cfg tc
  case traceRes of
    Left err -> assertFailure $ "generateTraces error: " ++ show err
    Right (GenerationError e) -> assertFailure $ "trace generation error: " ++ T.unpack e
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated (trace : _)) -> do
      let states = traceStates trace
          nvars  = traceVars trace
      assertBool "trace must have at least 2 states" (length states >= 2)
      assertBool "trace must include mp variable" (T.pack "mp" `elem` nvars)
      assertBool "trace must include cl_to_mir variable" (T.pack "cl_to_mir" `elem` nvars)
      assertBool "trace must include mir_to_cl variable" (T.pack "mir_to_cl" `elem` nvars)
      assertBool "trace must include action_taken variable" (T.pack "action_taken" `elem` nvars)

testMirrorFollowsProtocol :: TestTree
testMirrorFollowsProtocol = testCase "mirror follows protocol message sequence" $ do
  trace <- generateMirrorTrace
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $
    runMirror mirrorEnd "test/specs/HourClock.tla" hcTraceConfig
      >> putMVar mv True
      `catch` (\(_ :: SomeException) -> putMVar mv False)

  let steps = drop 1 (traceStates trace)
  results <- driveMirror clientEnd steps

  assertBool "at least one verification step" (length results >= 1)
  let mismatches = [(i, desc, msg) | (i, (desc, ok, msg)) <- results, not ok]
  unless (null mismatches) $
    assertFailure $ unlines $ "protocol mismatches:" : ["  step " ++ show i ++ ": " ++ desc ++ " -- " ++ msg | (i, desc, msg) <- mismatches]

  _ <- tryReadMVar mv
  pure ()

generateMirrorTrace :: IO ItfTrace
generateMirrorTrace = do
  let cfg = ApalacheConfig
        { specPath      = "specs/MirrorProtocolServer.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
        }
      tc = TraceGenerationConfig
        { invariant      = T.pack "TraceComplete"
        , lengthBound    = 20
        , numTraces      = 1
        , view           = Nothing
        , cinit          = Nothing
        , paramVarNames  = T.empty
        }
  traceRes <- generateTraces cfg tc
  case traceRes of
    Right (TracesGenerated (t : _)) -> pure t
    _ -> error $ "no traces generated: " ++ show traceRes

driveMirror :: MockTransport -> [TraceState] -> IO [(Int, (String, Bool, String))]
driveMirror clientEnd steps = go 0 steps
  where
    go _ [] = pure []
    go i (st : rest) = do
      let at = actionTake st
      result <- case at of
        "ClientSendRegister" -> do
          sendMsg clientEnd $ Register "test/specs/HourClock.tla" hcTraceConfig
          pure (i, ("send Register", True, "ok"))
        "ClientSendReport" -> do
          sendMsg clientEnd $ ReportState dummyState
          pure (i, ("send ReportState", True, "ok"))
        _ | at == "MirrorSendSpecValidatedValid" || at == "MirrorSendSpecValidatedInvalid" -> do
          msg <- recvMsg clientEnd
          let ok = case msg of
                Right (SpecValidated _) -> True
                _ -> False
          pure (i, ("recv SpecValidated", ok, showMsg msg))
        "MirrorSendRegisterError" -> do
          msg <- recvMsg clientEnd
          let ok = case msg of
                Right (RegisterError _) -> True
                _ -> False
          pure (i, ("recv RegisterError", ok, showMsg msg))
        "MirrorSendInitialState" -> do
          msg <- recvMsg clientEnd
          pure (i, ("recv InitialState", checkInitialState msg, showMsg msg))
        "MirrorSendNextStep" -> do
          msg <- recvMsg clientEnd
          pure (i, ("recv NextStep", checkNextStep msg, showMsg msg))
        "MirrorRecvReportState" -> do
          msg <- recvMsg clientEnd
          let ok = case msg of
                Right StepOk             -> True
                Right (StepMismatch _ _) -> True
                Right AllStepsDone       -> True
                _                        -> False
          pure (i, ("recv step result", ok, showMsg msg))
        "MirrorRecvRegister" ->
          pure (i, ("skip MirrorRecvRegister (mirror internal)", True, "ok"))
        "init" ->
          pure (i, ("skip init state", True, "ok"))
        _ ->
          pure (i, ("unknown action " ++ T.unpack at, False, show at))
      (result :) <$> go (i + 1) rest

dummyState :: Map.Map Text Value
dummyState = Map.singleton (T.pack "dummy") (VInt 0)

checkInitialState :: Either String MirrorMessage -> Bool
checkInitialState (Right (InitialState _ _)) = True
checkInitialState _ = False

checkNextStep :: Either String MirrorMessage -> Bool
checkNextStep (Right (NextStep _ _)) = True
checkNextStep _ = False

showMsg :: Show a => Either String a -> String
showMsg (Left e) = "parse error: " ++ e
showMsg (Right x) = show x
