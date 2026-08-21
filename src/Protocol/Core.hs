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
  , TraceContent
  , JobId (..)
  , JobKind (..)
  , JobPhase (..)
  , JobOutcome (..)
  , DiffHint (..)
  , PathSeg (..)
  , Path
  , renderPath
  , renderDiffHint
  , renderDiffHints
  ) where

import Apalache.Rpc.Types (ApalacheSpec)
import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult, Value)
import qualified Data.Aeson as A
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
type TraceContent = A.Value

-- | Server-generated, opaque-to-the-client identifier of an async job.
newtype JobId = JobId Text
  deriving (Show, Eq, Ord)

data JobKind
  = ValidateJob
  | GenTracesJob
  deriving (Show, Eq)

data JobPhase
  = JobPending    -- ^ accepted, waiting for a worker slot
  | JobRunning    -- ^ apalache invocation in flight
  | JobDone       -- ^ terminal, result available
  | JobFailed     -- ^ terminal, infrastructure failure
  | JobCancelled  -- ^ terminal, cancelled by client
  | JobUnknown    -- ^ queried JobId not (or no longer) known
  deriving (Show, Eq)

-- | Terminal payload of an async job; mirrors the corresponding synchronous
-- reply exactly ('SpecValidated' / 'GenTracesDone' / infra 'RegisterError').
data JobOutcome
  = JobValidateDone  !ValidateResult
  | JobGenTracesDone ![FilePath] ![TraceContent]
  | JobInfraError    !Text
  deriving (Show, Eq)

data ClientMessage
  = Register !ApalacheConfig !TraceGenerationConfig !(Maybe ApalacheSpec)
  | RegisterTraces !ApalacheConfig ![FilePath]
  | RegisterGenTraces !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
  | RegisterExplore !ApalacheSpec ![InvariantName] ![ExportName] !MaxSteps
  | RegisterExploreSession !ApalacheSpec ![InvariantName] ![ExportName]
  | RegisterValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)
  | RegisterValidateAsync !ApalacheConfig !Int !(Maybe ApalacheSpec)
  | RegisterGenTracesAsync !ApalacheConfig !TraceGenerationConfig !(Maybe FilePath) !(Maybe ApalacheSpec)
  | QueryJob !JobId
  | AwaitJob !JobId !(Maybe Int)
  | CancelJob !JobId
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
  | GenTracesDone ![FilePath] ![TraceContent]
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
  | JobAccepted !JobId !JobKind
  | JobStatus   !JobId !JobPhase
  | JobResult   !JobId !JobOutcome
  deriving (Show, Eq)

data ProtocolState
  = Idle
  | Validating
  | Ready
  | Stepping
  | Done
  deriving (Show, Eq)
