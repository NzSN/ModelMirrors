{-# LANGUAGE OverloadedStrings #-}
module MirrorProtocolSpec (spec) where

import Apalache.Command (generateTraces, generateTraceFiles)
import Apalache.Rpc.Types (ApalacheSpec, mkSpecFromFile, mkSpecFromSource)
import Apalache.Trace (readTrace)
import Apalache.Types
    ( ApalacheConfig (..)
    , ItfTrace (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , TraceState (..)
    , ValidateResult (..)
    , Value (..)
    )
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, catch, try)
import Control.Monad (unless, forM_)
import Data.Aeson (FromJSON, decode, encode)
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Timeout (timeout)
import Data.List (isPrefixOf, partition)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import qualified Data.Text as T
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , SockAddr (..)
  , Socket
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , getSocketName
  , socket
  )
import Engine.Core (traceSteps)
import Engine.Types (Step (..))
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import MinimalTraceCheck (normalize)
import Protocol.Client (Client (..), hourClockClient, runClientValidate, runClientWithTraces)
import Protocol.Mirror (MirrorStep (..), maxValidateBound, mirrorStepActionName, run, runMirrorWithTraces, runMirrorGenTraces)
import Protocol.Transport.Core (Transport (..), recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import Protocol.Transport.Tcp (serveTcp, tcpClose, tcpTransport)
import Protocol.Transport.Tls (connectTls, mkClientParams, mkServerParams, serveTlsConcurrent)
import System.Directory (createDirectory, getTemporaryDirectory, listDirectory, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeExtension)
import System.IO (Handle, hFlush)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createProcess
  , proc
  , readProcess
  , terminateProcess
  , waitForProcess
  )
import TlsTransportSpec (Certs (..), genCerts)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure, (@?=))

spec :: TestTree
spec = testGroup "MirrorProtocolSpec"
  [ testProtocolTraceGenerated
  , testMirrorFollowsProtocol
  , testMbtMirrorProtocol
  , testWitnessTracesFixed
  , testMbtTransports
  , testOutOfOrderFirstMessage
  , testGarbageMidSession
  , testPrematureCloseTcp
  , testRunMirrorWithTracesDir
  , testRunMirrorGenTraces
  , testRunMirrorGenTracesWithDest
  , testRunMirrorGenThenReplay
  , testRunMirrorClientReport
  , testRunMirrorValidate
  , testRunMirrorValidateInline
  , testRunMirrorValidateInvalid
  , testRunMirrorValidateBadInline
  , testRunMirrorValidateBoundTooHigh
  , testRunMirrorValidateBoundNonPositive
  , testRegisterValidateJsonRoundtrip
  , testRegisterFamilyJsonRoundtrips
  , testValidateConformanceNames
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
    Right (GenTracesDone ps ts) -> do
      assertBool "GenTracesDone has at least one path" (not (null ps))
      assertBool "GenTracesDone inlines one trace per path" (length ts == length ps)
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
    Right (GenTracesDone ps ts) -> do
      assertBool "GenTracesDone has at least one path" (not (null ps))
      assertBool "all paths point to destDir" (all (destDir `isPrefixOf`) ps)
      assertBool "GenTracesDone inlines one trace per path" (length ts == length ps)
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
    Right (StepMismatch _ _ _) -> pure ()
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
    Right (GenTracesDone ps _) ->
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

-- -----------------------------------------------------------------------------
-- Validate-only path (RegisterValidate)
-- -----------------------------------------------------------------------------

-- A spec that type-checks but whose invariant is FALSE, so apalache's check
-- (with @--inv@) finds a violation at any bound and @validateSpecIn@ returns
-- @SpecInvalid@. Exercises the @--inv@ path added for remote validation.
invalidSpec :: ApalacheSpec
invalidSpec = mkSpecFromSource $ T.unlines
  [ "---------------- MODULE BadInv ---------------------"
  , "EXTENDS Naturals"
  , "VARIABLE"
  , "  \\* @type: Int;"
  , "  x"
  , "Init == x = 0"
  , "Next == x' = x + 1"
  , "Inv == FALSE"
  , "======================================================"
  ]

-- | Fork the mirror on one end of a mock transport and drive the validate-only
-- path from the other, returning the client's result and the mirror's step
-- trace (for structural assertions).
runValidateFlow :: MockTransport -> MockTransport -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ValidateResult, Either String [MirrorStep])
runValidateFlow clientEnd mirrorEnd cfg bound mSpec = do
  mv <- newEmptyMVar
  _ <- forkIO $ do
    result <- try (run mirrorEnd)
    putMVar mv $ case result of
      Right stps -> Right stps
      Left (e :: SomeException) -> Left (show e)
  clientResult <- runClientValidate clientEnd cfg bound mSpec
  mSteps <- timeout 180_000_000 (readMVar mv)
  let mirrorResult = case mSteps of
        Nothing -> Left "mirror did not complete within timeout"
        Just r  -> r
  pure (clientResult, mirrorResult)

testRunMirrorValidate :: TestTree
testRunMirrorValidate = testCase "validate-only path validates HourClock" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd hcApalacheCfg 1 Nothing
  case clientResult of
    Left e -> assertFailure $ "client validate failed: " ++ T.unpack e
    Right SpecValid -> pure ()
    Right (SpecInvalid e) -> assertFailure $ "unexpected SpecInvalid: " ++ T.unpack e
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendSpecValidatedValid] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)

testRunMirrorValidateInline :: TestTree
testRunMirrorValidateInline = testCase "validate-only path validates an inline spec" $ do
  inlineSpec <- mkSpecFromFile "test/specs/HourClock.tla"
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd hcApalacheCfg 1 (Just inlineSpec)
  case clientResult of
    Left e -> assertFailure $ "client validate failed: " ++ T.unpack e
    Right SpecValid -> pure ()
    Right (SpecInvalid e) -> assertFailure $ "unexpected SpecInvalid: " ++ T.unpack e
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendSpecValidatedValid] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)

testRunMirrorValidateInvalid :: TestTree
testRunMirrorValidateInvalid = testCase "validate-only path reports SpecInvalid for a violated invariant" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  let cfg = hcApalacheCfg { invariant = T.pack "Inv" }
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd cfg 1 (Just invalidSpec)
  case clientResult of
    Right (SpecInvalid _) -> pure ()
    Right SpecValid -> assertFailure "expected invalid spec to fail, but mirror reported valid"
    Left e -> assertFailure $ "expected SpecInvalid, got infrastructure error: " ++ T.unpack e
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendSpecValidatedInvalid{}] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)

testRunMirrorValidateBadInline :: TestTree
testRunMirrorValidateBadInline = testCase "validate-only path rejects an unparseable inline spec" $ do
  let badSpec = mkSpecFromSource "not a TLA module"
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd hcApalacheCfg 1 (Just badSpec)
  case clientResult of
    Left _ -> pure ()  -- RegisterError surfaces as Left (infrastructure tier)
    Right _ -> assertFailure "expected RegisterError, but client succeeded"
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendRegisterError{}] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)

-- | The mirror rejects a client-requested bound above the server-side cap
-- (REJECT, not clamp): the rejection must happen before any spec
-- materialization or apalache run, so the only observable protocol
-- traffic is RegisterError.
testRunMirrorValidateBoundTooHigh :: TestTree
testRunMirrorValidateBoundTooHigh = testCase "validate-only path rejects a bound above maxValidateBound" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd hcApalacheCfg (maxValidateBound + 1) Nothing
  case clientResult of
    Left _ -> pure ()  -- RegisterError surfaces as Left (infrastructure tier)
    Right _ -> assertFailure "expected RegisterError, but client succeeded"
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendRegisterError{}] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)

-- | Bounds below 1 are equally nonsensical (apalache would fail or misbehave
-- on @--length=0@), so the same server-side rejection applies.
testRunMirrorValidateBoundNonPositive :: TestTree
testRunMirrorValidateBoundNonPositive = testCase "validate-only path rejects a non-positive bound" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd hcApalacheCfg 0 Nothing
  case clientResult of
    Left _ -> pure ()  -- RegisterError surfaces as Left (infrastructure tier)
    Right _ -> assertFailure "expected RegisterError, but client succeeded"
  case mirrorResult of
    Left e -> assertFailure e
    Right [MirrorRecvRegisterValidate{}, MirrorSendRegisterError{}] -> pure ()
    Right steps -> assertFailure $ "unexpected steps: " ++ show (map mirrorStepActionName steps)


testRegisterValidateJsonRoundtrip :: TestTree
testRegisterValidateJsonRoundtrip = testCase "register_validate JSON roundtrip" $ do
  let noSpec :: ClientMessage
      noSpec = RegisterValidate hcApalacheCfg 7 Nothing
  decode (encode noSpec) @?= Just noSpec
  inlineSpec <- mkSpecFromFile "test/specs/HourClock.tla"
  let withSpec :: ClientMessage
      withSpec = RegisterValidate hcApalacheCfg 7 (Just inlineSpec)
  decode (encode withSpec) @?= Just withSpec

-- | JSON roundtrips for the whole @Register*@ family, so @register_validate@
-- sits alongside the other registration messages.
testRegisterFamilyJsonRoundtrips :: TestTree
testRegisterFamilyJsonRoundtrips = testCase "register* messages JSON roundtrip" $ do
  let mSpec = mkSpecFromSource "---- MODULE M ----"
      msgs :: [ClientMessage]
      msgs =
        [ Register hcApalacheCfg hcTraceConfig Nothing
        , Register hcApalacheCfg hcTraceConfig (Just mSpec)
        , RegisterTraces hcApalacheCfg ["a.itf.json", "b.itf.json"]
        , RegisterGenTraces hcApalacheCfg hcTraceConfig (Just "dest") Nothing
        , RegisterGenTraces hcApalacheCfg hcTraceConfig Nothing (Just mSpec)
        , RegisterExplore mSpec [] [] 10
        , RegisterExploreSession mSpec [] []
        ]
  mapM_ (\m -> decode (encode m) @?= Just m) msgs

testValidateConformanceNames :: TestTree
testValidateConformanceNames = testCase "validate step action names match the TLA model" $ do
  mirrorStepActionName (MirrorRecvRegisterValidate hcApalacheCfg 1 Nothing) @?= T.pack "MirrorRecvRegisterValidate"
  mirrorStepActionName MirrorSendSpecValidatedValid @?= T.pack "MirrorSendSpecValidatedValid"
  mirrorStepActionName (MirrorSendSpecValidatedInvalid (T.pack "x")) @?= T.pack "MirrorSendSpecValidatedInvalid"

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
      assertBool "trace must include mirror_phase variable" (T.pack "mirror_phase" `elem` nvars)
      assertBool "trace must include client_to_mirror variable" (T.pack "client_to_mirror" `elem` nvars)
      assertBool "trace must include mirror_to_client variable" (T.pack "mirror_to_client" `elem` nvars)
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

  -- Validate traces are driven separately (checkValidateTraceAgainstMirror);
  -- RegisterError-outcome traces stay excluded: infrastructure failures
  -- can't be forced deterministically from the client side.
  let excluded = [T.pack "ClientRegisterGenTraces"
                 ,T.pack "ClientRegisterExplore"
                 ,T.pack "ClientRegisterExploreSession"
                 ,T.pack "ClientRecvRegisterError"
                 ,T.pack "MirrorSendRegisterError"
                 ]
      actsOf t = map actionTake (traceStates t)
      applicable = filter (\t -> not (any (`elem` excluded) (actsOf t))) traces
      (validateTraces, mirrorTraces) =
        partition (\t -> T.pack "ClientRegisterValidate" `elem` actsOf t) applicable
  assertBool "at least one applicable trace" (not (null applicable))

  forM_ mirrorTraces $ checkTraceAgainstMirror hcTracePaths
  forM_ validateTraces checkValidateTraceAgainstMirror

-- | Replay one validate-only model trace against the real mirror (mock
-- transport), then compare the mirror's step trace against the model's
-- mirror-action sequence. The model chooses the verdict nondeterministically,
-- so the fixture follows the trace: valid-outcome traces are driven against
-- HourClock (always valid), invalid-outcome traces against the inline
-- 'invalidSpec' (@Inv == FALSE@, invalid at any bound).
checkValidateTraceAgainstMirror :: ItfTrace -> IO ()
checkValidateTraceAgainstMirror trace = do
  let expectedMirror = [ actionTake s
                       | s <- drop 1 (traceStates trace)
                       , T.pack "Mirror" `T.isPrefixOf` actionTake s
                       ]
      expectInvalid = T.pack "MirrorSendSpecValidatedInvalid" `elem` expectedMirror
      (cfg, mSpec)
        | expectInvalid = (hcApalacheCfg { invariant = T.pack "Inv" }, Just invalidSpec)
        | otherwise     = (hcApalacheCfg, Nothing)
  (clientEnd, mirrorEnd) <- newMockTransport
  (clientResult, mirrorResult) <- runValidateFlow clientEnd mirrorEnd cfg 1 mSpec
  case (expectInvalid, clientResult) of
    (False, Right SpecValid)        -> pure ()
    (True, Right (SpecInvalid _))   -> pure ()
    _ -> assertFailure $ "validate client result mismatch (expected "
                          ++ (if expectInvalid then "invalid" else "valid")
                          ++ "): " ++ show clientResult
  case mirrorResult of
    Left e -> assertFailure e
    Right steps ->
      unless (map mirrorStepActionName steps == expectedMirror) $
        assertFailure $ unlines
          [ "validate protocol trace mismatch:"
          , "  spec: " ++ show expectedMirror
          , "  impl: " ++ show (map mirrorStepActionName steps)
          ]

-- | Replay one model trace against the real mirror (mock transport),
-- following its report_matches guidance, then compare protocol structure
-- and report branches. Shared by the freshly-sampled MBT test and the
-- checked-in witness-trace regression test.
checkTraceAgainstMirror :: [FilePath] -> ItfTrace -> IO ()
checkTraceAgainstMirror hcTracePaths trace = do
  let steps = drop 1 (traceStates trace)
      isDone s = case (Map.lookup (T.pack "mirror_phase") (stateVars s), Map.lookup (T.pack "client_phase") (stateVars s)) of
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
      isReportAction a = a `elem` [ T.pack "MirrorRecvReportOk"
                                  , T.pack "MirrorRecvReportAllDone"
                                  , T.pack "MirrorRecvReportMismatch" ]
      specStepCount = length [ () | s <- cycleSteps, isReportAction (actionTake s) ]
      -- The model decides each report branch via report_matches (set at
      -- ClientReport); extract the bit sequence so the driver can follow it.
      reportBits = [ b | s <- cycleSteps
                       , actionTake s == T.pack "ClientReport"
                       , Just (VBool b) <- [Map.lookup (T.pack "report_matches") (stateVars s)]
                       ]
      anyMismatch = False `elem` reportBits

  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- newEmptyMVar
  _ <- forkIO $ do
    result <- try (run mirrorEnd)
    putMVar mv $ case result of
      Right stps -> Right stps
      Left (e :: SomeException) -> Left (show e)

  client <- hourClockClient clientEnd
  -- On reports where the model chose report_matches = FALSE, send a
  -- deliberately wrong state so the mirror must answer StepMismatch.
  -- Handler calls correspond 1:1 with ClientReport actions, in order.
  bitsRef <- newIORef reportBits
  let guidedClient = client
        { clientHandler = \action prevState -> do
            bits <- readIORef bitsRef
            let (matches, rest) = case bits of
                  [] -> (True, [])
                  (b : bs) -> (b, bs)
            writeIORef bitsRef rest
            if matches
              then clientHandler client action prevState
              else pure wrongState
        }
  clientResult <- runClientWithTraces guidedClient hcApalacheCfg hcTracePaths
  case (anyMismatch, clientResult) of
    (False, Right ()) -> pure ()
    (True, Left _) -> pure ()
    (False, Left e) -> assertFailure ("client failed on an all-match trace: " ++ T.unpack e)
    (True, Right ()) -> assertFailure "client succeeded on a trace containing a mismatch report"

  mResult <- timeout 180_000_000 (readMVar mv)
  case mResult of
    Nothing -> assertFailure "mirror did not complete within timeout"
    Just (Left e) -> assertFailure $ "mirror threw exception: " ++ e
    Just (Right implSteps) -> do
      let -- structure comparison: collapse all report branches to a
          -- single label (old behavior)
          isReport a = a `elem` [ T.pack "MirrorRecvReportOk"
                                , T.pack "MirrorRecvReportAllDone"
                                , T.pack "MirrorRecvReportMismatch" ]
          structCanon a
            | a == T.pack "MirrorSendStepOk" = T.pack "MirrorRecvReport"
            | a == T.pack "MirrorSendStepMismatch" = T.pack "MirrorRecvReport"
            | a == T.pack "MirrorRecvReportState" = T.pack "MirrorRecvReport"
            | otherwise = a
          specShape = [ if isReport a then T.pack "MirrorRecvReport" else a | a <- specActions ]
          implActions = map (structCanon . mirrorStepActionName) (normalize implSteps)
          implTrimmed = take (2 * specStepCount + 1) implActions
      unless (specShape == implTrimmed) $
        assertFailure $ unlines $
          ("protocol trace mismatch:")
          : [ "  spec:   " ++ show specShape
            , "  impl:   " ++ show implTrimmed
            , "  raw:    " ++ show (map mirrorStepActionName implSteps)
            ]
      -- branch comparison: the model's report branches are controllable
      -- via report_matches. All but the last spec branch are Ok and must
      -- match exactly; a final Mismatch must match exactly; a final
      -- AllDone abstracts the impl's remaining steps, so the impl's
      -- report at that position may be Ok or AllDone, but the impl run
      -- must contain no Mismatch anywhere.
      let branchOf a
            | a == T.pack "MirrorRecvReportOk" = T.pack "ReportOk"
            | a == T.pack "MirrorRecvReportAllDone" = T.pack "ReportAllDone"
            | a == T.pack "MirrorRecvReportMismatch" = T.pack "ReportMismatch"
            | otherwise = a
          specBranches = [ branchOf a | a <- specActions, isReport a ]
          implBranchOf a
            | a == T.pack "MirrorSendStepOk" = Just (T.pack "ReportOk")
            | a == T.pack "MirrorSendStepMismatch" = Just (T.pack "ReportMismatch")
            | a == T.pack "MirrorRecvReportState" = Just (T.pack "ReportAllDone")
            | otherwise = Nothing
          implBranchesAll = [ b | s <- normalize implSteps
                                , Just b <- [implBranchOf (mirrorStepActionName s)]
                                ]
          n = length specBranches
      assertBool "impl has at least as many reports as the spec" (length implBranchesAll >= n)
      let implBranches = take n implBranchesAll
      case reverse specBranches of
        [] -> pure ()
        (lastSpec : initRev) -> do
          let initSpecs = reverse initRev
          unless (initSpecs == take (length initSpecs) implBranches) $
            assertFailure $ unlines
              [ "report branch mismatch (prefix):"
              , "  spec: " ++ show specBranches
              , "  impl: " ++ show implBranchesAll
              ]
          let implLast = last implBranches
              okLast = case lastSpec of
                _ | lastSpec == T.pack "ReportMismatch" -> implLast == T.pack "ReportMismatch"
                  | lastSpec == T.pack "ReportAllDone" ->
                      implLast `elem` [T.pack "ReportOk", T.pack "ReportAllDone"]
                        && T.pack "ReportMismatch" `notElem` implBranchesAll
                  | otherwise -> implLast == lastSpec
          unless okLast $
            assertFailure $ unlines
              [ "report branch mismatch (final):"
              , "  spec last: " ++ show lastSpec
              , "  impl at pos: " ++ show implLast
              , "  impl all: " ++ show implBranchesAll
              ]

-- | Checked-in witness traces (specs/traces/, regenerated from
-- MirrorProtocolWitness.tla by scripts/gen-witness-traces.sh and kept
-- up-to-date in CI) replayed as fixed regression scenarios.
testWitnessTracesFixed :: TestTree
testWitnessTracesFixed = testCase "witness traces replay as fixed scenarios" $ do
  files <- filter (T.isSuffixOf (T.pack ".itf.json") . T.pack) <$> listDirectory "specs/traces"
  assertBool "at least one witness trace" (not (null files))
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure (take 1 ps)
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err
  forM_ files $ \f -> do
    etrace <- readTrace ("specs/traces" </> f)
    trace <- case etrace of
      Left err -> assertFailure (f ++ ": readTrace failed: " ++ err)
      Right t -> pure t
    let acts = map actionTake (traceStates trace)
        exploreActs = [T.pack "ClientRegisterExploreSession", T.pack "ClientExploreCmd", T.pack "ClientExploreDone"]
    -- fault traces need a closable transport (covered by
    -- testPrematureCloseTcp); explorer sessions are covered by
    -- ExploreMirrorSpec
    if T.pack "ClientCloseConn" `elem` acts || any (`elem` exploreActs) acts
      then pure ()
      else if T.pack "MirrorSendRegisterError" `elem` acts
        then driveRegisterErrorScenario f
        else checkTraceAgainstMirror hcTracePaths trace

-- | The register_error witness: a registration the mirror must reject.
-- Driven deterministically with a nonexistent trace path.
driveRegisterErrorScenario :: String -> IO ()
driveRegisterErrorScenario fname = do
  (clientEnd, mirrorEnd) <- newMockTransport
  _ <- forkIO $ (run mirrorEnd >> pure ())
        `catch` (\(_ :: SomeException) -> pure ())
  sendMsg clientEnd (RegisterTraces hcApalacheCfg ["/nonexistent/trace.itf.json"])
  msg <- recvMsg clientEnd
  case msg of
    Right (RegisterError _) -> pure ()
    other -> assertFailure (fname ++ ": expected register_error, got " ++ showMsg other)

wrongState :: Map.Map Text Value
wrongState = Map.singleton (T.pack "hr") (VInt 999)

-- -----------------------------------------------------------------------------
-- MBT over real transports (item: transport coverage)
--
-- The mock-based MBT test compares mirror-internal step traces; over real
-- transports only client-visible behavior is compared (message flow and
-- final result), driven by the same model traces and the same
-- report_matches guidance. Gated behind the MBT_TRANSPORTS env var
-- (comma-separated subset of "stdio,tcp,tls"); with no env var the test
-- is a no-op.
-- -----------------------------------------------------------------------------

newtype Runner = Runner { withRunner :: forall a. (forall t. Transport t => t -> IO a) -> IO a }

-- | Client side of a spawned mirror process speaking stdio.
data ProcTransport = ProcTransport Handle Handle

instance Transport ProcTransport where
  send (ProcTransport hin _) bs = B8.hPutStrLn hin bs >> hFlush hin
  recv (ProcTransport _ hout) = do
    r <- try (B8.hGetLine hout) :: IO (Either IOException B8.ByteString)
    pure (either (const B8.empty) id r)

stdioRunner :: FilePath -> Runner
stdioRunner bin = Runner $ \k -> do
  (Just hin, Just hout, _, ph) <- createProcess (proc bin [])
    { std_in = CreatePipe, std_out = CreatePipe }
  r <- k (ProcTransport hin hout)
  terminateProcess ph
  _ <- waitForProcess ph
  pure r

tcpRunner :: Runner
tcpRunner = Runner $ \k -> do
  port <- freePort'
  tid <- forkIO (serveTcp port)
  threadDelay 200000
  s <- connectLoop 20 port
  t <- tcpTransport s
  r <- k t
  close s
  killThread tid
  pure r

tlsRunner :: Certs -> Runner
tlsRunner certs = Runner $ \k -> do
  port <- freePort'
  serverParams <- mkServerParams (serverCrt certs) (serverKey certs) (caCrt certs)
  tid <- forkIO (serveTlsConcurrent 2 serverParams port)
  threadDelay 200000
  clientParams <- mkClientParams "127.0.0.1" (clientCrt certs) (clientKey certs) (caCrt certs)
  t <- connectTls clientParams "127.0.0.1" port
  r <- k t
  killThread tid
  pure r

freePort' :: IO PortNumber
freePort' = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
  case addrs of
    [] -> error "freePort': cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind s (addrAddress addr)
      SockAddrInet p _ <- getSocketName s
      close s
      pure p

connectLoop :: Int -> PortNumber -> IO Socket
connectLoop retries port = do
  addrs <- getAddrInfo (Just defaultHints) (Just "127.0.0.1") (Just (show port))
  case addrs of
    [] -> error "connectLoop: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      r <- try (connect s (addrAddress addr))
      case r of
        Right () -> pure s
        Left (_ :: IOException)
          | retries > 0 -> close s >> threadDelay 100000 >> connectLoop (retries - 1) port
          | otherwise   -> close s >> error "connectLoop: connection refused"

mirrorBin :: IO FilePath
mirrorBin = do
  mEnv <- lookupEnv "MODELMIRRORS_BIN"
  case mEnv of
    Just b -> pure b
    Nothing -> do
      out <- readProcess "cabal" ["list-bin", "ModelMirrors"] ""
      case lines out of
        (b : _) -> pure b
        [] -> error "mirrorBin: cabal list-bin returned empty output"

testMbtTransports :: TestTree
testMbtTransports = testCase "mbt over stdio/tcp/tls (MBT_TRANSPORTS)" $ do
  mEnv <- lookupEnv "MBT_TRANSPORTS"
  let enabled = maybe [] (T.splitOn (T.pack ",") . T.pack) mEnv
  if null enabled
    then pure ()
    else do
      genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
      hcTracePaths <- case genResult of
        Right (_, ps) -> pure (take 1 ps)
        Left err -> assertFailure $ "pre-generate traces error: " ++ show err
      traces <- generateMirrorTraces
      -- ClientRegisterValidate stays excluded here: validate-only over real
      -- transports is covered by the MainSpec CLI integration tests; the
      -- mock-transport MBT (testMbtMirrorProtocol) drives validate traces.
      let applicable = filter (\t ->
            let acts = map actionTake (traceStates t)
            in not (any (`elem` [T.pack "ClientRegisterGenTraces"
                                ,T.pack "ClientRegisterExplore"
                                ,T.pack "ClientRegisterExploreSession"
                                ,T.pack "ClientRegisterValidate"
                                ,T.pack "ClientRecvRegisterError"
                                ,T.pack "MirrorSendRegisterError"
                                ]) acts)
            ) traces
      assertBool "at least one applicable trace" (not (null applicable))
      certs <- genCerts
      bin <- mirrorBin
      let runners :: [(Text, Runner)]
          runners = concat
            [ [("stdio", stdioRunner bin) | T.pack "stdio" `elem` enabled]
            , [("tcp", tcpRunner) | T.pack "tcp" `elem` enabled]
            , [("tls", tlsRunner certs) | T.pack "tls" `elem` enabled]
            ]
      forM_ runners $ \(tname, runner) ->
        forM_ (zip [1 :: Int ..] applicable) $ \(n, trace) -> do
          let steps = drop 1 (traceStates trace)
              reportBits = [ b | s <- steps
                               , actionTake s == T.pack "ClientReport"
                               , Just (VBool b) <- [Map.lookup (T.pack "report_matches") (stateVars s)]
                               ]
              anyMismatch = False `elem` reportBits
          withRunner runner $ \c -> do
            client <- hourClockClient c
            bitsRef <- newIORef reportBits
            let guidedClient = client
                  { clientHandler = \action prevState -> do
                      bits <- readIORef bitsRef
                      let (matches, rest) = case bits of
                            [] -> (True, [])
                            (b : bs) -> (b, bs)
                      writeIORef bitsRef rest
                      if matches
                        then clientHandler client action prevState
                        else pure wrongState
                  }
            clientResult <- runClientWithTraces guidedClient hcApalacheCfg hcTracePaths
            case (anyMismatch, clientResult) of
              (False, Right ()) -> pure ()
              (True, Left _) -> pure ()
              (False, Left e) -> assertFailure (T.unpack tname ++ " trace " ++ show n ++ ": client failed on all-match trace: " ++ T.unpack e)
              (True, Right ()) -> assertFailure (T.unpack tname ++ " trace " ++ show n ++ ": client succeeded on a mismatch trace")

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
                Right (GenTracesDone _ _) -> True
                _ -> False
          pure (i, ("recv GenTracesDone", ok, showMsg msg))
        "ClientReport" -> do
          sendMsg clientEnd $ ReportState dummyState
          pure (i, ("send ReportState", True, "ok"))
        _ | at == "MirrorSendSpecValidatedValid" || at == "MirrorSendRegisterError" -> do
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
        _ | at `elem` ["MirrorRecvReportOk", "MirrorRecvReportAllDone", "MirrorRecvReportMismatch"] -> do
          msg <- recvOrDie "step result"
          let ok = case msg of
                Right StepOk             -> True
                Right (StepMismatch _ _ _) -> True
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
                Right (GenTracesDone _ _) -> True
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

-- -----------------------------------------------------------------------------
-- Fault injection (impl side): out-of-order, garbage, and premature-close
-- inputs must yield protocol_error / clean disconnect, never a hang.
-- Model side lives in specs/MirrorProtocolFaults.tla.
-- -----------------------------------------------------------------------------

testOutOfOrderFirstMessage :: TestTree
testOutOfOrderFirstMessage = testCase "out-of-order first message gets protocol_error" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  done <- newEmptyMVar
  _ <- forkIO $ run mirrorEnd
        >> putMVar done True
        `catch` (\(_ :: SomeException) -> putMVar done False)
  sendMsg clientEnd (ReportState dummyState)
  msg <- recvMsg clientEnd
  case msg of
    Right (ProtocolError _) -> pure ()
    other -> assertFailure ("expected protocol_error, got " ++ showMsg other)

testGarbageMidSession :: TestTree
testGarbageMidSession = testCase "garbage mid-session gets protocol_error" $ do
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure (take 1 ps)
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err
  (clientEnd, mirrorEnd) <- newMockTransport
  _ <- forkIO $ (runMirrorWithTraces mirrorEnd hcApalacheCfg hcTracePaths >> pure ())
        `catch` (\(_ :: SomeException) -> pure ())
  _ <- recvOrDie' "SpecValidated" clientEnd :: IO (Either String MirrorMessage)
  _ <- recvOrDie' "InitialState" clientEnd :: IO (Either String MirrorMessage)
  send clientEnd (B8.pack "garbage")
  msg <- recvMsg clientEnd
  case msg of
    Right (ProtocolError _) -> pure ()
    other -> assertFailure ("expected protocol_error, got " ++ showMsg other)

testPrematureCloseTcp :: TestTree
testPrematureCloseTcp = testCase "premature close ends the session; server keeps accepting" $ do
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  hcTracePaths <- case genResult of
    Right (_, ps) -> pure (take 1 ps)
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err
  port <- freePort'
  tid <- forkIO (serveTcp port)
  threadDelay 200000
  -- first client: register, then vanish mid-session
  s1 <- connectLoop 20 port
  t1 <- tcpTransport s1
  sendMsg t1 (RegisterTraces hcApalacheCfg hcTracePaths)
  _ <- recvOrDie' "SpecValidated" t1 :: IO (Either String MirrorMessage)
  tcpClose t1
  threadDelay 300000
  -- second client: proves the first session ended and the accept loop
  -- survived the dropped connection
  s2 <- connectLoop 20 port
  t2 <- tcpTransport s2
  send t2 (B8.pack "garbage")
  msg <- recvMsg t2
  case msg of
    Right (ProtocolError _) -> pure ()
    other -> assertFailure ("expected protocol_error, got " ++ showMsg other)
  tcpClose t2
  killThread tid

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
