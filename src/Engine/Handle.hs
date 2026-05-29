module Engine.Handle (EngineM (..)) where

import Apalache.Types (ItfTrace (..), Value)
import Data.Functor.Identity (Identity)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Core (diffState, traceSteps)
import Engine.Types (Step (..), StateDiff (..))

class Monad m => EngineM m where
  replayTrace :: ItfTrace -> (Step -> m (Map Text Value)) -> m [StateDiff]
  replayTrace trace report = go (traceSteps trace)
    where
      go [] = pure []
      go (step : steps) = do
        actual <- report step
        let diff = diffState (stepVars step) actual
        case diff of
          StatesMatch -> (diff :) <$> go steps
          StateMismatch{} -> pure [diff]

instance EngineM Identity
