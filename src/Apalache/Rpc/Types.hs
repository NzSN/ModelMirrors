{-# LANGUAGE OverloadedStrings #-}
module Apalache.Rpc.Types
  ( JsonRpcRequest (..)
  , JsonRpcResponse (..)
  , RpcError (..)
  , RpcClient (..)
  , ApalacheServer (..)
  , ApalacheSpec (..)
  , mkSpecFromFile
  , mkSpecFromSource
  , LoadSpecParams (..)
  , LoadSpecResult (..)
  , AssumeTransitionParams (..)
  , AssumeTransitionResult (..)
  , NextStateParams (..)
  , NextStateResult (..)
  , InvariantKind (..)
  , CheckInvariantParams (..)
  , CheckInvariantResult (..)
  , QueryKind (..)
  , QueryParams (..)
  , QueryResult (..)
  , AssumeStateParams (..)
  , AssumeStateResult (..)
  , RollbackParams (..)
  , DisposeSpecParams (..)
  , TransitionStatus (..)
  , InvariantStatus (..)
  , SpecParams (..)
  , TransitionRef (..)
  , InvariantRef (..)
  , HealthResult (..)
  ) where

import Apalache.Types (ItfTrace, Value)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , withObject
  , withText
  , (.=)
  , (.:)
  , (.:?)
  , object
  )
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Network.HTTP.Client (Manager)
import System.Process (ProcessHandle)

data JsonRpcRequest = JsonRpcRequest
  { jrqMethod :: !Text
  , jrqParams :: !A.Value
  , jrqId     :: !Int
  }

instance ToJSON JsonRpcRequest where
  toJSON r = object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "method"  .= jrqMethod r
    , "params"  .= jrqParams r
    , "id"      .= jrqId r
    ]

data JsonRpcResponse
  = JrSuccess { jrsId :: !Int, jrsResult :: !A.Value }
  | JrError   { jreId :: !Int, jreCode :: !Int, jreMessage :: !Text, jreData :: !(Maybe A.Value) }

instance FromJSON JsonRpcResponse where
  parseJSON = withObject "JsonRpcResponse" $ \o -> do
    rid <- o .: "id"
    case KM.lookup "error" o of
      Just (A.Object errObj) -> do
        code <- errObj .: "code"
        msg  <- errObj .: "message"
        dat  <- errObj .:? "data"
        pure $ JrError rid code msg dat
      Just _ -> fail "error field must be an object"
      Nothing -> do
        result <- o .: "result"
        pure $ JrSuccess rid result

data RpcError
  = RpcHttpError     !Text
  | RpcProtocolError !Int !Text
  | RpcParseError    !Text
  deriving (Show)

data ApalacheServer = ApalacheServer
  { serverPort    :: !Int
  , serverProcess :: !ProcessHandle
  }

data RpcClient = RpcClient
  { rpcBaseUrl :: !Text
  , rpcManager :: !Manager
  , rpcNextId  :: !(IORef Int)
  }

newtype ApalacheSpec = ApalacheSpec
  { getSpecSources :: [Text]
  } deriving (Show, Eq)

instance ToJSON ApalacheSpec where
  toJSON s = object [ "sources" .= getSpecSources s ]

instance FromJSON ApalacheSpec where
  parseJSON = withObject "ApalacheSpec" $ \o ->
    ApalacheSpec <$> o .: "sources"

mkSpecFromFile :: FilePath -> IO ApalacheSpec
mkSpecFromFile path = ApalacheSpec . pure <$> TIO.readFile path

mkSpecFromSource :: Text -> ApalacheSpec
mkSpecFromSource src = ApalacheSpec [src]

data TransitionStatus
  = TransEnabled
  | TransDisabled
  | TransUnknown
  deriving (Show, Eq)

data InvariantStatus
  = InvSatisfied
  | InvViolated
  | InvUnknown
  deriving (Show, Eq)

data InvariantKind
  = StateInvariant
  | ActionInvariant
  deriving (Show, Eq)

data TransitionRef = TransitionRef
  { trIndex  :: !Int
  , trLabels :: ![Text]
  } deriving (Show, Eq)

data InvariantRef = InvariantRef
  { irIndex  :: !Int
  , irLabels :: ![Text]
  } deriving (Show, Eq)

data SpecParams = SpecParams
  { spInitTransitions  :: ![TransitionRef]
  , spNextTransitions  :: ![TransitionRef]
  , spStateInvariants  :: ![InvariantRef]
  , spActionInvariants :: ![InvariantRef]
  } deriving (Show, Eq)

data HealthResult = HealthResult
  { hrStatus :: !Text
  } deriving (Show, Eq)

data LoadSpecParams = LoadSpecParams
  { lspSources    :: ![Text]
  , lspInit       :: !(Maybe Text)
  , lspNext       :: !(Maybe Text)
  , lspInvariants :: ![Text]
  , lspExports    :: ![Text]
  } deriving (Show, Eq)

data LoadSpecResult = LoadSpecResult
  { lsrSessionId  :: !Text
  , lsrSnapshotId :: !Int
  , lsrSpecParams :: !SpecParams
  } deriving (Show, Eq)

data AssumeTransitionParams = AssumeTransitionParams
  { atpSessionId    :: !Text
  , atpTransitionId :: !Int
  , atpCheckEnabled :: !Bool
  , atpTimeoutSec   :: !(Maybe Int)
  } deriving (Show, Eq)

data AssumeTransitionResult = AssumeTransitionResult
  { atrSessionId    :: !Text
  , atrSnapshotId   :: !Int
  , atrTransitionId :: !Int
  , atrStatus       :: !TransitionStatus
  } deriving (Show, Eq)

data NextStateParams = NextStateParams
  { nspSessionId :: !Text
  } deriving (Show, Eq)

data NextStateResult = NextStateResult
  { nsrSessionId :: !Text
  , nsrSnapshotId :: !Int
  , nsrNewStepNo :: !Int
  } deriving (Show, Eq)

data CheckInvariantParams = CheckInvariantParams
  { cipSessionId   :: !Text
  , cipInvariantId :: !Int
  , cipKind        :: !InvariantKind
  , cipTimeoutSec  :: !(Maybe Int)
  } deriving (Show, Eq)

data CheckInvariantResult = CheckInvariantResult
  { cirSessionId :: !Text
  , cirStatus    :: !InvariantStatus
  , cirTrace     :: !(Maybe ItfTrace)
  } deriving (Show, Eq)

data QueryKind
  = QueryTrace
  | QueryState
  | QueryOperator
  deriving (Show, Eq)

data QueryParams = QueryParams
  { qpSessionId :: !Text
  , qpKinds     :: ![QueryKind]
  , qpOperator  :: !(Maybe Text)
  , qpTimeoutSec :: !(Maybe Int)
  } deriving (Show, Eq)

data QueryResult = QueryResult
  { qrSessionId     :: !Text
  , qrTrace         :: !(Maybe ItfTrace)
  , qrState         :: !(Maybe (Map Text Value))
  , qrOperatorValue :: !(Maybe Value)
  } deriving (Show, Eq)

data AssumeStateParams = AssumeStateParams
  { aspSessionId    :: !Text
  , aspCheckEnabled :: !Bool
  , aspTimeoutSec   :: !(Maybe Int)
  , aspEqualities   :: !(Map Text Value)
  } deriving (Show, Eq)

data AssumeStateResult = AssumeStateResult
  { asrSessionId  :: !Text
  , asrSnapshotId :: !Int
  , asrStatus     :: !TransitionStatus
  } deriving (Show, Eq)

data RollbackParams = RollbackParams
  { rpSessionId  :: !Text
  , rpSnapshotId :: !Int
  } deriving (Show, Eq)

data DisposeSpecParams = DisposeSpecParams
  { dspSessionId :: !Text
  } deriving (Show, Eq)

-------------------------------
-- Aeson instances
-------------------------------

instance ToJSON LoadSpecParams where
  toJSON p = object
    [ "sources"    .= lspSources p
    , "init"       .= lspInit p
    , "next"       .= lspNext p
    , "invariants" .= lspInvariants p
    , "exports"    .= lspExports p
    ]

instance FromJSON LoadSpecResult where
  parseJSON = withObject "LoadSpecResult" $ \o -> LoadSpecResult
    <$> o .: "sessionId"
    <*> o .: "snapshotId"
    <*> o .: "specParameters"

instance ToJSON AssumeTransitionParams where
  toJSON p = object
    [ "sessionId"    .= atpSessionId p
    , "transitionId" .= atpTransitionId p
    , "checkEnabled" .= atpCheckEnabled p
    , "timeoutSec"   .= atpTimeoutSec p
    ]

instance FromJSON AssumeTransitionResult where
  parseJSON = withObject "AssumeTransitionResult" $ \o -> AssumeTransitionResult
    <$> o .: "sessionId"
    <*> o .: "snapshotId"
    <*> o .: "transitionId"
    <*> o .: "status"

instance ToJSON NextStateParams where
  toJSON p = object ["sessionId" .= nspSessionId p]

instance FromJSON NextStateResult where
  parseJSON = withObject "NextStateResult" $ \o -> NextStateResult
    <$> o .: "sessionId"
    <*> o .: "snapshotId"
    <*> o .: "newStepNo"

instance ToJSON CheckInvariantParams where
  toJSON p = object
    [ "sessionId"   .= cipSessionId p
    , "invariantId" .= cipInvariantId p
    , "kind"        .= cipKind p
    , "timeoutSec"  .= cipTimeoutSec p
    ]

instance FromJSON CheckInvariantResult where
  parseJSON = withObject "CheckInvariantResult" $ \o -> CheckInvariantResult
    <$> o .: "sessionId"
    <*> o .: "invariantStatus"
    <*> o .: "trace"

instance ToJSON QueryKind where
  toJSON QueryTrace    = A.String (T.pack "TRACE")
  toJSON QueryState    = A.String (T.pack "STATE")
  toJSON QueryOperator = A.String (T.pack "OPERATOR")

instance ToJSON QueryParams where
  toJSON p = object
    [ "sessionId" .= qpSessionId p
    , "kinds"     .= qpKinds p
    , "operator"  .= qpOperator p
    , "timeoutSec" .= qpTimeoutSec p
    ]

instance FromJSON QueryResult where
  parseJSON = withObject "QueryResult" $ \o -> QueryResult
    <$> o .: "sessionId"
    <*> o .: "trace"
    <*> o .: "state"
    <*> o .: "operatorValue"

instance ToJSON AssumeStateParams where
  toJSON p = object
    [ "sessionId"    .= aspSessionId p
    , "checkEnabled" .= aspCheckEnabled p
    , "timeoutSec"   .= aspTimeoutSec p
    , "equalities"   .= aspEqualities p
    ]

instance FromJSON AssumeStateResult where
  parseJSON = withObject "AssumeStateResult" $ \o -> AssumeStateResult
    <$> o .: "sessionId"
    <*> o .: "snapshotId"
    <*> o .: "status"

instance ToJSON RollbackParams where
  toJSON p = object
    [ "sessionId"  .= rpSessionId p
    , "snapshotId" .= rpSnapshotId p
    ]

instance ToJSON DisposeSpecParams where
  toJSON p = object ["sessionId" .= dspSessionId p]

instance FromJSON TransitionStatus where
  parseJSON = withText "TransitionStatus" $ \case
    t | t == "ENABLED"  -> pure TransEnabled
    t | t == "DISABLED" -> pure TransDisabled
    _                    -> pure TransUnknown

instance FromJSON InvariantStatus where
  parseJSON = withText "InvariantStatus" $ \case
    t | t == "SATISFIED" -> pure InvSatisfied
    t | t == "VIOLATED"  -> pure InvViolated
    _                     -> pure InvUnknown

instance ToJSON InvariantKind where
  toJSON StateInvariant  = A.String "STATE"
  toJSON ActionInvariant = A.String "ACTION"

instance FromJSON TransitionRef where
  parseJSON = withObject "TransitionRef" $ \o -> TransitionRef
    <$> o .: "index"
    <*> o .: "labels"

instance FromJSON InvariantRef where
  parseJSON = withObject "InvariantRef" $ \o -> InvariantRef
    <$> o .: "index"
    <*> o .: "labels"

instance FromJSON SpecParams where
  parseJSON = withObject "SpecParams" $ \o -> SpecParams
    <$> o .: "initTransitions"
    <*> o .: "nextTransitions"
    <*> o .: "stateInvariants"
    <*> o .: "actionInvariants"

instance FromJSON HealthResult where
  parseJSON = withObject "HealthResult" $ \o -> HealthResult
    <$> o .: "status"
