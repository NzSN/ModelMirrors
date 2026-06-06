module Protocol.Mirror
  ( runMirror
  ) where

import Apalache.Command (generateTraces, validateSpec)
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
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)

runMirror :: Transport t => t -> FilePath -> TraceGenerationConfig -> IO ()
runMirror transport specPath config = do
  let cfg = ApalacheConfig specPath Nothing Nothing (cinit config) Nothing
  result <- validateSpec cfg (lengthBound config)
  case result of
    Left err ->
      sendMsg transport (ProtocolError (unApalacheError err))
    Right validationResult -> do
      sendMsg transport (SpecValidated validationResult)
      case validationResult of
        SpecInvalid _ -> pure ()
        SpecValid -> do
          traceRes <- generateTraces cfg config
          case traceRes of
            Left err ->
              sendMsg transport (ProtocolError (unApalacheError err))
            Right (TracesGenerated traces) -> do
              let driver = makeTransportDriver transport
              forM_ traces $ \trace ->
                replaySteps transport driver trace
              sendMsg transport AllStepsDone
            Right (GenerationError e) ->
              sendMsg transport (ProtocolError e)

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
