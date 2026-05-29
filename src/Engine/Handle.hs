module Engine.Handle (EngineM (..), StateReporter (..)) where

import Apalache.Types (ItfTrace (..), Value)
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StateDiff (..))

newtype StateReporter m = StateReporter
  { runReporter :: Step -> m (Map Text Value)
  }

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> StateReporter m -> m [StateDiff]
  replayTrace trace (StateReporter report) = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        actual <- report step
        let diff = diffState (stepVars step) actual
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]

instance EngineM Identity
