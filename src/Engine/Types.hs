module Engine.Types where

import Apalache.Types (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data Step = Step
  { stepIdx  :: !Int
  , stepVars :: !(Map Text Value)
  } deriving (Show, Eq)

data StepCommand
  = CmdInitial !(Map Text Value)
  | CmdNextStep !(Map Text Value)
  deriving (Show, Eq)

data VarDiff
  = ValueMismatch !Text !Value !Value
  | MissingVar    !Text !Value
  | ExtraVar      !Text !Value
  deriving (Show, Eq)

data StateDiff
  = StatesMatch
  | StateMismatch
      !(Map Text Value)
      !(Map Text Value)
      ![VarDiff]
  deriving (Show, Eq)
