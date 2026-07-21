{-# OPTIONS_GHC -Wno-orphans #-}

module Protocol.Format.Json
  ( module Protocol.Core
  ) where

import Protocol.Core

import Data.Aeson
import Data.Aeson.Key (fromString)
import qualified Data.Text as T

instance ToJSON ClientMessage where
  toJSON (Register apCfg tc) = object
    [ fromString "proto_step" .= T.pack "register"
    , fromString "apalacheConfig" .= apCfg
    , fromString "traceConfig" .= tc
    ]
  toJSON (RegisterTraces apCfg traces) = object
    [ fromString "proto_step" .= T.pack "register_traces"
    , fromString "apalacheConfig" .= apCfg
    , fromString "itfTracePaths" .= traces
    ]
  toJSON (RegisterGenTraces apCfg tc dest) = object
    [ fromString "proto_step" .= T.pack "register_trace_gen"
    , fromString "apalacheConfig" .= apCfg
    , fromString "traceConfig" .= tc
    , fromString "destPath" .= dest
    ]
  toJSON (RegisterExplore spec invs exports maxSteps) = object
    [ fromString "proto_step" .= T.pack "register_explore"
    , fromString "spec" .= spec
    , fromString "invariants" .= invs
    , fromString "exports" .= exports
    , fromString "maxSteps" .= maxSteps
    ]
  toJSON (RegisterExploreSession spec invs exports) = object
    [ fromString "proto_step" .= T.pack "register_explore_session"
    , fromString "spec" .= spec
    , fromString "invariants" .= invs
    , fromString "exports" .= exports
    ]
  toJSON (ExploreAssumeTransition tid) = object
    [ fromString "proto_step" .= T.pack "explore_assume_transition"
    , fromString "transitionId" .= tid
    ]
  toJSON ExploreNextStep = object
    [ fromString "proto_step" .= T.pack "explore_next_step"
    ]
  toJSON ExploreQueryState = object
    [ fromString "proto_step" .= T.pack "explore_query_state"
    ]
  toJSON (ExploreCheckInvariant iid) = object
    [ fromString "proto_step" .= T.pack "explore_check_invariant"
    , fromString "invariantId" .= iid
    ]
  toJSON (ExploreAssumeState state) = object
    [ fromString "proto_step" .= T.pack "explore_assume_state"
    , fromString "state" .= state
    ]
  toJSON (ExploreRollback snap) = object
    [ fromString "proto_step" .= T.pack "explore_rollback"
    , fromString "snapshotId" .= snap
    ]
  toJSON ExploreDone = object
    [ fromString "proto_step" .= T.pack "explore_done"
    ]
  toJSON (ReportState state) = object
    [ fromString "proto_step" .= T.pack "report_state"
    , fromString "state" .= state
    ]

instance FromJSON ClientMessage where
  parseJSON = withObject "ClientMessage" $ \o -> do
    tag <- o .: fromString "proto_step"
    case tag of
      t | t == T.pack "register" ->
          Register <$> o .: fromString "apalacheConfig" <*> o .: fromString "traceConfig"
      t | t == T.pack "register_traces" ->
          RegisterTraces <$> o .: fromString "apalacheConfig" <*> o .: fromString "itfTracePaths"
      t | t == T.pack "register_trace_gen" ->
          RegisterGenTraces <$> o .: fromString "apalacheConfig"
                            <*> o .: fromString "traceConfig"
                            <*> o .:? fromString "destPath" .!= Nothing
      t | t == T.pack "register_explore" ->
          RegisterExplore <$> o .: fromString "spec"
                          <*> o .: fromString "invariants"
                          <*> o .: fromString "exports"
                          <*> o .:? fromString "maxSteps" .!= 10
      t | t == T.pack "register_explore_session" ->
          RegisterExploreSession <$> o .: fromString "spec"
                                 <*> o .: fromString "invariants"
                                 <*> o .: fromString "exports"
      t | t == T.pack "explore_assume_transition" ->
          ExploreAssumeTransition <$> o .: fromString "transitionId"
      t | t == T.pack "explore_next_step" ->
          pure ExploreNextStep
      t | t == T.pack "explore_query_state" ->
          pure ExploreQueryState
      t | t == T.pack "explore_check_invariant" ->
          ExploreCheckInvariant <$> o .: fromString "invariantId"
      t | t == T.pack "explore_assume_state" ->
          ExploreAssumeState <$> o .: fromString "state"
      t | t == T.pack "explore_rollback" ->
          ExploreRollback <$> o .: fromString "snapshotId"
      t | t == T.pack "explore_done" ->
          pure ExploreDone
      t | t == T.pack "report_state" ->
          ReportState <$> o .: fromString "state"
      _ ->
          fail $ "Unknown ClientMessage tag: " ++ T.unpack tag

instance ToJSON MirrorMessage where
  toJSON (SpecValidated result) = object
    [ fromString "proto_step" .= T.pack "spec_validated"
    , fromString "result" .= result
    ]
  toJSON (InitialState action state) = object
    [ fromString "proto_step" .= T.pack "initial_state"
    , fromString "action" .= action
    , fromString "state" .= state
    ]
  toJSON (NextStep action params) = object
    [ fromString "proto_step" .= T.pack "next_step"
    , fromString "action" .= action
    , fromString "parameters" .= params
    ]
  toJSON StepOk = object
    [ fromString "proto_step" .= T.pack "step_ok"
    ]
  toJSON (StepMismatch expected actual) = object
    [ fromString "proto_step" .= T.pack "step_mismatch"
    , fromString "expected" .= expected
    , fromString "actual" .= actual
    ]
  toJSON AllStepsDone = object
    [ fromString "proto_step" .= T.pack "all_steps_done"
    ]
  toJSON (GenTracesDone paths) = object
    [ fromString "proto_step" .= T.pack "gen_traces_done"
    , fromString "itfTracePaths" .= paths
    ]
  toJSON (RegisterError err) = object
    [ fromString "proto_step" .= T.pack "register_error"
    , fromString "error" .= err
    ]
  toJSON (ProtocolError err) = object
    [ fromString "proto_step" .= T.pack "protocol_error"
    , fromString "error" .= err
    ]
  toJSON (ExplorerReady nInit nNext nInv) = object
    [ fromString "proto_step" .= T.pack "explorer_ready"
    , fromString "initTransitions" .= nInit
    , fromString "nextTransitions" .= nNext
    , fromString "stateInvariants" .= nInv
    ]
  toJSON (ExploreTransitionStatus status) = object
    [ fromString "proto_step" .= T.pack "explore_transition_status"
    , fromString "status" .= status
    ]
  toJSON (ExploreStepDone stepNo) = object
    [ fromString "proto_step" .= T.pack "explore_step_done"
    , fromString "stepNo" .= stepNo
    ]
  toJSON (ExploreState state) = object
    [ fromString "proto_step" .= T.pack "explore_state"
    , fromString "state" .= state
    ]
  toJSON (ExploreInvariantStatus status) = object
    [ fromString "proto_step" .= T.pack "explore_invariant_status"
    , fromString "status" .= status
    ]
  toJSON (ExploreAssumeStatus status) = object
    [ fromString "proto_step" .= T.pack "explore_assume_status"
    , fromString "status" .= status
    ]
  toJSON (ExploreRollbackDone snap) = object
    [ fromString "proto_step" .= T.pack "explore_rollback_done"
    , fromString "snapshotId" .= snap
    ]
  toJSON ExploreSessionDone = object
    [ fromString "proto_step" .= T.pack "explore_session_done"
    ]

instance FromJSON MirrorMessage where
  parseJSON = withObject "MirrorMessage" $ \o -> do
    tag <- o .: fromString "proto_step"
    case tag of
      t | t == T.pack "spec_validated" ->
          SpecValidated <$> o .: fromString "result"
      t | t == T.pack "initial_state" ->
          InitialState <$> o .: fromString "action" <*> o .: fromString "state"
      t | t == T.pack "next_step" ->
          NextStep <$> o .: fromString "action" <*> o .: fromString "parameters"
      t | t == T.pack "step_ok" ->
          pure StepOk
      t | t == T.pack "step_mismatch" ->
          StepMismatch <$> o .: fromString "expected" <*> o .: fromString "actual"
      t | t == T.pack "all_steps_done" ->
          pure AllStepsDone
      t | t == T.pack "gen_traces_done" ->
          GenTracesDone <$> o .: fromString "itfTracePaths"
      t | t == T.pack "protocol_error" ->
          ProtocolError <$> o .: fromString "error"
      t | t == T.pack "register_error" ->
          RegisterError <$> o .: fromString "error"
      t | t == T.pack "explorer_ready" ->
          ExplorerReady <$> o .: fromString "initTransitions"
                        <*> o .: fromString "nextTransitions"
                        <*> o .: fromString "stateInvariants"
      t | t == T.pack "explore_transition_status" ->
          ExploreTransitionStatus <$> o .: fromString "status"
      t | t == T.pack "explore_step_done" ->
          ExploreStepDone <$> o .: fromString "stepNo"
      t | t == T.pack "explore_state" ->
          ExploreState <$> o .: fromString "state"
      t | t == T.pack "explore_invariant_status" ->
          ExploreInvariantStatus <$> o .: fromString "status"
      t | t == T.pack "explore_assume_status" ->
          ExploreAssumeStatus <$> o .: fromString "status"
      t | t == T.pack "explore_rollback_done" ->
          ExploreRollbackDone <$> o .: fromString "snapshotId"
      t | t == T.pack "explore_session_done" ->
          pure ExploreSessionDone
      _ ->
          fail $ "Unknown MirrorMessage tag: " ++ T.unpack tag
