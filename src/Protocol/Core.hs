module Protocol.Core
  ( ClientMessage (..)
  , MirrorMessage (..)
  , ProtocolState (..)
  ) where

import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult, Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data ClientMessage
  = Register !ApalacheConfig !TraceGenerationConfig
  | RegisterTraces ![FilePath]
  | RegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath)
  | ReportState !(Map Text Value)
  deriving (Show, Eq)

data MirrorMessage
  = SpecValidated !ValidateResult
  | InitialState !Text !(Map Text Value)
  | NextStep !Text !(Map Text Value)
  | StepOk
  | StepMismatch !(Map Text Value) !(Map Text Value)
  | AllStepsDone
  | GenTracesDone ![FilePath]
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
