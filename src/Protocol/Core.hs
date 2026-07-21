module Protocol.Core
  ( ClientMessage (..)
  , MirrorMessage (..)
  , ProtocolState (..)
  ) where

import Apalache.Rpc.Types (ApalacheSpec)
import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult, Value)
import Data.Map.Strict (Map)
import Data.Text (Text)

data ClientMessage
  = Register !ApalacheConfig !TraceGenerationConfig
  | RegisterTraces !ApalacheConfig ![FilePath]
  | RegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath)
  | RegisterExplore !ApalacheSpec ![Text] ![Text] !Int
  | RegisterExploreSession !ApalacheSpec ![Text] ![Text]
  | ExploreAssumeTransition !Int
  | ExploreNextStep
  | ExploreQueryState
  | ExploreCheckInvariant !Int
  | ExploreAssumeState !(Map Text Value)
  | ExploreRollback !Int
  | ExploreDone
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
  | ExplorerReady !Int !Int !Int
  | ExploreTransitionStatus !Text
  | ExploreStepDone !Int
  | ExploreState !(Map Text Value)
  | ExploreInvariantStatus !Text
  | ExploreAssumeStatus !Text
  | ExploreRollbackDone !Int
  | ExploreSessionDone
  deriving (Show, Eq)

data ProtocolState
  = Idle
  | Validating
  | Ready
  | Stepping
  | Done
  deriving (Show, Eq)
