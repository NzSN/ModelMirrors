module Protocol.Core
  ( ClientMessage (..)
  , MirrorMessage (..)
  , ProtocolState (..)
  ) where

import Apalache.Types (TraceGenerationConfig, ValidateResult, Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data ClientMessage
  = Register !FilePath !TraceGenerationConfig
  | RegisterTraces ![FilePath]
  | ReportState !(Map Text Value)
  deriving (Show, Eq)

data MirrorMessage
  = SpecValidated !ValidateResult
  | InitialState !Text !(Map Text Value)
  | NextStep !Text !(Map Text Value)
  | StepOk
  | StepMismatch !(Map Text Value) !(Map Text Value)
  | AllStepsDone
  | RegisterError !Text
  | ProtocolError !Text
  deriving (Show, Eq)

data ProtocolState
  = Idle
  | Validating
  | Ready
  | Stepping
  | Done
  deriving (Show, Eq)
