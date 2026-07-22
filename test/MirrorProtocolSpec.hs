{-# LANGUAGE OverloadedStrings #-}
module MirrorProtocolSpec (spec) where

import Apalache.Command (generateTraces, generateTraceFiles)
import Apalache.Rpc.Types (mkSpecFromFile)
import Apalache.Trace (readTrace)
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
import Control.Exception (SomeException, catch, try)
import Control.Monad (unless, forM_)
import Data.Aeson (FromJSON, encode)
import qualified Data.ByteString.Lazy as BL
import System.Timeout (timeout)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (traceSteps)
import Engine.Types (Step (..))
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import MinimalTraceCheck (normalize)
import Protocol.Client (hourClockClient, runClientWithTraces)
import Protocol.Mirror (mirrorStepActionName, run, runMirrorWithTraces, runMirrorGenTraces)
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>), takeExtension)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "MirrorProtocolSpec"
  [ testProtocolTraceGenerated
  , testMirrorFollowsProtocol
  , testMbtMirrorProtocol
  , testRunMirrorWithTracesDir
  , testRunMirrorGenTraces
  , testRunMirrorGenTracesWithDest
  , testRunMirrorGenThenReplay
  , testRunMirrorClientReport
  ]

hcApalacheCfg :: ApalacheConfig
hcApalacheCfg = ApalacheConfig
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

testRunMirrorWithTracesDir :: TestTree
testRunMirrorWithTracesDir = testCase "runMirrorWithTraces expands directory paths" $ do
  result <- generateTraces hcApalacheCfg hcTraceConfig
  case result of
    Left err -> assertFailure $ "generateTraces error: " ++ show err
    Right (GenerationError e) -> assertFailure $ "trace generation error: " ++ T.unpack e
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated traces) -> do
      sysTmp <- getTemporaryDirectory
      let tmpDir = sysTmp </> "modelmirrors-test-traces"
      createDirectory tmpDir
      forM_ (zip [0 :: Int ..] traces) $ \(i, t) ->
        BL.writeFile (tmpDir </> "trace_" ++ show i ++ ".itf.json") (encode t)

      (clientEnd, mirrorEnd) <- newMockTransport
      done <- newEmptyMVar
      _ <- forkIO $ runMirrorWithTraces mirrorEnd hcApalacheCfg [tmpDir]
        >> putMVar done True
        `catch` (\(_ :: SomeException) -> putMVar done False)

      results <- driveMirrorTraces clientEnd traces
      removeDirectoryRecursive tmpDir

      let mismatches = [(i, msg) | (i, (False, msg)) <- results]
      unless (null mismatches) $
        assertFailure $ unlines $
          ("protocol mismatches (" ++ show (length mismatches) ++ "/" ++ show (length results) ++ "):")
          : ["  step " ++ show i ++ ": " ++ msg | (i, msg) <- mismatches]

      ok <- readMVar done
      assertBool "mirror completed without exception" ok

testRunMirrorGenTraces :: TestTree
testRunMirrorGenTraces = testCase "runMirrorGenTraces generates and notifies done" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  done <- newEmptyMVar
  _ <- forkIO $ runMirrorGenTraces mirrorEnd hcApalacheCfg hcTraceConfig Nothing
        >> putMVar done True
        `catch` (\(_ :: SomeException) -> putMVar done False)

  msg <- recvMsg clientEnd
  paths <- case msg of
    Right (GenTracesDone ps) -> do
      assertBool "GenTracesDone has at least one path" (not (null ps))
      pure ps
    _ -> assertFailure $ "expected GenTracesDone, got: " ++ showMsg msg

  ok <- readMVar done
  assertBool "mirror completed without exception" ok

  assertBool "generated paths are valid files" (not (null paths) && all (\p -> takeExtension p == ".json") paths)

testRunMirrorGenTracesWithDest :: TestTree
testRunMirrorGenTracesWithDest = testCase "runMirrorGenTraces copies to destPath" $ do
  sysTmp <- getTemporaryDirectory
  let destDir = sysTmp </> "modelmirrors-test-gendest"
  createDirectory destDir

  (clientEnd, mirrorEnd) <- newMockTransport
  done <- newEmptyMVar
  _ <- forkIO $ runMirrorGenTraces mirrorEnd hcApalacheCfg hcTraceConfig (Just destDir)
        >> putMVar done True
        `catch` (\(_ :: SomeException) -> putMVar done False)

  msg <- recvMsg clientEnd
  _ <- case msg of
    Right (GenTracesDone ps) -> do
      assertBool "GenTracesDone has at least one path" (not (null ps))
      assertBool "all paths point to destDir" (all (destDir `isPrefixOf`) ps)
      pure ps
    _ -> assertFailure $ "expected GenTracesDone, got: " ++ showMsg msg

  ok <- readMVar done
  removeDirectoryRecursive destDir
  assertBool "mirror completed without exception" ok

testRunMirrorClientReport :: TestTree
testRunMirrorClientReport = testCase "ClientReport must send ReportState or timeout" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure ps
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err
  assertBool "at least one trace file" (not (null hcTracePaths))

  done <- newEmptyMVar
  _ <- forkIO $ runMirrorWithTraces mirrorEnd hcApalacheCfg hcTracePaths
        >> putMVar done True
        `catch` (\(_ :: SomeException) -> putMVar done False)

  -- Receive SpecValidated
  msg1 <- recvOrDie' "SpecValidated" clientEnd
  case msg1 of
    Right (SpecValidated _) -> pure ()
    _ -> assertFailure $ "expected SpecValidated, got: " ++ showMsg msg1

  -- Receive InitialState (sent by mirror's first replay step)
  msg2 <- recvOrDie' "InitialState" clientEnd
  case msg2 of
    Right (InitialState _ _) -> pure ()
    _ -> assertFailure $ "expected InitialState, got: " ++ showMsg msg2

  -- DELIBERATELY DO NOT send ReportState; mirror should block
  -- The MVar should NOT be filled within 10s (mirror is stuck)

  mirrorFinished <- timeout 5_000_000 (readMVar done)
  case mirrorFinished of
    Just True -> assertFailure "mirror finished without ReportState (should have blocked)"
    _ -> pure ()

  -- Now send ReportState to unblock mirror
  sendMsg clientEnd $ ReportState dummyState

  -- Mirror should now respond with StepOk or StepMismatch
  msg3 <- recvOrDie' "step result" clientEnd
  case msg3 of
    Right StepOk -> pure ()
    Right (StepMismatch _ _) -> pure ()
    _ -> assertFailure $ "expected StepOk/StepMismatch, got: " ++ showMsg msg3

  sendMsg clientEnd $ ReportState dummyState
  _ <- timeout 5_000_000 (recvMsg clientEnd :: IO (Either String MirrorMessage))
  _ <- tryReadMVar done
  pure ()

testRunMirrorGenThenReplay :: TestTree
testRunMirrorGenThenReplay = testCase "runMirrorGenTraces then RegisterTraces replays" $ do
  (clientEnd1, mirrorEnd1) <- newMockTransport
  done1 <- newEmptyMVar
  _ <- forkIO $ runMirrorGenTraces mirrorEnd1 hcApalacheCfg hcTraceConfig Nothing
        >> putMVar done1 True
        `catch` (\(_ :: SomeException) -> putMVar done1 False)

  msg <- recvMsg clientEnd1
  generatedPaths <- case msg of
    Right (GenTracesDone ps) ->
      assertBool "GenTracesDone has paths" (not (null ps)) >> pure ps
    _ -> assertFailure $ "expected GenTracesDone, got: " ++ showMsg msg

  _ <- readMVar done1

  traces <- mapM readTrace generatedPaths
  case sequence traces of
    Left err -> assertFailure $ "readTrace failed: " ++ err
    Right parsed -> do
      assertBool "read at least one trace" (not (null parsed))

      (clientEnd2, mirrorEnd2) <- newMockTransport
      done2 <- newEmptyMVar
      _ <- forkIO $ runMirrorWithTraces mirrorEnd2 hcApalacheCfg generatedPaths
            >> putMVar done2 True
            `catch` (\(_ :: SomeException) -> putMVar done2 False)

      results <- driveMirrorTraces clientEnd2 parsed
      let mismatches = [(i, m) | (i, (False, m)) <- results]
      unless (null mismatches) $
        assertFailure $ unlines $
          ("protocol mismatches (" ++ show (length mismatches) ++ "/" ++ show (length results) ++ "):")
          : ["  step " ++ show i ++ ": " ++ m | (i, m) <- mismatches]

      ok2 <- readMVar done2
      assertBool "replay mirror completed without exception" ok2

driveMirrorTraces :: MockTransport -> [ItfTrace] -> IO [(Int, (Bool, String))]
driveMirrorTraces clientEnd traces = do
  msg <- recvMsg clientEnd
  case msg of
    Right (SpecValidated _) -> go 0 steps
    _ -> pure [(0, (False, "expected SpecValidated, got: " ++ showMsg msg))]
  where
    steps = concatMap traceSteps traces
    go i [] = do
      msg <- recvMsg clientEnd
      pure $ case msg of
        Right AllStepsDone -> [(i, (True, "ok"))]
        _ -> [(i, (False, "expected AllStepsDone, got: " ++ showMsg msg))]
    go i (step : rest) = do
      msg <- recvMsg clientEnd
      case msg of
        Right m | isStep m -> do
          sendMsg clientEnd (ReportState (stepVars step))
          resp <- recvMsg clientEnd
          case resp of
            Right StepOk -> ((i, (True, "ok")) :) <$> go (i + 1) rest
            _ -> pure [(i, (False, "expected StepOk, got: " ++ showMsg resp))]
        _ -> pure [(i, (False, "expected InitialState/NextStep, got: " ++ showMsg msg))]
    isStep InitialState{} = True
    isStep NextStep{} = True
    isStep _ = False

testProtocolTraceGenerated :: TestTree
testProtocolTraceGenerated = testCase "MirrorProtocolServer generates traces" $ do
  let cfg = ApalacheConfig
        { specPath      = "specs/MirrorProtocol.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
        , invariant     = T.pack "TraceComplete"
        , lengthBound   = 20
        , paramVarNames = T.empty
        }
      tc = TraceGenerationConfig
        { numTraces = 1
        , view      = Nothing
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
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure ps
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err

  trace <- generateMirrorTrace
  let steps = drop 1 (traceStates trace)

  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ run mirrorEnd
        >> putMVar mv True
        `catch` (\(_ :: SomeException) -> putMVar mv False)

  results <- driveMirror clientEnd hcApalacheCfg hcTraceConfig hcTracePaths steps

  assertBool "at least one verification step" (length results >= 1)
  let mismatches = [(i, desc, msg) | (i, (desc, ok, msg)) <- results, not ok]
  unless (null mismatches) $
    assertFailure $ unlines $ "protocol mismatches:" : ["  step " ++ show i ++ ": " ++ desc ++ " -- " ++ msg | (i, desc, msg) <- mismatches]

  _ <- tryReadMVar mv
  pure ()

testMbtMirrorProtocol :: TestTree
testMbtMirrorProtocol = testCase "mbt: mirror follows all protocol flows" $ do
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure (take 1 ps)
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err

  traces <- generateMirrorTraces
  assertBool "at least one trace generated" (not (null traces))

  let applicable = filter (\t ->
        let acts = map actionTake (traceStates t)
        in not (any (`elem` [T.pack "ClientRegisterGenTraces"
                            ,T.pack "ClientRegisterExplore"
                            ,T.pack "ClientRegisterExploreSession"
                            ,T.pack "ClientRecvRegisterError"
                            ,T.pack "ClientRecvProtocolError"
                            ,T.pack "MirrorSendSpecValidatedInvalid"
                            ,T.pack "MirrorSendRegisterError"
                            ,T.pack "MirrorSendProtocolError"
                            ]) acts)
        ) traces
  assertBool "at least one applicable trace" (not (null applicable))

  forM_ applicable $ \trace -> do
    let steps = drop 1 (traceStates trace)
        isDone s = case (Map.lookup (T.pack "mp") (stateVars s), Map.lookup (T.pack "cp") (stateVars s)) of
          (Just (VStr p1), _) | p1 == T.pack "done" -> True
          (_, Just (VStr p2)) | p2 == T.pack "done" -> True
          _ -> False
        cycleSteps = case break isDone steps of
          (pre, t : _) -> pre ++ [t]
          (pre, [])   -> pre

        specCanon a
          | a == T.pack "MirrorRecvRegister" = T.pack "MirrorRecvRegisterTraces"
          | a == T.pack "MirrorSendSpecValidatedValid" = T.pack ""
          | otherwise = a
        specActions = filter (not . T.null) [ specCanon (actionTake s)
                                            | s <- cycleSteps
                                            , "Mirror" `T.isPrefixOf` actionTake s
                                            ]
        specStepCount = length [ () | s <- cycleSteps
                                  , actionTake s == T.pack "MirrorRecvReportState"
                                  ]

    (clientEnd, mirrorEnd) <- newMockTransport
    mv <- newEmptyMVar
    _ <- forkIO $ do
      result <- try (run mirrorEnd)
      putMVar mv $ case result of
        Right stps -> Right stps
        Left (e :: SomeException) -> Left (show e)

    client <- hourClockClient clientEnd
    _ <- runClientWithTraces client hcApalacheCfg hcTracePaths

    mResult <- timeout 180_000_000 (readMVar mv)
    case mResult of
      Nothing -> assertFailure "mirror did not complete within timeout"
      Just (Left e) -> assertFailure $ "mirror threw exception: " ++ e
      Just (Right implSteps) -> do
        let stepCanon a
              | a == T.pack "MirrorSendStepOk" = T.pack "MirrorRecvReportState"
              | a == T.pack "MirrorSendStepMismatch" = T.pack "MirrorRecvReportState"
              | otherwise = a
            implActions = map (stepCanon . mirrorStepActionName) (normalize implSteps)
            implTrimmed = take (2 * specStepCount + 1) implActions
        unless (specActions == implTrimmed) $
          assertFailure $ unlines $
            ("protocol trace mismatch:")
            : [ "  spec:   " ++ show specActions
              , "  impl:   " ++ show implTrimmed
              , "  raw:    " ++ show (map mirrorStepActionName implSteps)
              ]

generateMirrorTrace :: IO ItfTrace
generateMirrorTrace = do
  let cfg = ApalacheConfig
        { specPath      = "specs/MirrorProtocol.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
        , invariant     = T.pack "TraceSuccess"
        , lengthBound   = 20
        , paramVarNames = T.empty
        }
      tc = TraceGenerationConfig
        { numTraces = 1
        , view      = Nothing
        }
  traceRes <- generateTraces cfg tc
  case traceRes of
    Right (TracesGenerated (t : _)) -> pure t
    _ -> error $ "no traces generated: " ++ show traceRes

generateMirrorTraces :: IO [ItfTrace]
generateMirrorTraces = do
  let cfg = ApalacheConfig
        { specPath      = "specs/MirrorProtocol.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
          , invariant     = T.pack "TraceComplete"
        , lengthBound   = 20
        , paramVarNames = T.empty
        }
      tc = TraceGenerationConfig
        { numTraces = 100
        , view      = Just (T.pack "MirrorView")
        }
  traceRes <- generateTraces cfg tc
  case traceRes of
    Right (TracesGenerated ts) -> pure ts
    _ -> error $ "no traces generated: " ++ show traceRes

driveMirror :: MockTransport -> ApalacheConfig -> TraceGenerationConfig -> [FilePath] -> [TraceState] -> IO [(Int, (String, Bool, String))]
driveMirror clientEnd apCfg tc tracePaths steps = go 0 steps
  where
    recvOrDie desc = do
      m <- timeout 10_000_000 (recvMsg clientEnd)
      case m of
        Nothing -> pure $ Left $ "timeout waiting for " ++ desc
        Just r  -> pure r
    go _ [] = pure []
    go i (st : rest) = do
      let at = actionTake st
      result <- case at of
        "ClientRegister" -> do
          sendMsg clientEnd (Register apCfg tc Nothing)
          pure (i, ("send Register", True, "ok"))
        "ClientRegisterTraces" -> do
          sendMsg clientEnd (RegisterTraces apCfg tracePaths)
          pure (i, ("send RegisterTraces", True, "ok"))
        "ClientRegisterGenTraces" -> do
          sendMsg clientEnd (RegisterGenTraces apCfg tc Nothing Nothing)
          pure (i, ("send RegisterGenTraces", True, "ok"))
        "ClientRegisterExplore" -> do
          -- Explore traces are covered by ExploreMirrorSpec; at the message
          -- level the explore flow is identical to RegisterTraces, so drive
          -- the equivalent flow here.
          sendMsg clientEnd (RegisterTraces apCfg tracePaths)
          pure (i, ("send RegisterTraces (explore substitute)", True, "ok"))
        "ClientRegisterExploreSession" -> do
          spec' <- mkSpecFromFile (specPath apCfg)
          sendMsg clientEnd (RegisterExploreSession spec' [] [])
          pure (i, ("send RegisterExploreSession", True, "ok"))
        "ClientExploreCmd" -> do
          sendMsg clientEnd ExploreQueryState
          pure (i, ("send ExploreQueryState", True, "ok"))
        "ClientExploreDone" -> do
          sendMsg clientEnd ExploreDone
          pure (i, ("send ExploreDone", True, "ok"))
        "ClientRecvSpecValidated" ->
          pure (i, ("skip ClientRecvSpecValidated", True, "ok"))
        "ClientRecvInitialState" ->
          pure (i, ("skip ClientRecvInitialState", True, "ok"))
        "ClientRecvGenTracesDone" -> do
          msg <- recvOrDie "GenTracesDone"
          let ok = case msg of
                Right (GenTracesDone _) -> True
                _ -> False
          pure (i, ("recv GenTracesDone", ok, showMsg msg))
        "ClientReport" -> do
          sendMsg clientEnd $ ReportState dummyState
          pure (i, ("send ReportState", True, "ok"))
        _ | at == "MirrorSendSpecValidatedValid" || at == "MirrorSendSpecValidatedInvalid" || at == "MirrorSendRegisterError" -> do
          msg <- recvOrDie "SpecValidated or RegisterError"
          let ok = case msg of
                Right (SpecValidated _) -> True
                Right (RegisterError _) -> True
                _ -> False
          pure (i, ("recv SpecValidated/RegisterError", ok, showMsg msg))
        "MirrorSendInitialState" -> do
          msg <- recvOrDie "InitialState"
          pure (i, ("recv InitialState", checkInitialState msg, showMsg msg))
        "MirrorSendNextStep" -> do
          msg <- recvOrDie "NextStep"
          pure (i, ("recv NextStep", checkNextStep msg, showMsg msg))
        "MirrorRecvReportState" -> do
          msg <- recvOrDie "step result"
          let ok = case msg of
                Right StepOk             -> True
                Right (StepMismatch _ _) -> True
                Right AllStepsDone       -> True
                _                        -> False
          pure (i, ("recv step result", ok, showMsg msg))
        "MirrorRecvRegister" ->
          pure (i, ("skip MirrorRecvRegister (mirror internal)", True, "ok"))
        "MirrorRecvRegisterTraces" ->
          pure (i, ("skip MirrorRecvRegisterTraces", True, "ok"))
        "MirrorRecvRegisterGenTraces" ->
          pure (i, ("skip MirrorRecvRegisterGenTraces", True, "ok"))
        "MirrorRecvRegisterExplore" ->
          pure (i, ("skip MirrorRecvRegisterExplore", True, "ok"))
        "MirrorRecvRegisterExploreSession" ->
          pure (i, ("skip MirrorRecvRegisterExploreSession", True, "ok"))
        "MirrorSendExplorerReady" -> do
          msg <- recvOrDie "ExplorerReady"
          let ok = case msg of
                Right (ExplorerReady _ _ _) -> True
                _ -> False
          pure (i, ("recv ExplorerReady", ok, showMsg msg))
        "MirrorRecvExploreCmd" -> do
          msg <- recvOrDie "explore result"
          let ok = case msg of
                Right (ExploreState _) -> True
                Right (ProtocolError _) -> True
                _ -> False
          pure (i, ("recv explore result", ok, showMsg msg))
        "MirrorRecvExploreDone" -> do
          msg <- recvOrDie "ExploreSessionDone"
          let ok = case msg of
                Right ExploreSessionDone -> True
                _ -> False
          pure (i, ("recv ExploreSessionDone", ok, showMsg msg))
        "ClientRecvExplorerReady" ->
          pure (i, ("skip ClientRecvExplorerReady", True, "ok"))
        "ClientRecvExploreResult" ->
          pure (i, ("skip ClientRecvExploreResult", True, "ok"))
        "ClientRecvExploreDoneAck" ->
          pure (i, ("skip ClientRecvExploreDoneAck", True, "ok"))
        "MirrorSendGenTracesDone" -> do
          msg <- recvOrDie "GenTracesDone"
          let ok = case msg of
                Right (GenTracesDone _) -> True
                _ -> False
          pure (i, ("recv GenTracesDone", ok, showMsg msg))
        "ClientRecvRegisterError" ->
          pure (i, ("skip ClientRecvRegisterError", True, "ok"))
        "ClientRecvStepOk" ->
          pure (i, ("skip ClientRecvStepOk", True, "ok"))
        "ClientRecvStepMismatch" ->
          pure (i, ("skip ClientRecvStepMismatch", True, "ok"))
        "ClientRecvAllStepsDone" ->
          pure (i, ("skip ClientRecvAllStepsDone", True, "ok"))
        "ClientRecvNextStep" ->
          pure (i, ("skip ClientRecvNextStep", True, "ok"))
        "init" ->
          pure (i, ("skip init state", True, "ok"))
        _ ->
          pure (i, ("unknown action " ++ T.unpack at, False, show at))
      (result :) <$> go (i + 1) rest

dummyState :: Map.Map Text Value
dummyState = Map.singleton (T.pack "dummy") (VInt 0)

recvOrDie' :: (Transport t, FromJSON a) => String -> t -> IO (Either String a)
recvOrDie' desc t = do
  m <- timeout 10_000_000 (recvMsg t)
  case m of
    Nothing -> pure $ Left $ "timeout waiting for " ++ desc
    Just r  -> pure r

checkInitialState :: Either String MirrorMessage -> Bool
checkInitialState (Right (InitialState _ _)) = True
checkInitialState _ = False

checkNextStep :: Either String MirrorMessage -> Bool
checkNextStep (Right (NextStep _ _)) = True
checkNextStep _ = False

showMsg :: Show a => Either String a -> String
showMsg (Left e) = "parse error: " ++ e
showMsg (Right x) = show x
