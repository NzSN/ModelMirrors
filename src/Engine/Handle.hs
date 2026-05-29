module Engine.Handle (EngineM (..), StateDriver (..)) where

import Apalache.Types (ItfTrace (..), Value)
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StateDiff (..))

newtype StateDriver m = StateDriver
  { runDriver :: Step -> m (Map Text Value)
  }

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> StateDriver m -> m [StateDiff]
  replayTrace trace (StateDriver report) = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        actual <- report step
        let diff = diffState (stepVars step) actual
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]

instance EngineM Identity
