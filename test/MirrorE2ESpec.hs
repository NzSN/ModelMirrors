module MirrorE2ESpec (spec) where

import Apalache.Command (generateTraceFiles)
import Apalache.Rpc.Types (ApalacheSpec (..), mkSpecFromFile)
import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , Value (..)
  )
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException, catch)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Protocol.Client
  ( cannedClient
  , exploreSession
  , fixedClient
  , hourClockClient
  , runClient
  , runClientExplore
  , runClientGenTraces
  , runClientWithSpec
  , runClientWithTraces
  )
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Mirror (MirrorStep (..), run)
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Mock (MockTransport, newMockTransport)
import System.FilePath (takeExtension)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

-- | Full-stack end-to-end tests for the mirror.
--
-- Each test forks the real mirror entry point ('Protocol.Mirror.run') on one
-- end of a 'MockTransport' and drives the other end with a real client from
-- 'Protocol.Client'. The mirror talks to a real apalache-mc (CLI for trace
-- generation, explorer server for the explore flows), so these tests cover
-- the entire stack:
--
-- > client  <->  MockTransport  <->  mirror (run)  <->  apalache-mc
--
-- Assertions check both sides: the client's final result, and the mirror's
-- recorded @[MirrorStep]@ log (which 'MirrorStepSpec' and the MBT tests in
-- 'MirrorProtocolSpec' check against @specs/MirrorProtocol.tla@).
spec :: TestTree
spec = testGroup "MirrorE2ESpec"
  [ testRegisterHappyPath
  , testRegisterMismatch
  , testRegisterTracesHappyPath
  , testRegisterGenTraces
  , testExploreHappyPath
  , testExploreMismatch
  , testExploreSessionHappyPath
  , testRegisterInlineSpec
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

-- | Fork the mirror on @mirrorEnd@, returning an MVar that will hold the
-- mirror's recorded steps once it finishes. An exception (e.g. the client
-- disappearing mid-protocol) yields an empty step list rather than a hung
-- test.
forkMirror :: MockTransport -> IO (MVar [MirrorStep])
forkMirror mirrorEnd = do
  mv <- newEmptyMVar
  _ <- forkIO $ (run mirrorEnd >>= putMVar mv)
    `catch` (\(_ :: SomeException) -> putMVar mv [])
  pure mv

hasStep :: (MirrorStep -> Bool) -> [MirrorStep] -> Bool
hasStep p = any p

isMismatch :: MirrorStep -> Bool
isMismatch MirrorSendStepMismatch{} = True
isMismatch _ = False

isProtocolError :: MirrorStep -> Bool
isProtocolError MirrorSendProtocolError{} = True
isProtocolError _ = False

isRegisterError :: MirrorStep -> Bool
isRegisterError MirrorSendRegisterError{} = True
isRegisterError _ = False

-- | Shared "nothing went wrong" assertion: a successful run must not contain
-- mismatch, protocol-error, or register-error steps.
assertCleanSteps :: [MirrorStep] -> IO ()
assertCleanSteps steps = do
  assertBool "no step mismatches" (not (hasStep isMismatch steps))
  assertBool "no protocol errors" (not (hasStep isProtocolError steps))
  assertBool "no register errors" (not (hasStep isRegisterError steps))

-- | E2E, Register flow, happy path (MirrorProtocol.tla: ClientRegister ->
-- MirrorRecvRegister -> MirrorSendSpecValidatedValid -> MirrorSendInitialState
-- -> (MirrorRecvReportState)+ -> done).
--
-- The client sends @Register@; the mirror runs apalache-mc to generate
-- traces of HourClock (the TraceComplete "invariant" is violated at step 13,
-- producing a 13-tick counterexample trace), then replays every trace state
-- against the client. 'hourClockClient' is a faithful re-implementation of
-- HourClock: it echoes the initial state and computes each tick itself, so
-- every 'ReportState' should match the model's expected state.
--
-- Expected outcome: client returns @Right ()@ and the mirror's step log is
-- exactly the happy path: starts with 'MirrorRecvRegister', contains
-- 'MirrorSendSpecValidatedValid', ends with 'MirrorSendAllStepsDone', with no
-- mismatch or error steps anywhere.
testRegisterHappyPath :: TestTree
testRegisterHappyPath = testCase "e2e Register: hourClockClient passes verification" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  client <- hourClockClient clientEnd
  result <- runClient client hcApalacheCfg hcTraceConfig
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right () -> pure ()
  steps <- readMVar mv
  assertBool "mirror produced steps" (not (null steps))
  assertBool "starts with MirrorRecvRegister"
    (case steps of
      (MirrorRecvRegister _ _ _ : _) -> True
      _ -> False)
  assertBool "spec validated"
    (hasStep (\case MirrorSendSpecValidatedValid -> True; _ -> False) steps)
  assertBool "ends with MirrorSendAllStepsDone"
    (case reverse steps of
      (MirrorSendAllStepsDone : _) -> True
      _ -> False)
  assertCleanSteps steps

-- | E2E, Register flow, conformance-failure path (MirrorProtocol.tla:
-- MirrorRecvReportState with the mismatch branch, mp' = "done").
--
-- Same setup as the happy path, but the client is a 'fixedClient' that always
-- reports @{hr: 99}@ regardless of the actual HourClock state. The very first
-- replay step must therefore fail the mirror's 'diffState' check.
--
-- Expected outcome: the mirror replies @StepMismatch@ (recorded as
-- 'MirrorSendStepMismatch'), the client surfaces that as @Left@, and replay
-- stops at the first divergence instead of continuing through the trace.
testRegisterMismatch :: TestTree
testRegisterMismatch = testCase "e2e Register: divergent client state yields StepMismatch" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  let bogus = Map.singleton (T.pack "hr") (VInt 99) :: Map Text Value
      client = fixedClient clientEnd bogus
  result <- runClient client hcApalacheCfg hcTraceConfig
  case result of
    Left _ -> pure ()
    Right () -> assertFailure "client unexpectedly succeeded with bogus state"
  steps <- readMVar mv
  assertBool "mismatch reported" (hasStep isMismatch steps)

-- | E2E, RegisterTraces flow, happy path (MirrorProtocol.tla:
-- ClientRegisterTraces -> MirrorRecvRegisterTraces, which replies
-- SPEC_VALIDATED immediately since the traces are already provided).
--
-- Instead of asking the mirror to generate traces, the test pre-generates
-- ITF trace files itself ('generateTraceFiles') and hands the file paths to
-- the mirror via @RegisterTraces@. The mirror parses them, then runs the same
-- replay loop as the Register flow against 'hourClockClient'.
--
-- Expected outcome: client returns @Right ()@; the step log starts with
-- 'MirrorRecvRegisterTraces', ends with 'MirrorSendAllStepsDone', and is
-- otherwise clean. Note the log has no 'MirrorSendSpecValidatedValid' step —
-- that constructor is only recorded on the generate-then-replay path.
testRegisterTracesHappyPath :: TestTree
testRegisterTracesHappyPath = testCase "e2e RegisterTraces: hourClockClient replays trace files" $ do
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  tracePaths <- case genResult of
    Right (_, ps) -> pure ps
    Left err -> assertFailure $ "pre-generate traces error: " ++ show err
  assertBool "at least one trace file" (not (null tracePaths))

  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  client <- hourClockClient clientEnd
  result <- runClientWithTraces client hcApalacheCfg tracePaths
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right () -> pure ()
  steps <- readMVar mv
  assertBool "mirror produced steps" (not (null steps))
  assertBool "starts with MirrorRecvRegisterTraces"
    (case steps of
      (MirrorRecvRegisterTraces _ _ : _) -> True
      _ -> False)
  assertBool "ends with MirrorSendAllStepsDone"
    (case reverse steps of
      (MirrorSendAllStepsDone : _) -> True
      _ -> False)
  assertCleanSteps steps

-- | E2E, RegisterGenTraces flow (MirrorProtocol.tla: ClientRegisterGenTraces
-- -> MirrorRecvRegisterGenTraces -> MirrorSendGenTracesDone, then both sides
-- return to idle — no replay happens in this flow).
--
-- The client asks the mirror to generate trace files and report their paths
-- (@GenTracesDone@), nothing more. No destination directory is given, so the
-- files stay in apalache's own output directory (@_apalache-out@).
--
-- Expected outcome: client returns @Right ()@; the step log is exactly
-- 'MirrorRecvRegisterGenTraces' followed by one 'MirrorSendGenTracesDone'
-- carrying a non-empty list of @.json@ trace files.
testRegisterGenTraces :: TestTree
testRegisterGenTraces = testCase "e2e RegisterGenTraces: mirror generates and notifies done" $ do
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  client <- hourClockClient clientEnd
  result <- runClientGenTraces client hcApalacheCfg hcTraceConfig Nothing
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right () -> pure ()
  steps <- readMVar mv
  assertBool "starts with MirrorRecvRegisterGenTraces"
    (case steps of
      (MirrorRecvRegisterGenTraces _ _ _ _ : _) -> True
      _ -> False)
  case [ps | MirrorSendGenTracesDone ps <- steps] of
    [ps] -> do
      assertBool "GenTracesDone has at least one path" (not (null ps))
      assertBool "generated paths are .json files"
        (all (\p -> takeExtension p == ".json") ps)
    _ -> assertFailure "expected exactly one MirrorSendGenTracesDone step"
  assertCleanSteps steps

hcSpec :: IO ApalacheSpec
hcSpec = mkSpecFromFile "test/specs/HourClock.tla"

-- | E2E, Register flow with INLINE spec sources (network-separation feature):
-- the mirror must not touch the filesystem path in the config.
--
-- The client sends @Register@ whose @spec@ field carries BOTH modules of a
-- two-module spec (ExtMain EXTENDS ExtDep), while @specPath@ deliberately
-- points at a path that does not exist on the mirror's filesystem. The mirror
-- must materialize the sources to a temp dir (files named after their MODULE
-- headers, so the apalache CLI can resolve EXTENDS there) and run from the
-- materialized root instead of specPath.
--
-- Source order matters: apalache treats sources[0] as the root module and the
-- rest as dependencies, so ExtMain comes first.
--
-- Expected outcome: client returns @Right ()@; the step log starts with
-- 'MirrorRecvRegister' carrying @Just spec@, ends with
-- 'MirrorSendAllStepsDone', and is otherwise clean. Success proves the bogus
-- specPath was never read.
testRegisterInlineSpec :: TestTree
testRegisterInlineSpec = testCase "e2e Register: inline spec sources bypass specPath" $ do
  rootSrc <- TIO.readFile "test/specs/ExtMain.tla"
  depSrc <- TIO.readFile "test/specs/ExtDep.tla"
  let inlineSpec = ApalacheSpec [rootSrc, depSrc]
      cfg = ApalacheConfig
        { specPath      = "/nonexistent/ExtMain.tla"
        , initPredicate = Nothing
        , nextPredicate = Nothing
        , constInit     = Nothing
        , invariant     = T.pack "TraceComplete"
        , lengthBound   = 3
        , paramVarNames = T.empty
        }
      tc = TraceGenerationConfig 1 Nothing
      -- apalache writes both violation.itf.json and violation1.itf.json
      -- (same trace twice), and the mirror replays every *.itf.json found —
      -- so one logical trace is replayed twice. Pre-existing behavior,
      -- also relied on by MainSpec. Serve states for both replays.
      states = concat $ replicate 2
        [ Map.fromList
            [ (T.pack "count", VInt n)
            , (T.pack "action_taken", VStr (if n == 0 then T.pack "init" else T.pack "tick"))
            ]
        | n <- [0 .. 3]
        ]
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  client <- cannedClient clientEnd states
  result <- runClientWithSpec client cfg tc (Just inlineSpec)
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right () -> pure ()
  steps <- readMVar mv
  assertBool "starts with MirrorRecvRegister carrying inline spec"
    (case steps of
      (MirrorRecvRegister _ _ (Just _) : _) -> True
      _ -> False)
  assertBool "ends with MirrorSendAllStepsDone"
    (case reverse steps of
      (MirrorSendAllStepsDone : _) -> True
      _ -> False)
  assertCleanSteps steps

-- | E2E, RegisterExplore flow, happy path (MirrorProtocol.tla:
-- ClientRegisterExplore -> MirrorRecvRegisterExplore -> validating -> ready,
-- then the same stepping loop as Register).
--
-- Unlike the Register flows (which replay precomputed concrete traces), here
-- the mirror starts a live apalache explorer server and drives it through
-- 'Apalache.Rpc.Client': it symbolically computes each successor state itself
-- ('exploreQueryState' / 'exploreAssumeState' / 'exploreNext'), sends it as
-- InitialState/NextStep, and checks the client's ReportState against it. So
-- this test exercises interactive symbolic model checking end to end:
--
-- > hourClockClient <-> mirror <-> Explorer <-> Rpc.Client <-> apalache server
--
-- 'hourClockClient' computes the same successor states as the model, and the
-- state invariant @Inv@ holds throughout, so all 4 steps should match.
--
-- Expected outcome: client returns @Right ()@; the step log starts with
-- 'MirrorRecvRegisterExplore', contains 'MirrorSendSpecValidatedValid', ends
-- with 'MirrorSendAllStepsDone' (reached when maxSteps = 4 is hit), and is
-- otherwise clean.
testExploreHappyPath :: TestTree
testExploreHappyPath = testCase "e2e RegisterExplore: hourClockClient matches symbolic states" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  client <- hourClockClient clientEnd
  result <- runClientExplore client spec' [T.pack "Inv"] [] 4
  case result of
    Left err -> assertFailure ("client failed: " ++ T.unpack err)
    Right () -> pure ()
  steps <- readMVar mv
  assertBool "mirror produced steps" (not (null steps))
  assertBool "starts with MirrorRecvRegisterExplore"
    (case steps of
      (MirrorRecvRegisterExplore _ _ _ _ : _) -> True
      _ -> False)
  assertBool "spec validated"
    (hasStep (\case MirrorSendSpecValidatedValid -> True; _ -> False) steps)
  assertBool "ends with MirrorSendAllStepsDone"
    (case reverse steps of
      (MirrorSendAllStepsDone : _) -> True
      _ -> False)
  assertCleanSteps steps

-- | E2E, RegisterExplore flow, conformance-failure path.
--
-- Same symbolic-exploration setup as the happy path, but the client is a
-- 'fixedClient' reporting @{hr: 99}@. The mirror's very first 'diffState'
-- against the symbolically computed initial state must fail.
--
-- Expected outcome: the mirror replies @StepMismatch@ (recorded as
-- 'MirrorSendStepMismatch') and aborts the exploration; the client surfaces
-- it as @Left@.
testExploreMismatch :: TestTree
testExploreMismatch = testCase "e2e RegisterExplore: divergent client state yields StepMismatch" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  let bogus = Map.singleton (T.pack "hr") (VInt 99) :: Map Text Value
      client = fixedClient clientEnd bogus
  result <- runClientExplore client spec' [T.pack "Inv"] [] 4
  case result of
    Left _ -> pure ()
    Right () -> assertFailure "client unexpectedly succeeded with bogus state"
  steps <- readMVar mv
  assertBool "mismatch reported" (hasStep isMismatch steps)

-- | E2E, RegisterExploreSession flow (MirrorProtocol.tla:
-- ClientRegisterExploreSession -> MirrorRecvRegisterExploreSession ->
-- MirrorSendExplorerReady, then strictly alternating EXPLORE_CMD /
-- EXPLORE_RESULT until EXPLORE_DONE).
--
-- This is the client-driven variant of interactive symbolic checking: after
-- 'exploreSession' opens the session, the *test itself* issues explorer
-- commands and the mirror forwards each one to the apalache explorer server
-- via 'Apalache.Rpc.Client'. The script covers every command kind:
--
--   1. @assumeTransition 0@  -> ENABLED (the single init transition)
--   2. @nextStep@            -> advances to step 1
--   3. @queryState@          -> returns a state containing @hr@
--   4. @checkInvariant 0@    -> @Inv@ is SATISFIED at the current state
--   5. @assumeState {hr}@    -> ENABLED (queried value re-assumed)
--   6. @assumeTransition 999@ -> ProtocolError (invalid id), and the session
--      SURVIVES the error (unlike the Register flows, a failed command does
--      not tear the session down)
--   7. @rollback 0@          -> back to the initial snapshot
--   8. @done@                -> ExploreSessionDone, mirror disposes session
--
-- Expected outcome: every reply has the shape above; the step log contains
-- 'MirrorRecvRegisterExploreSession' and 'MirrorSendExplorerReady', followed
-- by one 'MirrorRecvExploreCmd' per command (>= 8).
testExploreSessionHappyPath :: TestTree
testExploreSessionHappyPath = testCase "e2e RegisterExploreSession: client drives symbolic checking" $ do
  spec' <- hcSpec
  (clientEnd, mirrorEnd) <- newMockTransport
  mv <- forkMirror mirrorEnd
  r <- exploreSession clientEnd spec' [T.pack "Inv"] []
  (nInit, nNext, nInv) <- case r of
    Left err -> assertFailure ("exploreSession failed: " ++ T.unpack err)
    Right counts -> pure counts
  assertBool "one init transition" (nInit == 1)
  assertBool "at least one next transition" (nNext >= 1)
  assertBool "one state invariant" (nInv == 1)

  sendMsg clientEnd (ExploreAssumeTransition 0)
  r1 <- recvMsg clientEnd
  assertBool ("assumeTransition: " ++ show r1)
    (case r1 of Right (ExploreTransitionStatus s) -> s == T.pack "ENABLED"; _ -> False)

  sendMsg clientEnd ExploreNextStep
  r2 <- recvMsg clientEnd
  assertBool ("nextStep: " ++ show r2)
    (case r2 of Right (ExploreStepDone 1) -> True; _ -> False)

  sendMsg clientEnd ExploreQueryState
  r3 <- recvMsg clientEnd
  hrVal <- case r3 of
    Right (ExploreState st) -> pure (Map.lookup (T.pack "hr") st)
    _ -> assertFailure ("queryState: " ++ show r3)

  sendMsg clientEnd (ExploreCheckInvariant 0)
  r4 <- recvMsg clientEnd
  assertBool ("checkInvariant: " ++ show r4)
    (case r4 of Right (ExploreInvariantStatus s) -> s == T.pack "SATISFIED"; _ -> False)

  case hrVal of
    Nothing -> assertFailure "queried state has no hr"
    Just v -> do
      sendMsg clientEnd (ExploreAssumeState (Map.singleton (T.pack "hr") v))
      r5 <- recvMsg clientEnd
      assertBool ("assumeState: " ++ show r5)
        (case r5 of Right (ExploreAssumeStatus s) -> s == T.pack "ENABLED"; _ -> False)

  sendMsg clientEnd (ExploreAssumeTransition 999)
  r6 <- recvMsg clientEnd
  assertBool ("invalid tid: " ++ show r6)
    (case r6 of Right (ProtocolError _) -> True; _ -> False)

  sendMsg clientEnd (ExploreRollback 0)
  r7 <- recvMsg clientEnd
  assertBool ("rollback: " ++ show r7)
    (case r7 of Right (ExploreRollbackDone 0) -> True; _ -> False)

  sendMsg clientEnd ExploreDone
  r8 <- recvMsg clientEnd
  assertBool ("done: " ++ show r8)
    (case r8 of Right ExploreSessionDone -> True; _ -> False)

  steps <- readMVar mv
  assertBool "session registered"
    (hasStep (\case MirrorRecvRegisterExploreSession{} -> True; _ -> False) steps)
  assertBool "explorer ready sent"
    (hasStep (\case MirrorSendExplorerReady -> True; _ -> False) steps)
  let cmds = length [ () | MirrorRecvExploreCmd _ <- steps ]
  assertBool ("explorer commands forwarded: " ++ show cmds) (cmds >= 8)
