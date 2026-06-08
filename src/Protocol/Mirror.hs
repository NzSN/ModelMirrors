module Protocol.Mirror
  ( MirrorStep (..)
  , mirrorStepActionName
  , normalizeMirrorSteps
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
import Control.Monad (forM, forM_)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (diffState, traceSteps)
import Engine.Interactive (makeTransportDriver)
import Engine.Replay (StateDriver (..))
import Engine.Types (Step (..), StepCommand (..), StateDiff (..))
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

run :: Transport t => t -> IO [MirrorStep]
run transport = do
  msg <- recvMsg transport
  case msg of
    Right (Register apCfg tc) -> do
      steps <- runMirror transport apCfg tc
      pure (MirrorRecvRegister apCfg tc : steps)
    Right (RegisterTraces apCfg traces) -> do
      steps <- runMirrorWithTraces transport apCfg traces
      pure (MirrorRecvRegisterTraces apCfg traces : steps)
    Right (RegisterGenTraces apCfg tc destPath) -> do
      steps <- runMirrorGenTraces transport apCfg tc destPath
      pure (MirrorRecvRegisterGenTraces apCfg tc destPath : steps)
    Right _ -> do
      sendMsg transport (ProtocolError (T.pack "Expected Register message"))
      pure [MirrorSendProtocolError (T.pack "Expected Register message")]
    Left err -> do
      sendMsg transport (ProtocolError (T.pack err))
      pure [MirrorSendProtocolError (T.pack err)]

runMirror :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> IO [MirrorStep]
runMirror transport cfg tc = do
  traceRes <- generateTraces cfg tc
  case traceRes of
    Left err -> do
      sendMsg transport (RegisterError (unApalacheError err))
      pure [MirrorSendRegisterError (unApalacheError err)]
    Right (TracesGenerated traces) -> do
      sendMsg transport (SpecValidated SpecValid)
      let driver = makeTransportDriver transport
      stepResults <- concat <$> forM traces (replaySteps transport driver)
      sendMsg transport AllStepsDone
      pure (MirrorSendSpecValidatedValid : stepResults ++ [MirrorSendAllStepsDone])
    Right (GenerationError e) -> do
      sendMsg transport (ProtocolError e)
      pure [MirrorSendProtocolError e]

runMirrorWithTraces :: Transport t => t -> ApalacheConfig -> [FilePath] -> IO [MirrorStep]
runMirrorWithTraces transport cfg tracePaths = do
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
      stepResults <- concat <$> forM traces' (replaySteps transport driver)
      sendMsg transport AllStepsDone
      pure (MirrorSendSpecValidatedValid : stepResults ++ [MirrorSendAllStepsDone])
  where
    expandPath p = do
      isDir <- doesDirectoryExist p
      if isDir then findTraceFiles p else pure [p]

runMirrorGenTraces :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> IO [MirrorStep]
runMirrorGenTraces transport cfg tc destPath = do
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

replaySteps :: Transport t => t -> StateDriver IO -> ItfTrace -> IO [MirrorStep]
replaySteps transport driver trace = do
  let steps = traceSteps trace
  go driver steps
  where
    go _ [] = pure []
    go (StateDriver report) (step : rest) = do
      let action = stepAct step
          sidx = stepIdx step
          cmd = if sidx == 0
                then CmdInitial action (stepVars step)
                else CmdNextStep action (stepParams step)
          sendStep = if sidx == 0
                     then MirrorSendInitialState action (stepVars step)
                     else MirrorSendNextStep action (stepParams step)
      actual <- report cmd
      let diff = diffState (stepVars step) actual
          recvStep = MirrorRecvReportState sidx action
      case diff of
        StatesMatch -> do
          sendMsg transport StepOk
          restSteps <- go (StateDriver report) rest
          pure (sendStep : recvStep : MirrorSendStepOk sidx : restSteps)
        StateMismatch expected actualDiffs _ -> do
          sendMsg transport (StepMismatch expected actualDiffs)
          pure (sendStep : recvStep : MirrorSendStepMismatch sidx diff : [])
