module Protocol.Mirror
  ( MirrorStep (..)
  , mirrorStepActionName
  , normalizeMirrorSteps
  , Step (..)
  , RecvMsg (..)
  , MkRunMirror (..)
  , MkRunMirrorWithTraces (..)
  , MkRunMirrorGenTraces (..)
  , MkReplayAll (..)
  , MkReplayOne (..)
  , replaySteps
  , runMirror
  , runMirrorWithTraces
  , runMirrorGenTraces
  , run
  ) where

import Apalache.Command (generateTraceFiles, generateTraces)
import Apalache.Trace (findTraceFiles, readTrace)
import Apalache.Types
    ( ApalacheConfig (..)
    , ApalacheError (..)
    , ItfTrace (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , ValidateResult (..)
    , Value
    , applyParamVars
    )
import Control.Monad (forM_)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (diffState, traceSteps)
import Engine.Interactive (makeTransportDriver)
import Engine.Replay (StateDriver (..))
import Engine.Types (StepCommand (..), StateDiff (..))
import qualified Engine.Types as Engine
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)
import System.Directory (createDirectoryIfMissing, copyFile, doesDirectoryExist)
import System.FilePath (takeFileName, (</>))

data MirrorStep
  = MirrorRecvRegister !ApalacheConfig !TraceGenerationConfig
  | MirrorRecvRegisterTraces !ApalacheConfig ![FilePath]
  | MirrorRecvRegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath)
  | MirrorRecvReportState !Int !Text
  | MirrorSendGenTracesDone ![FilePath]
  | MirrorSendSpecValidatedValid
  | MirrorSendSpecValidatedInvalid !Text
  | MirrorSendRegisterError !Text
  | MirrorSendProtocolError !Text
  | MirrorSendInitialState !Text !(Map Text Value)
  | MirrorSendNextStep !Text !(Map Text Value)
  | MirrorSendStepOk !Int
  | MirrorSendStepMismatch !Int !StateDiff
  | MirrorSendAllStepsDone
  deriving (Show, Eq)

mirrorStepActionName :: MirrorStep -> Text
mirrorStepActionName = \case
  MirrorRecvRegister{}            -> T.pack "MirrorRecvRegister"
  MirrorRecvRegisterTraces{}      -> T.pack "MirrorRecvRegisterTraces"
  MirrorRecvRegisterGenTraces{}   -> T.pack "MirrorRecvRegisterGenTraces"
  MirrorRecvReportState{}         -> T.pack "MirrorRecvReportState"
  MirrorSendGenTracesDone{}       -> T.pack "MirrorSendGenTracesDone"
  MirrorSendSpecValidatedValid    -> T.pack "MirrorSendSpecValidatedValid"
  MirrorSendSpecValidatedInvalid{}-> T.pack "MirrorSendSpecValidatedInvalid"
  MirrorSendRegisterError{}       -> T.pack "MirrorSendRegisterError"
  MirrorSendProtocolError{}       -> T.pack "MirrorSendProtocolError"
  MirrorSendInitialState{}        -> T.pack "MirrorSendInitialState"
  MirrorSendNextStep{}            -> T.pack "MirrorSendNextStep"
  MirrorSendStepOk{}              -> T.pack "MirrorSendStepOk"
  MirrorSendStepMismatch{}        -> T.pack "MirrorSendStepMismatch"
  MirrorSendAllStepsDone          -> T.pack "MirrorSendAllStepsDone"

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
data MkRunMirror t = MkRunMirror t ApalacheConfig TraceGenerationConfig
data MkRunMirrorWithTraces t = MkRunMirrorWithTraces t ApalacheConfig [FilePath]
data MkRunMirrorGenTraces t = MkRunMirrorGenTraces t ApalacheConfig TraceGenerationConfig (Maybe FilePath)
data MkReplayAll t = MkReplayAll t (StateDriver IO) [ItfTrace]
data MkReplayOne t = MkReplayOne t (StateDriver IO) ItfTrace

class Step a where
  exec :: a -> IO [MirrorStep]

instance Transport t => Step (RecvMsg t) where
  exec (RecvMsg transport) = do
    msg <- recvMsg transport
    case msg of
      Right (Register apCfg tc) -> do
        steps <- exec (MkRunMirror transport apCfg tc)
        pure (MirrorRecvRegister apCfg tc : steps)
      Right (RegisterTraces apCfg traces) -> do
        steps <- exec (MkRunMirrorWithTraces transport apCfg traces)
        pure (MirrorRecvRegisterTraces apCfg traces : steps)
      Right (RegisterGenTraces apCfg tc destPath) -> do
        steps <- exec (MkRunMirrorGenTraces transport apCfg tc destPath)
        pure (MirrorRecvRegisterGenTraces apCfg tc destPath : steps)
      Right _ -> do
        sendMsg transport (ProtocolError (T.pack "Expected Register message"))
        pure [MirrorSendProtocolError (T.pack "Expected Register message")]
      Left err -> do
        sendMsg transport (ProtocolError (T.pack err))
        pure [MirrorSendProtocolError (T.pack err)]

instance Transport t => Step (MkRunMirror t) where
  exec (MkRunMirror transport cfg tc) = do
    traceRes <- generateTraces cfg tc
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
    where
      expandPath p = do
        isDir <- doesDirectoryExist p
        if isDir then findTraceFiles p else pure [p]

instance Transport t => Step (MkRunMirrorGenTraces t) where
  exec (MkRunMirrorGenTraces transport cfg tc destPath) = do
    result <- generateTraceFiles cfg tc
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
        sendMsg transport (GenTracesDone finalPaths)
        pure [MirrorSendGenTracesDone finalPaths]

instance Transport t => Step (MkReplayAll t) where
  exec (MkReplayAll _ _ []) = pure []
  exec (MkReplayAll transport driver (t : ts)) = do
    steps <- exec (MkReplayOne transport driver t)
    rest <- exec (MkReplayAll transport driver ts)
    pure (steps ++ rest)

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
          StateMismatch expected actualDiffs _ -> do
            sendMsg transport (StepMismatch expected actualDiffs)
            pure (sendStep : recvStep : MirrorSendStepMismatch sidx diff : [])

replaySteps :: Transport t => t -> StateDriver IO -> ItfTrace -> IO [MirrorStep]
replaySteps transport driver = exec . MkReplayOne transport driver

runMirror :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> IO [MirrorStep]
runMirror transport cfg tc = exec (MkRunMirror transport cfg tc)

runMirrorWithTraces :: Transport t => t -> ApalacheConfig -> [FilePath] -> IO [MirrorStep]
runMirrorWithTraces transport cfg traces = exec (MkRunMirrorWithTraces transport cfg traces)

runMirrorGenTraces :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> IO [MirrorStep]
runMirrorGenTraces transport cfg tc destPath = exec (MkRunMirrorGenTraces transport cfg tc destPath)

run :: Transport t => t -> IO [MirrorStep]
run = exec . RecvMsg
