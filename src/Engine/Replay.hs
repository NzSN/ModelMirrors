module Engine.Replay
  ( EngineM (..)
  , StateDriver (..)
  , StateDiff (..)
  ) where

import Apalache.Types (ItfTrace (..), Value)
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StepCommand (..), StateDiff (..))

newtype StateDriver m = StateDriver
  { runDriver :: StepCommand -> m (Map Text Value)
  }

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> StateDriver m -> m [StateDiff]

  onStepResult :: StateDiff -> m ()
  onStepResult _ = pure ()

  replayTrace trace (StateDriver report) = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        let action = stepAct step
            cmd = if stepIdx step == 0
                  then CmdInitial action (stepVars step)
                  else CmdNextStep action (stepParams step)
        actual <- report cmd
        let diff = diffState (stepVars step) actual
        onStepResult diff
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]

instance EngineM Identity
