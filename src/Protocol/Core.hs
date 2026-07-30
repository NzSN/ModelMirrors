module Protocol.Core
  ( ClientMessage (..)
  , MirrorMessage (..)
  , ProtocolState (..)
  , ActionName
  , ErrorMessage
  , StatusMessage
  , StateValuation
  , InvariantName
  , ExportName
  , TransitionId
  , InvariantId
  , SnapshotId
  , StepNo
  , MaxSteps
  , TransitionCount
  , InvariantCount
  , DiffHint (..)
  , PathSeg (..)
  , Path
  , renderPath
  , renderDiffHint
  , renderDiffHints
  ) where

import Apalache.Rpc.Types (ApalacheSpec)
import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult, Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Engine.Types
  ( DiffHint (..)
  , Path
  , PathSeg (..)
  , renderDiffHint
  , renderDiffHints
  , renderPath
  )

type ActionName = Text
type ErrorMessage = Text
type StatusMessage = Text
type StateValuation = Map Text Value
type InvariantName = Text
type ExportName = Text
type TransitionId = Int
type InvariantId = Int
type SnapshotId = Int
type StepNo = Int
type MaxSteps = Int
type TransitionCount = Int
type InvariantCount = Int

data ClientMessage
  = Register !ApalacheConfig !TraceGenerationConfig !(Maybe ApalacheSpec)
  | RegisterTraces !ApalacheConfig ![FilePath]
  | RegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
  | RegisterExplore !ApalacheSpec ![InvariantName] ![ExportName] !MaxSteps
  | RegisterExploreSession !ApalacheSpec ![InvariantName] ![ExportName]
  | ExploreAssumeTransition !TransitionId
  | ExploreNextStep
  | ExploreQueryState
  | ExploreCheckInvariant !InvariantId
  | ExploreAssumeState !StateValuation
  | ExploreRollback !SnapshotId
  | ExploreDone
  | ReportState !StateValuation
  deriving (Show, Eq)

data MirrorMessage
  = SpecValidated !ValidateResult
  | InitialState !ActionName !StateValuation
  | NextStep !ActionName !StateValuation
  | StepOk
  | StepMismatch !StateValuation !StateValuation ![DiffHint]
  | AllStepsDone
  | GenTracesDone ![FilePath]
  | RegisterError !ErrorMessage
  | ProtocolError !ErrorMessage
  | ExplorerReady !TransitionCount !TransitionCount !InvariantCount
  | ExploreTransitionStatus !StatusMessage
  | ExploreStepDone !StepNo
  | ExploreState !StateValuation
  | ExploreInvariantStatus !StatusMessage
  | ExploreAssumeStatus !StatusMessage
  | ExploreRollbackDone !SnapshotId
  | ExploreSessionDone
  deriving (Show, Eq)

data ProtocolState
  = Idle
  | Validating
  | Ready
  | Stepping
  | Done
  deriving (Show, Eq)
