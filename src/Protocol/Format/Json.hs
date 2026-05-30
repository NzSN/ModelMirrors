{-# OPTIONS_GHC -Wno-orphans #-}

module Protocol.Format.Json
  ( module Protocol.Core
  ) where

import Protocol.Core

import Data.Aeson
import Data.Aeson.Key (fromString)
import qualified Data.Text as T

instance ToJSON ClientMessage where
  toJSON (Register path config) = object
    [ fromString "proto_step" .= T.pack "register"
    , fromString "specPath" .= path
    , fromString "traceConfig" .= config
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
          Register <$> o .: fromString "specPath" <*> o .: fromString "traceConfig"
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
  toJSON (NextStep action state) = object
    [ fromString "proto_step" .= T.pack "next_step"
    , fromString "action" .= action
    , fromString "state" .= state
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
  toJSON (ProtocolError err) = object
    [ fromString "proto_step" .= T.pack "protocol_error"
    , fromString "error" .= err
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
          NextStep <$> o .: fromString "action" <*> o .: fromString "state"
      t | t == T.pack "step_ok" ->
          pure StepOk
      t | t == T.pack "step_mismatch" ->
          StepMismatch <$> o .: fromString "expected" <*> o .: fromString "actual"
      t | t == T.pack "all_steps_done" ->
          pure AllStepsDone
      t | t == T.pack "protocol_error" ->
          ProtocolError <$> o .: fromString "error"
      _ ->
          fail $ "Unknown MirrorMessage tag: " ++ T.unpack tag
