module Protocol.Mirror
  ( runMirror
  , runMirrorWithTraces
  ) where

import Apalache.Command (generateTraces)
import Apalache.Trace (findTraceFiles, readTrace)
import Apalache.Types
    ( ApalacheConfig (..)
    , ApalacheError (..)
    , ItfTrace (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , ValidateResult (..)
    )
import Control.Monad (forM_)
import Data.Text qualified as T
import Engine.Core (diffState, traceSteps)
import Engine.Interactive (makeTransportDriver)
import Engine.Replay (StateDriver (..))
import Engine.Types (Step (..), StepCommand (..), StateDiff (..))
import Protocol.Core (MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, sendMsg)
import System.Directory (doesDirectoryExist)

runMirror :: Transport t => t -> FilePath -> TraceGenerationConfig -> IO ()
runMirror transport specPath config = do
  let cfg = ApalacheConfig specPath Nothing Nothing (cinit config)
  traceRes <- generateTraces cfg config
  case traceRes of
    Left err ->
      sendMsg transport (RegisterError (unApalacheError err))
    Right (TracesGenerated traces) -> do
      sendMsg transport (SpecValidated SpecValid)
      let driver = makeTransportDriver transport
      forM_ traces $ \trace ->
        replaySteps transport driver trace
      sendMsg transport AllStepsDone
    Right (GenerationError e) ->
      sendMsg transport (ProtocolError e)

runMirrorWithTraces :: Transport t => t -> [FilePath] -> IO ()
runMirrorWithTraces transport tracePaths = do
  expanded <- concat <$> mapM expandPath tracePaths
  traces <- mapM readTrace expanded
  case sequence traces of
    Left err -> sendMsg transport (RegisterError (T.pack err))
    Right parsed -> do
      sendMsg transport (SpecValidated SpecValid)
      let driver = makeTransportDriver transport
      forM_ parsed $ \trace ->
        replaySteps transport driver trace
      sendMsg transport AllStepsDone
  where
    expandPath p = do
      isDir <- doesDirectoryExist p
      if isDir then findTraceFiles p else pure [p]

replaySteps :: Transport t => t -> StateDriver IO -> ItfTrace -> IO ()
replaySteps transport driver trace = do
  let steps = traceSteps trace
  go driver steps
  where
    go _ [] = pure ()
    go (StateDriver report) (step : rest) = do
      let action = stepAct step
          cmd = if stepIdx step == 0
                then CmdInitial action (stepVars step)
                else CmdNextStep action (stepParams step)
      actual <- report cmd
      let diff = diffState (stepVars step) actual
      case diff of
        StatesMatch -> do
          sendMsg transport StepOk
          go (StateDriver report) rest
        StateMismatch expected actualDiffs _ -> do
          sendMsg transport (StepMismatch expected actualDiffs)
