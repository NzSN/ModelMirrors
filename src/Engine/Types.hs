module Engine.Types where

import Apalache.Types (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data Step = Step
  { stepIdx    :: !Int
  , stepAct    :: !Text
  , stepParams :: !(Map Text Value)
  , stepVars   :: !(Map Text Value)
  } deriving (Show, Eq)

data StepCommand
  = CmdInitial !Text !(Map Text Value)
  | CmdNextStep !Text !(Map Text Value)
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
