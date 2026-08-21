module Protocol.Mirror
  ( MirrorStep (..)
  , mirrorStepActionName
  , normalizeMirrorSteps
  , Step (..)
  , RecvMsg (..)
  , MkRunMirror (..)
  , MkRunMirrorWithTraces (..)
  , MkRunMirrorGenTraces (..)
  , MkRunValidate (..)
  , MkExploreMirror (..)
  , MkExploreSession (..)
  , MkReplayAll (..)
  , MkReplayOne (..)
  , replaySteps
  , runMirror
  , runMirrorWithSpec
  , runMirrorWithTraces
  , runMirrorGenTraces
  , runMirrorGenTracesWithSpec
  , runMirrorExplore
  , runMirrorExploreSession
  , runMirrorValidate
  , MkRunValidateAsync (..)
  , MkRunGenTracesAsync (..)
  , MkJobQuery (..)
  , MkJobAwait (..)
  , MkJobCancel (..)
  , runMirrorValidateAsync
  , runMirrorGenTracesAsync
  , runAsyncSession
  , maxValidateBound
  , run
  ) where

import Apalache.Command (generateTraceFilesIn, generateTracesIn, validateSpecIn)
import Apalache.Explorer
  ( Explorer (..)
  , exploreAssumeState
  , exploreCheck
  , exploreDispose
  , exploreInit
  , exploreNext
  , exploreQueryState
  , newExplorer
  , withApalacheServer
  )
import Apalache.Rpc.Client (assumeTransition, nextStep, rollback)
import Apalache.SpecSource (acquireSpec, freshSessionDir, removeSessionDir)
import Apalache.Rpc.Types
  ( ApalacheSpec
  , AssumeTransitionParams (..)
  , AssumeTransitionResult (..)
  , InvariantKind (..)
  , InvariantStatus (..)
  , NextStateParams (..)
  , NextStateResult (..)
  , RollbackParams (..)
  , RpcError
  , SpecParams (..)
  , TransitionStatus (..)
  )
import Apalache.Trace (findTraceFiles, readTrace)
import Apalache.Types
    ( ApalacheConfig (..)
    , ApalacheError (..)
    , ItfTrace (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , ValidateResult (..)
    , Value (..)
    , applyParamVars
    )
import Control.Exception (IOException, finally, throwIO, try)
import Control.Monad (forM_)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (diffState, traceSteps)
import Engine.Interactive (makeTransportDriver)
import Engine.Replay (StateDriver (..))
import Engine.Types (StepCommand (..), StateDiff (..))
import qualified Engine.Types as Engine
import Protocol.AsyncJobs
  ( JobStore
  , awaitJob
  , cancelJob
  , closeJobStore
  , queryJob
  , submitGenTracesJob
  , submitValidateJob
  )
import qualified Protocol.AsyncJobs (maxValidateBound)
import Protocol.Core
  ( ClientMessage (..)
  , JobId (..)
  , JobKind (..)
  , JobOutcome (..)
  , JobPhase (..)
  , MirrorMessage (..)
  )
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)
import Resource (release, use, with)
import System.Directory (createDirectoryIfMissing, copyFile, doesDirectoryExist)
import System.FilePath (takeFileName, (</>))

data MirrorStep
  = MirrorRecvRegister !ApalacheConfig !TraceGenerationConfig !(Maybe ApalacheSpec)
  | MirrorRecvRegisterTraces !ApalacheConfig ![FilePath]
  | MirrorRecvRegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
  | MirrorRecvRegisterExplore !ApalacheSpec ![Text] ![Text] !Int
  | MirrorRecvRegisterExploreSession !ApalacheSpec ![Text] ![Text]
  | MirrorRecvRegisterValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)
  | MirrorRecvExploreCmd !Text
  | MirrorRecvReportState !Int !Text
  | MirrorSendGenTracesDone ![FilePath]
  | MirrorSendSpecValidatedValid
  | MirrorSendSpecValidatedInvalid !Text
  | MirrorSendExplorerReady
  | MirrorSendExploreResult !Text
  | MirrorSendRegisterError !Text
  | MirrorSendProtocolError !Text
  | MirrorSendInitialState !Text !(Map Text Value)
  | MirrorSendNextStep !Text !(Map Text Value)
  | MirrorSendStepOk !Int
  | MirrorSendStepMismatch !Int !StateDiff
  | MirrorSendAllStepsDone
  | MirrorRecvRegisterValidateAsync !ApalacheConfig !Int !(Maybe ApalacheSpec)
  | MirrorRecvRegisterGenTracesAsync !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
  | MirrorRecvJobQuery !JobId
  | MirrorRecvJobAwait !JobId
  | MirrorRecvJobCancel !JobId
  | MirrorSendJobAccepted !JobId !JobKind
  | MirrorSendJobStatus !JobId !JobPhase
  | MirrorSendJobResult !JobId !Text
  deriving (Show, Eq)

mirrorStepActionName :: MirrorStep -> Text
mirrorStepActionName = \case
  MirrorRecvRegister{}            -> T.pack "MirrorRecvRegister"
  MirrorRecvRegisterTraces{}      -> T.pack "MirrorRecvRegisterTraces"
  MirrorRecvRegisterGenTraces{}   -> T.pack "MirrorRecvRegisterGenTraces"
  MirrorRecvRegisterExplore{}     -> T.pack "MirrorRecvRegisterExplore"
  MirrorRecvRegisterExploreSession{} -> T.pack "MirrorRecvRegisterExploreSession"
  MirrorRecvRegisterValidate{}   -> T.pack "MirrorRecvRegisterValidate"
  MirrorRecvExploreCmd{}          -> T.pack "MirrorRecvExploreCmd"
  MirrorRecvReportState{}         -> T.pack "MirrorRecvReportState"
  MirrorSendGenTracesDone{}       -> T.pack "MirrorSendGenTracesDone"
  MirrorSendSpecValidatedValid    -> T.pack "MirrorSendSpecValidatedValid"
  MirrorSendSpecValidatedInvalid{}-> T.pack "MirrorSendSpecValidatedInvalid"
  MirrorSendExplorerReady         -> T.pack "MirrorSendExplorerReady"
  MirrorSendExploreResult{}       -> T.pack "MirrorSendExploreResult"
  MirrorSendRegisterError{}       -> T.pack "MirrorSendRegisterError"
  MirrorSendProtocolError{}       -> T.pack "MirrorSendProtocolError"
  MirrorSendInitialState{}        -> T.pack "MirrorSendInitialState"
  MirrorSendNextStep{}            -> T.pack "MirrorSendNextStep"
  MirrorSendStepOk{}              -> T.pack "MirrorSendStepOk"
  MirrorSendStepMismatch{}        -> T.pack "MirrorSendStepMismatch"
  MirrorSendAllStepsDone          -> T.pack "MirrorSendAllStepsDone"
  MirrorRecvRegisterValidateAsync{}  -> T.pack "MirrorRecvRegisterValidateAsync"
  MirrorRecvRegisterGenTracesAsync{} -> T.pack "MirrorRecvRegisterGenTracesAsync"
  MirrorRecvJobQuery{}            -> T.pack "MirrorRecvJobQuery"
  MirrorRecvJobAwait{}            -> T.pack "MirrorRecvJobAwait"
  MirrorRecvJobCancel{}           -> T.pack "MirrorRecvJobCancel"
  MirrorSendJobAccepted{}         -> T.pack "MirrorSendJobAccepted"
  MirrorSendJobStatus{}           -> T.pack "MirrorSendJobStatus"
  MirrorSendJobResult{}           -> T.pack "MirrorSendJobResult"

normalizeMirrorSteps :: [MirrorStep] -> [Text]
normalizeMirrorSteps = go
  where
    go [] = []
    go (MirrorRecvReportState i _ : MirrorSendStepOk j : rest) | i == j =
      T.pack "MirrorRecvReportState" : go rest
    go (MirrorRecvReportState i _ : MirrorSendStepMismatch j _ : rest) | i == j =
      T.pack "MirrorRecvReportState" : go rest
    go (MirrorSendAllStepsDone : rest) = go rest
    go (step : rest) = mirrorStepActionName step : go rest

data RecvMsg t = RecvMsg t
data MkRunMirror t = MkRunMirror t ApalacheConfig TraceGenerationConfig (Maybe ApalacheSpec)
data MkRunMirrorWithTraces t = MkRunMirrorWithTraces t ApalacheConfig [FilePath]
data MkRunMirrorGenTraces t = MkRunMirrorGenTraces t ApalacheConfig TraceGenerationConfig (Maybe FilePath) (Maybe ApalacheSpec)
data MkRunValidate t = MkRunValidate t ApalacheConfig Int (Maybe ApalacheSpec)
data MkRunValidateAsync t = MkRunValidateAsync t JobStore ApalacheConfig Int (Maybe ApalacheSpec)
data MkRunGenTracesAsync t = MkRunGenTracesAsync t JobStore ApalacheConfig TraceGenerationConfig (Maybe FilePath) (Maybe ApalacheSpec)
data MkJobQuery t = MkJobQuery t JobStore JobId
data MkJobAwait t = MkJobAwait t JobStore JobId (Maybe Int)
data MkJobCancel t = MkJobCancel t JobStore JobId
data MkExploreMirror t = MkExploreMirror t ApalacheSpec [Text] [Text] Int
data MkExploreSession t = MkExploreSession t ApalacheSpec [Text] [Text]
data MkReplayAll t = MkReplayAll t (StateDriver IO) [ItfTrace]
data MkReplayOne t = MkReplayOne t (StateDriver IO) ItfTrace

class Step a where
  exec :: a -> IO [MirrorStep]

instance Transport t => Step (RecvMsg t) where
  exec (RecvMsg transport) = do
    msg <- recvMsg transport
    case msg of
      Right (Register apCfg tc mSpec) -> do
        steps <- exec (MkRunMirror transport apCfg tc mSpec)
        pure (MirrorRecvRegister apCfg tc mSpec : steps)
      Right (RegisterTraces apCfg traces) -> do
        steps <- exec (MkRunMirrorWithTraces transport apCfg traces)
        pure (MirrorRecvRegisterTraces apCfg traces : steps)
      Right (RegisterGenTraces apCfg tc destPath mSpec) -> do
        steps <- exec (MkRunMirrorGenTraces transport apCfg tc destPath mSpec)
        pure (MirrorRecvRegisterGenTraces apCfg tc destPath mSpec : steps)
      Right (RegisterExplore spec invs exports maxSteps) -> do
        steps <- exec (MkExploreMirror transport spec invs exports maxSteps)
        pure (MirrorRecvRegisterExplore spec invs exports maxSteps : steps)
      Right (RegisterExploreSession spec invs exports) -> do
        steps <- exec (MkExploreSession transport spec invs exports)
        pure (MirrorRecvRegisterExploreSession spec invs exports : steps)
      Right (RegisterValidate apCfg bound mSpec) -> do
        steps <- exec (MkRunValidate transport apCfg bound mSpec)
        pure (MirrorRecvRegisterValidate apCfg bound mSpec : steps)
      Right _ -> do
        sendMsg transport (ProtocolError (T.pack "Expected Register message"))
        pure [MirrorSendProtocolError (T.pack "Expected Register message")]
      Left err -> do
        sendMsg transport (ProtocolError (T.pack err))
        pure [MirrorSendProtocolError (T.pack err)]

-- | When inline spec sources are provided, acquire them via 'acquireSpec'
-- (the apalache CLI resolves EXTENDS from the filesystem) and override the
-- config's specPath; otherwise use the config as-is. The acquired spec
-- resource is released on exit (normal or exceptional), matching the old
-- bracket behavior; release is a no-op for 'Borrowed' specs.
withSpecDir :: Transport t => t -> Maybe ApalacheSpec -> ApalacheConfig -> (ApalacheConfig -> IO [MirrorStep]) -> IO [MirrorStep]
withSpecDir _ Nothing cfg k = k cfg
withSpecDir transport (Just spec) cfg k = do
  r <- acquireSpec (Just spec) cfg
  case r of
    Left err -> do
      sendMsg transport (RegisterError err)
      pure [MirrorSendRegisterError err]
    Right (specResource, cfg') -> do
      result <- k cfg' `finally` release specResource
      pure result

-- | Run an action with a per-session temporary directory (removed on
-- exit) so concurrent sessions never share apalache run directories.
-- Re-based on 'Resource.with' over 'freshSessionDir'/'removeSessionDir'.
withSessionDir :: (FilePath -> IO a) -> IO a
withSessionDir action =
  with (T.pack "session-dir") freshSessionDir removeSessionDir $ \sessionRes ->
    either (\e -> throwIO (userError ("session-dir unavailable: " ++ show e))) pure
      =<< use sessionRes action

instance Transport t => Step (MkRunMirror t) where
  exec (MkRunMirror transport cfg tc mSpec) =
    withSpecDir transport mSpec cfg $ \cfg' ->
      withSessionDir $ \sessionDir -> do
        traceRes <- generateTracesIn (Just sessionDir) cfg' tc
        case traceRes of
          Left err -> do
            sendMsg transport (RegisterError (unApalacheError err))
            pure [MirrorSendRegisterError (unApalacheError err)]
          Right (TracesGenerated traces) -> do
            sendMsg transport (SpecValidated SpecValid)
            let driver = makeTransportDriver transport
            stepResults <- exec (MkReplayAll transport driver traces)
            sendMsg transport AllStepsDone
            pure (MirrorSendSpecValidatedValid : stepResults ++ [MirrorSendAllStepsDone])
          Right (GenerationError e) -> do
            sendMsg transport (ProtocolError e)
            pure [MirrorSendProtocolError e]

instance Transport t => Step (MkRunMirrorWithTraces t) where
  exec (MkRunMirrorWithTraces transport cfg tracePaths) = do
    r <- try go
    case r of
      Left (e :: IOException) -> do
        -- unreadable trace file(s): report, don't die
        sendMsg transport (RegisterError (T.pack (show e)))
        pure [MirrorSendRegisterError (T.pack (show e))]
      Right steps -> pure steps
    where
      go = do
        expanded <- concat <$> mapM expandPath tracePaths
        traces <- mapM readTrace expanded
        case sequence traces of
          Left err -> do
            sendMsg transport (RegisterError (T.pack err))
            pure [MirrorSendRegisterError (T.pack err)]
          Right parsed -> do
            let pvs = filter (not . T.null) [paramVarNames cfg]
                traces' = map (applyParamVars pvs) parsed
            sendMsg transport (SpecValidated SpecValid)
            let driver = makeTransportDriver transport
            stepResults <- exec (MkReplayAll transport driver traces')
            sendMsg transport AllStepsDone
            pure (stepResults ++ [MirrorSendAllStepsDone])
      expandPath p = do
        isDir <- doesDirectoryExist p
        if isDir then findTraceFiles p else pure [p]

instance Transport t => Step (MkRunMirrorGenTraces t) where
  exec (MkRunMirrorGenTraces transport cfg tc destPath mSpec) =
    withSpecDir transport mSpec cfg $ \cfg' ->
      withSessionDir $ \sessionDir -> do
        result <- generateTraceFilesIn (Just sessionDir) cfg' tc
        case result of
          Left err -> do
            sendMsg transport (RegisterError (unApalacheError err))
            pure [MirrorSendRegisterError (unApalacheError err)]
          Right (outDir, paths) -> do
            finalPaths <- case destPath of
              Just d | d /= outDir -> do
                createDirectoryIfMissing True d
                forM_ paths $ \p -> copyFile p (d </> takeFileName p)
                pure $ map (\p -> d </> takeFileName p) paths
              _ -> pure paths
            contentsRes <- readTraceContents finalPaths
            case contentsRes of
              Left err -> do
                sendMsg transport (RegisterError err)
                pure [MirrorSendRegisterError err]
              Right contents -> do
                sendMsg transport (GenTracesDone finalPaths contents)
                pure [MirrorSendGenTracesDone finalPaths]

readTraceContents :: [FilePath] -> IO (Either Text [A.Value])
readTraceContents ps = fmap sequence (traverse readOne ps)
  where
    readOne p = do
      bs <- LBS.readFile p
      pure $ case A.decode bs of
        Just v  -> Right v
        Nothing -> Left (T.pack ("failed to parse generated trace: " ++ p))

-- | Server-side cap on the check bound a remote client may request via
-- @RegisterValidate@. A bound outside @[1, maxValidateBound]@ is rejected
-- with a @RegisterError@ before any spec materialization or apalache
-- invocation, so a remote client cannot force an unbounded (or
-- nonsensical) bounded check on the mirror.
-- maxValidateBound now delegates to the single source in
-- "Protocol.AsyncJobs" (which this module imports for the async Step
-- instances, so the constant cannot live here without a module cycle).
-- Same name, same value (100): no signature or behavior change.
maxValidateBound :: Int
maxValidateBound = Protocol.AsyncJobs.maxValidateBound

instance Transport t => Step (MkRunValidate t) where
  exec (MkRunValidate transport cfg bound mSpec)
    | bound < 1 || bound > maxValidateBound = do
        let msg = T.pack ("validate bound " ++ show bound
                          ++ " outside allowed range 1.." ++ show maxValidateBound)
        sendMsg transport (RegisterError msg)
        pure [MirrorSendRegisterError msg]
    | otherwise =
        withSpecDir transport mSpec cfg $ \cfg' ->
          withSessionDir $ \sessionDir -> do
            res <- validateSpecIn (Just sessionDir) cfg' bound
            case res of
              Left err -> do
                sendMsg transport (RegisterError (unApalacheError err))
                pure [MirrorSendRegisterError (unApalacheError err)]
              Right v -> do
                sendMsg transport (SpecValidated v)
                pure [case v of
                        SpecValid     -> MirrorSendSpecValidatedValid
                        SpecInvalid e -> MirrorSendSpecValidatedInvalid e]


--------------------------------------------------------------------------------
-- Async job operations (design §5). The session loop never blocks on
-- apalache: submits fork through the job store and return immediately;
-- job operations are answered from the store. Sync registers received
-- mid-session still run inline (documented §5).

-- | One-word outcome summary for the step log.
outcomeTag :: JobOutcome -> Text
outcomeTag = \case
  JobValidateDone _  -> T.pack "validate"
  JobGenTracesDone{} -> T.pack "genTraces"
  JobInfraError _    -> T.pack "error"

instance Transport t => Step (MkRunValidateAsync t) where
  exec (MkRunValidateAsync transport store cfg bound mSpec) = do
    r <- submitValidateJob store cfg bound mSpec
    case r of
      Left err -> do
        sendMsg transport (RegisterError err)
        pure [MirrorSendRegisterError err]
      Right jid -> do
        sendMsg transport (JobAccepted jid ValidateJob)
        pure [MirrorSendJobAccepted jid ValidateJob]

instance Transport t => Step (MkRunGenTracesAsync t) where
  exec (MkRunGenTracesAsync transport store cfg tc destPath mSpec) = do
    r <- submitGenTracesJob store cfg tc destPath mSpec
    case r of
      Left err -> do
        sendMsg transport (RegisterError err)
        pure [MirrorSendRegisterError err]
      Right jid -> do
        sendMsg transport (JobAccepted jid GenTracesJob)
        pure [MirrorSendJobAccepted jid GenTracesJob]

instance Transport t => Step (MkJobQuery t) where
  exec (MkJobQuery transport store jid) = do
    (phase, mOut) <- queryJob store jid
    case mOut of
      -- Terminal query answers with the retained result directly.
      Just out -> do
        sendMsg transport (JobResult jid out)
        pure [MirrorSendJobResult jid (outcomeTag out)]
      Nothing -> do
        sendMsg transport (JobStatus jid phase)
        pure [MirrorSendJobStatus jid phase]

instance Transport t => Step (MkJobAwait t) where
  exec (MkJobAwait transport store jid mTimeout) = do
    r <- awaitJob store jid mTimeout
    case r of
      Right out -> do
        sendMsg transport (JobResult jid out)
        pure [MirrorSendJobResult jid (outcomeTag out)]
      Left _ -> do
        (phase, mOut) <- queryJob store jid
        case mOut of
          Just out -> do
            sendMsg transport (JobResult jid out)
            pure [MirrorSendJobResult jid (outcomeTag out)]
          Nothing -> do
            sendMsg transport (JobStatus jid phase)
            pure [MirrorSendJobStatus jid phase]

instance Transport t => Step (MkJobCancel t) where
  exec (MkJobCancel transport store jid) = do
    cancelJob store jid
    (phase, _) <- queryJob store jid
    sendMsg transport (JobStatus jid phase)
    pure [MirrorSendJobStatus jid phase]

-- | Async session entry point (design §5): a recv-dispatch loop over one
-- connection. Async registers fork and return to the loop immediately; job
-- operations are answered from the store (terminal query/await replies with
-- 'JobResult', per the async contract); a /sync/ register received
-- mid-session still runs to completion inline (blocking the loop, as
-- today). Transport EOF or a decode failure ends the session: any reply on
-- the way out is best-effort, the session's jobs are killed and their
-- resources force-released ('closeJobStore'), and the accumulated step log
-- is returned.
runAsyncSession :: Transport t => t -> JobStore -> IO [MirrorStep]
runAsyncSession transport store = loop []
  where
    loop acc = do
      msg <- recvMsg transport
      case msg of
        Left err -> endSession acc (Just err)
        Right incoming -> dispatch incoming acc
    dispatch incoming acc = case incoming of
      RegisterValidateAsync cfg bound mSpec -> do
        steps <- exec (MkRunValidateAsync transport store cfg bound mSpec)
        continue (MirrorRecvRegisterValidateAsync cfg bound mSpec : steps) acc
      RegisterGenTracesAsync cfg tc destPath mSpec -> do
        steps <- exec (MkRunGenTracesAsync transport store cfg tc destPath mSpec)
        continue (MirrorRecvRegisterGenTracesAsync cfg tc destPath mSpec : steps) acc
      QueryJob jid -> do
        steps <- exec (MkJobQuery transport store jid)
        continue (MirrorRecvJobQuery jid : steps) acc
      AwaitJob jid mTimeout -> do
        steps <- exec (MkJobAwait transport store jid mTimeout)
        continue (MirrorRecvJobAwait jid : steps) acc
      CancelJob jid -> do
        steps <- exec (MkJobCancel transport store jid)
        continue (MirrorRecvJobCancel jid : steps) acc
      -- Sync one-shot registers still work mid-session, inline.
      Register apCfg tc mSpec -> do
        steps <- exec (MkRunMirror transport apCfg tc mSpec)
        continue [MirrorRecvRegister apCfg tc mSpec] (steps ++ acc)
      RegisterTraces apCfg traces -> do
        steps <- exec (MkRunMirrorWithTraces transport apCfg traces)
        continue [MirrorRecvRegisterTraces apCfg traces] (steps ++ acc)
      RegisterGenTraces apCfg tc destPath mSpec -> do
        steps <- exec (MkRunMirrorGenTraces transport apCfg tc destPath mSpec)
        continue [MirrorRecvRegisterGenTraces apCfg tc destPath mSpec] (steps ++ acc)
      RegisterValidate apCfg bound mSpec -> do
        steps <- exec (MkRunValidate transport apCfg bound mSpec)
        continue [MirrorRecvRegisterValidate apCfg bound mSpec] (steps ++ acc)
      -- The interactive sync registers also run inline: each owns its
      -- recv/send loop, blocks this session loop until done, and then
      -- returns to it (same "sync register mid-session" rule, §5).
      RegisterExplore spec invs exports maxSteps -> do
        steps <- exec (MkExploreMirror transport spec invs exports maxSteps)
        continue [MirrorRecvRegisterExplore spec invs exports maxSteps] (steps ++ acc)
      RegisterExploreSession spec invs exports -> do
        steps <- exec (MkExploreSession transport spec invs exports)
        continue [MirrorRecvRegisterExploreSession spec invs exports] (steps ++ acc)
      _ -> do
        let err = T.pack "unexpected message in async session"
        sendMsg transport (ProtocolError err)
        continue [MirrorSendProtocolError err] acc
    continue fresh acc = loop (reverse fresh ++ acc)
    endSession acc mErr = do
      case mErr of
        Just err -> sendMsg transport (ProtocolError (T.pack err))
        Nothing -> pure ()
      closeJobStore store
      pure (reverse acc)


instance Transport t => Step (MkExploreMirror t) where
  exec (MkExploreMirror transport spec invs exports maxSteps) =
    withApalacheServer Nothing $ \server -> do
      explRes <- newExplorer server spec invs exports
      case explRes of
        Left err -> do
          let msg = rpcErrorText err
          sendMsg transport (RegisterError msg)
          pure [MirrorSendRegisterError msg]
        Right expl0 -> do
          initRes <- exploreInit expl0
          case initRes of
            Left err -> do
              let msg = rpcErrorText err
              sendMsg transport (ProtocolError msg)
              pure [MirrorSendProtocolError msg]
            Right expl1 -> do
              sendMsg transport (SpecValidated SpecValid)
              (MirrorSendSpecValidatedValid :) <$> exploreLoop expl1 0
    where
      exploreLoop expl stepIdx = do
        stateRes <- exploreQueryState expl
        case stateRes of
          Left err -> do
            let msg = rpcErrorText err
            sendMsg transport (ProtocolError msg)
            pure [MirrorSendProtocolError msg]
          Right expected -> do
            let action = stateAction expected
                sendStep
                  | stepIdx == 0 = MirrorSendInitialState action expected
                  | otherwise    = MirrorSendNextStep action expected
            if stepIdx == 0
              then sendMsg transport (InitialState action expected)
              else sendMsg transport (NextStep action expected)
            resp <- recvMsg transport
            case resp of
              Left err -> do
                sendMsg transport (ProtocolError (T.pack err))
                pure [sendStep, MirrorSendProtocolError (T.pack err)]
              Right (ReportState actual) -> do
                let diff = diffState expected actual
                    recvStep = MirrorRecvReportState stepIdx action
                case diff of
                  StateMismatch e a hints -> do
                    sendMsg transport (StepMismatch e a hints)
                    pure [sendStep, recvStep, MirrorSendStepMismatch stepIdx diff]
                  StatesMatch -> do
                    asRes <- exploreAssumeState expl actual
                    case asRes of
                      Left err -> do
                        let msg = rpcErrorText err
                        sendMsg transport (ProtocolError msg)
                        pure [sendStep, recvStep, MirrorSendProtocolError msg]
                      Right (expl', _) -> do
                        sendMsg transport StepOk
                        violated <- invariantViolated expl'
                        if violated
                          then do
                            sendMsg transport (StepMismatch Map.empty Map.empty [])
                            pure [ sendStep, recvStep, MirrorSendStepOk stepIdx
                                 , MirrorSendStepMismatch stepIdx
                                     (StateMismatch Map.empty Map.empty []) ]
                          else if stepIdx + 1 >= maxSteps
                            then do
                              sendMsg transport AllStepsDone
                              pure [sendStep, recvStep, MirrorSendStepOk stepIdx, MirrorSendAllStepsDone]
                            else do
                              nxt <- exploreNext expl' 0
                              case nxt of
                                Left err -> do
                                  let msg = rpcErrorText err
                                  sendMsg transport (ProtocolError msg)
                                  pure [sendStep, recvStep, MirrorSendStepOk stepIdx
                                       , MirrorSendProtocolError msg]
                                Right (_, TransDisabled) -> do
                                  sendMsg transport AllStepsDone
                                  pure [sendStep, recvStep, MirrorSendStepOk stepIdx
                                       , MirrorSendAllStepsDone]
                                Right (expl'', _) -> do
                                  rest <- exploreLoop expl'' (stepIdx + 1)
                                  pure (sendStep : recvStep : MirrorSendStepOk stepIdx : rest)
              Right _ -> do
                sendMsg transport (ProtocolError (T.pack "expected ReportState"))
                pure [sendStep, MirrorSendProtocolError (T.pack "expected ReportState")]
      invariantViolated expl
        | null invs = pure False
        | otherwise = do
            r <- exploreCheck expl 0 StateInvariant
            pure $ case r of
              Right (InvViolated, _) -> True
              _ -> False
      stateAction expected = case Map.lookup (T.pack "action_taken") expected of
        Just (VStr a) -> a
        _             -> T.pack "explore"

rpcErrorText :: RpcError -> Text
rpcErrorText = T.pack . show

transitionStatusText :: TransitionStatus -> Text
transitionStatusText TransEnabled  = T.pack "ENABLED"
transitionStatusText TransDisabled = T.pack "DISABLED"
transitionStatusText TransUnknown  = T.pack "UNKNOWN"

invariantStatusText :: InvariantStatus -> Text
invariantStatusText InvSatisfied = T.pack "SATISFIED"
invariantStatusText InvViolated  = T.pack "VIOLATED"
invariantStatusText InvUnknown   = T.pack "UNKNOWN"

instance Transport t => Step (MkExploreSession t) where
  exec (MkExploreSession transport spec invs exports) =
    withApalacheServer Nothing $ \server -> do
      explRes <- newExplorer server spec invs exports
      case explRes of
        Left err -> do
          let msg = rpcErrorText err
          sendMsg transport (RegisterError msg)
          pure [MirrorSendRegisterError msg]
        Right expl0 -> do
          let params = explParams expl0
          sendMsg transport $ ExplorerReady
            (length (spInitTransitions params))
            (length (spNextTransitions params))
            (length (spStateInvariants params))
          (MirrorSendExplorerReady :) <$> sessionLoop expl0
    where
      sessionLoop expl = do
        msg <- recvMsg transport
        case msg of
          Left err -> do
            sendMsg transport (ProtocolError (T.pack err))
            pure [MirrorSendProtocolError (T.pack err)]
          Right ExploreDone -> do
            _ <- exploreDispose expl
            sendMsg transport ExploreSessionDone
            pure [MirrorRecvExploreCmd (T.pack "done"), MirrorSendExploreResult (T.pack "done")]
          Right (ExploreAssumeTransition tid) ->
            cmd (T.pack "assumeTransition") expl $ do
              r <- assumeTransition (explClient expl)
                    (AssumeTransitionParams (explSessionId expl) tid True Nothing)
              pure $ flip fmap r $ \atr ->
                let st = transitionStatusText (atrStatus atr)
                in (expl { explSnap = atrSnapshotId atr }, ExploreTransitionStatus st, st)
          Right ExploreNextStep ->
            cmd (T.pack "nextStep") expl $ do
              r <- nextStep (explClient expl) (NextStateParams (explSessionId expl))
              pure $ flip fmap r $ \nsr ->
                (expl { explSnap = nsrSnapshotId nsr }, ExploreStepDone (nsrNewStepNo nsr), T.pack "ok")
          Right ExploreQueryState ->
            cmd (T.pack "query") expl $ do
              r <- exploreQueryState expl
              pure $ flip fmap r $ \st -> (expl, ExploreState st, T.pack "ok")
          Right (ExploreCheckInvariant iid) ->
            cmd (T.pack "checkInvariant") expl $ do
              r <- exploreCheck expl iid StateInvariant
              pure $ flip fmap r $ \(st, _) ->
                let s = invariantStatusText st
                in (expl, ExploreInvariantStatus s, s)
          Right (ExploreAssumeState eqs) ->
            cmd (T.pack "assumeState") expl $ do
              r <- exploreAssumeState expl eqs
              pure $ flip fmap r $ \(expl', st) ->
                let s = transitionStatusText st
                in (expl', ExploreAssumeStatus s, s)
          Right (ExploreRollback snap) ->
            cmd (T.pack "rollback") expl $ do
              r <- rollback (explClient expl) (RollbackParams (explSessionId expl) snap)
              pure $ flip fmap r $ \() ->
                (expl { explSnap = snap }, ExploreRollbackDone snap, T.pack "ok")
          Right _ -> do
            sendMsg transport (ProtocolError (T.pack "unexpected message in explore session"))
            pure [MirrorSendProtocolError (T.pack "unexpected message in explore session")]
      cmd name expl action = do
        r <- action
        case r of
          Left err -> do
            let msg = rpcErrorText err
            sendMsg transport (ProtocolError msg)
            rest <- sessionLoop expl
            pure (MirrorRecvExploreCmd name : MirrorSendProtocolError msg : rest)
          Right (expl', resultMsg, resultName) -> do
            sendMsg transport resultMsg
            rest <- sessionLoop expl'
            pure (MirrorRecvExploreCmd name : MirrorSendExploreResult resultName : rest)

instance Transport t => Step (MkReplayAll t) where
  exec (MkReplayAll _ _ []) = pure []
  exec (MkReplayAll transport driver (t : ts)) = do
    steps <- exec (MkReplayOne transport driver t)
    if hasMismatch steps
      then pure steps
      else do
        rest <- exec (MkReplayAll transport driver ts)
        pure (steps ++ rest)

hasMismatch :: [MirrorStep] -> Bool
hasMismatch = any (\case MirrorSendStepMismatch{} -> True; _ -> False)

instance Transport t => Step (MkReplayOne t) where
  exec (MkReplayOne transport driver trace) = go driver (traceSteps trace)
    where
      go _ [] = pure []
      go (StateDriver report) (step : rest) = do
        let action = Engine.stepAct step
            sidx = Engine.stepIdx step
            cmd = if sidx == 0
                  then CmdInitial action (Engine.stepVars step)
                  else CmdNextStep action (Engine.stepParams step)
            sendStep = if sidx == 0
                       then MirrorSendInitialState action (Engine.stepVars step)
                       else MirrorSendNextStep action (Engine.stepParams step)
        actual <- report cmd
        let diff = diffState (Engine.stepVars step) actual
            recvStep = MirrorRecvReportState sidx action
        case diff of
          StatesMatch -> do
            sendMsg transport StepOk
            restSteps <- go (StateDriver report) rest
            pure (sendStep : recvStep : MirrorSendStepOk sidx : restSteps)
          StateMismatch expected actualDiffs hints -> do
            sendMsg transport (StepMismatch expected actualDiffs hints)
            pure (sendStep : recvStep : MirrorSendStepMismatch sidx diff : [])

replaySteps :: Transport t => t -> StateDriver IO -> ItfTrace -> IO [MirrorStep]
replaySteps transport driver = exec . MkReplayOne transport driver

runMirror :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> IO [MirrorStep]
runMirror transport cfg tc = exec (MkRunMirror transport cfg tc Nothing)

runMirrorWithSpec :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> ApalacheSpec -> IO [MirrorStep]
runMirrorWithSpec transport cfg tc spec = exec (MkRunMirror transport cfg tc (Just spec))

runMirrorWithTraces :: Transport t => t -> ApalacheConfig -> [FilePath] -> IO [MirrorStep]
runMirrorWithTraces transport cfg traces = exec (MkRunMirrorWithTraces transport cfg traces)

runMirrorGenTraces :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> IO [MirrorStep]
runMirrorGenTraces transport cfg tc destPath = exec (MkRunMirrorGenTraces transport cfg tc destPath Nothing)

runMirrorGenTracesWithSpec :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> ApalacheSpec -> IO [MirrorStep]
runMirrorGenTracesWithSpec transport cfg tc destPath spec =
  exec (MkRunMirrorGenTraces transport cfg tc destPath (Just spec))

runMirrorExplore :: Transport t => t -> ApalacheSpec -> [Text] -> [Text] -> Int -> IO [MirrorStep]
runMirrorExplore transport spec invs exports maxSteps =
  exec (MkExploreMirror transport spec invs exports maxSteps)

runMirrorExploreSession :: Transport t => t -> ApalacheSpec -> [Text] -> [Text] -> IO [MirrorStep]
runMirrorExploreSession transport spec invs exports =
  exec (MkExploreSession transport spec invs exports)

runMirrorValidate :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO [MirrorStep]
runMirrorValidate transport cfg bound mSpec = exec (MkRunValidate transport cfg bound mSpec)

-- | One-shot async validate submit (see 'runAsyncSession' for the full
-- session loop). Signature mirrors 'runMirrorValidate' plus the job store.
runMirrorValidateAsync :: Transport t => t -> JobStore -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO [MirrorStep]
runMirrorValidateAsync transport store cfg bound mSpec =
  exec (MkRunValidateAsync transport store cfg bound mSpec)

-- | One-shot async trace-gen submit; signature mirrors
-- 'runMirrorGenTracesWithSpec' plus the job store.
runMirrorGenTracesAsync :: Transport t => t -> JobStore -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO [MirrorStep]
runMirrorGenTracesAsync transport store cfg tc destPath mSpec =
  exec (MkRunGenTracesAsync transport store cfg tc destPath mSpec)

run :: Transport t => t -> IO [MirrorStep]
run = exec . RecvMsg
