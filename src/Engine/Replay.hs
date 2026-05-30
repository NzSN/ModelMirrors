module Engine.Replay (EngineM (..), StateDriver (..)) where

import Apalache.Types (ItfTrace (..), Value (..))
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StepCommand (..), StateDiff (..))

newtype StateDriver m = StateDriver
  { runDriver :: StepCommand -> m (Map Text Value)
  }

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> StateDriver m -> m [StateDiff]
  replayTrace trace (StateDriver report) = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        let action = stepAction step
            cmd = if stepIdx step == 0
                  then CmdInitial action (stepVars step)
                  else CmdNextStep action (stepVars step)
        actual <- report cmd
        let diff = diffState (stepVars step) actual
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]

instance EngineM Identity

stepAction :: Step -> Text
stepAction step = case Map.lookup (T.pack "action_taken") (stepVars step) of
  Just (VStr a) -> a
  _             -> mempty
