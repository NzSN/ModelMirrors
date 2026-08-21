-- | Async job machinery tests (docs/async-operations-design.md §9).
--
-- Coverage:
--
-- 1. 'Protocol.Transport.Mock' round-trips: submit → poll / long-poll →
--    result for both async paths against 'Protocol.Mirror.runAsyncSession',
--    using an injected fake 'JobRunner' so no apalache-mc is needed. The
--    step log is asserted via 'Protocol.Mirror.normalizeMirrorSteps'.
-- 2. Error tiers: bad bound and spec-materialization failure are
--    pre-accept @register_error@; a forced apalache failure (exit 255) is a
--    post-accept 'JobInfraError'; an unknown 'JobId' in query / await /
--    cancel is 'JobUnknown'.
-- 3. Concurrency and GC: capacity 1 serializes submissions (a second live
--    submit is rejected pre-accept with @job queue full@) and
--    'closeJobStore' kills a running job and removes its temp dirs.
-- 4. Integration against real apalache-mc: HourClock async validate and
--    async trace generation via 'runAsyncSession' with the default runner
--    (alongside, not replacing, the existing sync cases).
module Protocol.AsyncJobsSpec (spec) where

import Apalache.Command (ApalacheResult (..))
import Apalache.Rpc.Types (ApalacheSpec (..))
import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , ValidateResult (..)
  )
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Data.IORef
  ( IORef
  , newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.AsyncJobs
  ( JobRunner
  , JobStore
  , awaitJob
  , cancelJob
  , closeJobStore
  , newJobStore
  , newJobStoreWith
  , queryJob
  , submitGenTracesJob
  , submitValidateJob
  )
import qualified Protocol.Client as Client
  ( runClientGenTracesAsync
  , runClientValidateAsync
  , submitValidateAsync
  )
import Protocol.Core
  ( ClientMessage (QueryJob)
  , JobId (..)
  , JobOutcome (..)
  , JobPhase (..)
  , MirrorMessage (..)
  )
import Protocol.Format.Json ()
import Protocol.Mirror
  ( MirrorStep
  , normalizeMirrorSteps
  , runAsyncSession
  )
import Protocol.Transport.Core (Transport (..), recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

spec :: TestTree
spec = testGroup "Protocol.AsyncJobsSpec"
  [ testValidateRoundTrip
  , testGenTracesRoundTrip
  , testBadBoundRejectedPreAccept
  , testMaterializationFailureRejectedPreAccept
  , testForcedApalacheFailureIsInfraError
  , testUnknownJobId
  , testCapacityOneSerializes
  , testCancelRunningJob
  , testSessionCloseGC
  , testIntegrationHourClockValidate
  , testIntegrationHourClockGenTraces
  ]

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

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

okResult :: ApalacheResult
okResult = ApalacheResult ExitSuccess "all good" ""

fail255Result :: ApalacheResult
fail255Result = ApalacheResult (ExitFailure 255) "boom" ""

-- | A fake job body: ignores its arguments and always succeeds. For the
-- validate flow the runner is invoked twice (typecheck then check); both
-- invocations return 'ExitSuccess', so the job ends 'JobValidateDone
-- SpecValid' without any apalache-mc involved.
fakeOkRunner :: JobRunner
fakeOkRunner _ _ _ _ = pure (Right okResult)

-- | A fake job body that always fails with apalache's infra exit code
-- (255), exercising the post-accept 'JobInfraError' tier through the real
-- exit-code classification in 'Apalache.Command.validateSpecVia'.
fakeFail255Runner :: JobRunner
fakeFail255Runner _ _ _ _ = pure (Right fail255Result)

-- | Minimal well-formed JSON trace content:
-- @{\"#meta\":{\"tracer\":\"fake\"},\"vars\":[\"x\"]}@ as raw bytes.
fakeTraceJson :: BS.ByteString
fakeTraceJson = BS.pack
  [123, 34, 35, 109, 101, 116, 97, 34, 58, 123, 34, 116, 114, 97, 99
  , 101, 114, 34, 58, 34, 102, 97, 107, 101, 34, 125, 44, 34, 118, 97
  , 114, 115, 34, 58, 91, 34, 120, 34, 93, 125
  ]

-- | A fake job body for the trace-generation flow: creates a fake ITF
-- output directory (inside the job's own run dir, reported exactly the way
-- apalache does) containing one well-formed JSON trace file.
fakeGenTracesRunner :: JobRunner
fakeGenTracesRunner _ (Just runDir) _ _ = do
  let outDir = runDir </> "fake-apalache-out"
  createDirectoryIfMissing True outDir
  LBS.writeFile (outDir </> "1.itf.json") (LBS.fromStrict fakeTraceJson)
  pure (Right (ApalacheResult ExitSuccess ("Output directory: " ++ outDir) ""))
fakeGenTracesRunner _ Nothing _ _ =
  pure (Right fail255Result)

-- | A fake job body that records the job's run dir and then blocks until
-- the test releases it (via 'readMVar', which does not consume the token,
-- so later invocations of the same job pass through once released).
fakeBlockingRunner :: MVar () -> IORef (Maybe FilePath) -> JobRunner
fakeBlockingRunner release dirRef _ mRunDir _ _ = do
  writeIORef dirRef mRunDir
  _ <- readMVar release
  pure (Right okResult)

-- | Fork 'runAsyncSession' on one end of a mock transport; the MVar holds
-- the mirror's accumulated step log once the session ends.
forkAsyncSession :: MockTransport -> JobStore -> IO (MVar [MirrorStep])
forkAsyncSession mirrorEnd store = do
  mv <- newEmptyMVar
  _ <- forkIO (runAsyncSession mirrorEnd store >>= putMVar mv)
  pure mv

-- | End the session from the client side by feeding the mirror a frame that
-- does not decode as a 'Protocol.Core.ClientMessage'; the session answers a
-- best-effort protocol error, GCs its jobs, and returns the step log.
endAsyncSession :: MockTransport -> MVar [MirrorStep] -> IO [MirrorStep]
endAsyncSession clientEnd stepsVar = do
  send clientEnd (BS.singleton 0x5d) -- ']' : valid JSON, no ClientMessage
  takeMVar stepsVar

-- | Poll 'queryJob' until the phase matches or the attempt budget is spent.
waitForPhase :: JobStore -> JobId -> (JobPhase -> Bool) -> Int -> IO Bool
waitForPhase _ _ _ 0 = pure False
waitForPhase store jid p n = do
  (phase, _) <- queryJob store jid
  if p phase then pure True else threadDelay 10000 >> waitForPhase store jid p (n - 1)

expectRegisterError :: Either Text a -> IO ()
expectRegisterError (Left _) = pure ()
expectRegisterError (Right _) = assertFailure "expected register error, got acceptance"

-- -----------------------------------------------------------------------------
-- 1. MockTransport round-trips (fake job body, no apalache)
-- -----------------------------------------------------------------------------

testValidateRoundTrip :: TestTree
testValidateRoundTrip = testCase "async validate round-trip via MockTransport with fake job body" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  store <- newJobStoreWith 4 fakeOkRunner
  stepsVar <- forkAsyncSession mirrorEnd store
  out <- Client.runClientValidateAsync clientEnd hcApalacheCfg 1 Nothing
  case out of
    Right SpecValid -> pure ()
    Right (SpecInvalid e) -> assertFailure ("unexpected SpecInvalid: " ++ T.unpack e)
    Left e -> assertFailure ("client validate failed: " ++ T.unpack e)
  steps <- endAsyncSession clientEnd stepsVar
  normalizeMirrorSteps steps @?=
    map T.pack
      [ "MirrorRecvRegisterValidateAsync"
      , "MirrorSendJobAccepted"
      , "MirrorRecvJobAwait"
      , "MirrorSendJobResult"
      ]

testGenTracesRoundTrip :: TestTree
testGenTracesRoundTrip = testCase "async gen-traces round-trip via MockTransport with fake job body" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  store <- newJobStoreWith 4 fakeGenTracesRunner
  stepsVar <- forkAsyncSession mirrorEnd store
  out <- Client.runClientGenTracesAsync clientEnd hcApalacheCfg hcTraceConfig Nothing Nothing
  case out of
    Left e -> assertFailure ("client gen-traces failed: " ++ T.unpack e)
    Right (paths, contents) -> do
      assertBool "expected at least one trace path" (not (null paths))
      assertBool "expected at least one trace content" (not (null contents))
  steps <- endAsyncSession clientEnd stepsVar
  normalizeMirrorSteps steps @?=
    map T.pack
      [ "MirrorRecvRegisterGenTracesAsync"
      , "MirrorSendJobAccepted"
      , "MirrorRecvJobAwait"
      , "MirrorSendJobResult"
      ]

-- -----------------------------------------------------------------------------
-- 2. Error tiers
-- -----------------------------------------------------------------------------

testBadBoundRejectedPreAccept :: TestTree
testBadBoundRejectedPreAccept = testCase "bad bound is a pre-accept register error" $ do
  store <- newJobStoreWith 4 fakeOkRunner
  r0 <- submitValidateJob store hcApalacheCfg 0 Nothing
  expectRegisterError r0
  r101 <- submitValidateJob store hcApalacheCfg 101 Nothing
  expectRegisterError r101
  -- Mirror-level: the same guard answers RegisterError before job_accepted.
  (clientEnd, mirrorEnd) <- newMockTransport
  stepsVar <- forkAsyncSession mirrorEnd store
  r <- Client.submitValidateAsync clientEnd hcApalacheCfg 0 Nothing
  case r of
    Left e -> assertBool "error mentions the bound range"
      (T.isInfixOf (T.pack "outside allowed range") e)
    Right _ -> assertFailure "expected register error for bound 0"
  steps <- endAsyncSession clientEnd stepsVar
  normalizeMirrorSteps steps @?=
    map T.pack
      [ "MirrorRecvRegisterValidateAsync"
      , "MirrorSendRegisterError"
      ]

testMaterializationFailureRejectedPreAccept :: TestTree
testMaterializationFailureRejectedPreAccept =
  testCase "spec materialization failure is a pre-accept register error" $ do
    store <- newJobStoreWith 4 fakeOkRunner
    let badSpec = ApalacheSpec [T.pack "not a TLA module"]
    rv <- submitValidateJob store hcApalacheCfg 1 (Just badSpec)
    expectRegisterError rv
    rg <- submitGenTracesJob store hcApalacheCfg hcTraceConfig Nothing (Just badSpec)
    expectRegisterError rg
    (clientEnd, mirrorEnd) <- newMockTransport
    stepsVar <- forkAsyncSession mirrorEnd store
    r <- Client.submitValidateAsync clientEnd hcApalacheCfg 1 (Just badSpec)
    case r of
      Left _ -> pure ()
      Right _ -> assertFailure "expected register error for unmaterializable spec"
    steps <- endAsyncSession clientEnd stepsVar
    normalizeMirrorSteps steps @?=
      map T.pack
        [ "MirrorRecvRegisterValidateAsync"
        , "MirrorSendRegisterError"
        ]

testForcedApalacheFailureIsInfraError :: TestTree
testForcedApalacheFailureIsInfraError =
  testCase "forced apalache failure (exit 255) is a post-accept JobInfraError" $ do
    store <- newJobStoreWith 4 fakeFail255Runner
    r <- submitValidateJob store hcApalacheCfg 1 Nothing
    jid <- case r of
      Right j -> pure j
      Left e  -> assertFailure ("expected acceptance, got: " ++ T.unpack e)
    res <- awaitJob store jid Nothing
    case res of
      Right (JobInfraError e) ->
        assertBool "infra error mentions the fake failure output" (T.isInfixOf (T.pack "boom") e)
      Right other -> assertFailure ("expected JobInfraError, got: " ++ show other)
      Left e -> assertFailure ("await failed: " ++ T.unpack e)
    (phase, mOut) <- queryJob store jid
    phase @?= JobFailed
    case mOut of
      Just (JobInfraError _) -> pure ()
      other -> assertFailure ("expected retained JobInfraError, got: " ++ show other)

testUnknownJobId :: TestTree
testUnknownJobId = testCase "unknown jobId answers JobUnknown in query, await, and cancel" $ do
  store <- newJobStoreWith 4 fakeOkRunner
  let unknown = JobId (T.pack "job-nope")
  (phase, mOut) <- queryJob store unknown
  phase @?= JobUnknown
  mOut @?= Nothing
  a <- awaitJob store unknown Nothing
  case a of
    Left e -> e @?= T.pack "unknown"
    Right _ -> assertFailure "expected Left unknown from await"
  cancelJob store unknown -- no-op, must not throw
  (phase2, _) <- queryJob store unknown
  phase2 @?= JobUnknown
  -- Mirror-level: QueryJob for an unknown id answers job_status unknown.
  (clientEnd, mirrorEnd) <- newMockTransport
  stepsVar <- forkAsyncSession mirrorEnd store
  sendMsg clientEnd (QueryJob unknown)
  resp <- recvMsg clientEnd
  case resp of
    Right (JobStatus _ JobUnknown) -> pure ()
    other -> assertFailure ("expected JobStatus unknown, got: " ++ show other)
  steps <- endAsyncSession clientEnd stepsVar
  normalizeMirrorSteps steps @?=
    map T.pack ["MirrorRecvJobQuery", "MirrorSendJobStatus"]

-- -----------------------------------------------------------------------------
-- 3. Concurrency and GC
-- -----------------------------------------------------------------------------

testCapacityOneSerializes :: TestTree
testCapacityOneSerializes =
  testCase "capacity 1 serializes: second live submit rejected, resubmit after finish accepted" $ do
    release <- newEmptyMVar
    dirRef <- newIORef Nothing
    store <- newJobStoreWith 1 (fakeBlockingRunner release dirRef)
    r1 <- submitValidateJob store hcApalacheCfg 1 Nothing
    j1 <- case r1 of
      Right j -> pure j
      Left e  -> assertFailure ("first submit failed: " ++ T.unpack e)
    running <- waitForPhase store j1 (== JobRunning) 500
    assertBool "first job should be running" running
    -- While job 1 is live, capacity 1 rejects a second submit pre-accept.
    r2 <- submitValidateJob store hcApalacheCfg 1 Nothing
    case r2 of
      Left e -> e @?= T.pack "job queue full"
      Right _ -> assertFailure "expected queue-full rejection while job 1 is live"
    -- Release job 1; it completes and frees the capacity.
    putMVar release ()
    o1 <- awaitJob store j1 Nothing
    case o1 of
      Right (JobValidateDone SpecValid) -> pure ()
      other -> assertFailure ("expected first job SpecValid, got: " ++ show other)
    -- A fresh submit is accepted and runs (serialized after the first).
    r3 <- submitValidateJob store hcApalacheCfg 1 Nothing
    j3 <- case r3 of
      Right j -> pure j
      Left e  -> assertFailure ("resubmit failed: " ++ T.unpack e)
    o3 <- awaitJob store j3 Nothing
    case o3 of
      Right (JobValidateDone SpecValid) -> pure ()
      other -> assertFailure ("expected second job SpecValid, got: " ++ show other)
    closeJobStore store

testCancelRunningJob :: TestTree
testCancelRunningJob = testCase "cancelling a running job answers cancelled and frees capacity" $ do
  release <- newEmptyMVar
  dirRef <- newIORef Nothing
  store <- newJobStoreWith 1 (fakeBlockingRunner release dirRef)
  r <- submitValidateJob store hcApalacheCfg 1 Nothing
  jid <- case r of
    Right j -> pure j
    Left e  -> assertFailure ("submit failed: " ++ T.unpack e)
  running <- waitForPhase store jid (== JobRunning) 500
  assertBool "job should be running before cancel" running
  cancelJob store jid
  (phase, mOut) <- queryJob store jid
  phase @?= JobCancelled
  case mOut of
    Just (JobInfraError e) -> e @?= T.pack "job cancelled"
    other -> assertFailure ("expected cancelled result, got: " ++ show other)
  -- The slot is free again: a fresh submit is accepted on the same store.
  putMVar release ()
  r2 <- submitValidateJob store hcApalacheCfg 1 Nothing
  case r2 of
    Right _ -> pure ()
    Left e  -> assertFailure ("expected acceptance after cancel, got: " ++ T.unpack e)
  closeJobStore store

testSessionCloseGC :: TestTree
testSessionCloseGC =
  testCase "session close (closeJobStore) kills a running job and removes its temp dirs" $ do
    release <- newEmptyMVar
    dirRef <- newIORef Nothing
    store <- newJobStoreWith 1 (fakeBlockingRunner release dirRef)
    r <- submitValidateJob store hcApalacheCfg 1 Nothing
    jid <- case r of
      Right j -> pure j
      Left e  -> assertFailure ("submit failed: " ++ T.unpack e)
    running <- waitForPhase store jid (== JobRunning) 500
    assertBool "job should be running before close" running
    Just dir <- readIORef dirRef
    existsBefore <- doesDirectoryExist dir
    assertBool "job run dir should exist while running" existsBefore
    closeJobStore store
    (phase, mOut) <- queryJob store jid
    phase @?= JobCancelled
    case mOut of
      Just (JobInfraError e) -> e @?= T.pack "job cancelled"
      other -> assertFailure ("expected cancelled result after close, got: " ++ show other)
    existsAfter <- doesDirectoryExist dir
    assertBool "job run dir should be removed by closeJobStore" (not existsAfter)

-- -----------------------------------------------------------------------------
-- 4. Integration against real apalache-mc (slow; needs apalache-mc on PATH)
-- -----------------------------------------------------------------------------

integrationTimeout :: Int
integrationTimeout = 300 * 1000000 -- 300s per flow, like the sync specs

testIntegrationHourClockValidate :: TestTree
testIntegrationHourClockValidate =
  testCase "integration: async HourClock validate against real apalache" $ do
    (clientEnd, mirrorEnd) <- newMockTransport
    store <- newJobStore 1
    stepsVar <- forkAsyncSession mirrorEnd store
    mOut <- timeout integrationTimeout (Client.runClientValidateAsync clientEnd hcApalacheCfg 1 Nothing)
    case mOut of
      Nothing -> assertFailure "async validate timed out"
      Just (Left e) -> assertFailure ("client validate failed: " ++ T.unpack e)
      Just (Right SpecValid) -> pure ()
      Just (Right (SpecInvalid e)) -> assertFailure ("unexpected SpecInvalid: " ++ T.unpack e)
    steps <- endAsyncSession clientEnd stepsVar
    normalizeMirrorSteps steps @?=
      map T.pack
        [ "MirrorRecvRegisterValidateAsync"
        , "MirrorSendJobAccepted"
        , "MirrorRecvJobAwait"
        , "MirrorSendJobResult"
        ]

testIntegrationHourClockGenTraces :: TestTree
testIntegrationHourClockGenTraces =
  testCase "integration: async HourClock trace-gen against real apalache" $ do
    (clientEnd, mirrorEnd) <- newMockTransport
    store <- newJobStore 1
    stepsVar <- forkAsyncSession mirrorEnd store
    mOut <- timeout integrationTimeout
      (Client.runClientGenTracesAsync clientEnd hcApalacheCfg hcTraceConfig Nothing Nothing)
    case mOut of
      Nothing -> assertFailure "async gen-traces timed out"
      Just (Left e) -> assertFailure ("client gen-traces failed: " ++ T.unpack e)
      Just (Right (paths, contents)) -> do
        assertBool "expected at least one trace path" (not (null paths))
        assertBool "expected at least one trace content" (not (null contents))
        -- The delivered trace contents were read back from the generated
        -- files before the job's terminal transition released its run dir,
        -- so non-empty contents prove the files existed on disk.
    steps <- endAsyncSession clientEnd stepsVar
    normalizeMirrorSteps steps @?=
      map T.pack
        [ "MirrorRecvRegisterGenTracesAsync"
        , "MirrorSendJobAccepted"
        , "MirrorRecvJobAwait"
        , "MirrorSendJobResult"
        ]
