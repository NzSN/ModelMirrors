module Apalache.Types where

import Data.Aeson (FromJSON, ToJSON, withObject, (.:), (.:?), (.=), (.!=), object)
import qualified Data.Aeson as A
import Data.Aeson.Key (fromString, fromText, toText)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Foldable as F
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T

data ApalacheConfig = ApalacheConfig
  { specPath      :: !FilePath
  , initPredicate :: !(Maybe Text)
  , nextPredicate :: !(Maybe Text)
  , constInit     :: !(Maybe Text)
  } deriving (Show, Eq)

data ValidateResult
  = SpecValid
  | SpecInvalid !Text
  deriving (Show, Eq)

instance ToJSON ValidateResult where
  toJSON SpecValid = A.String (T.pack "valid")
  toJSON (SpecInvalid e) = object [fromString "invalid" .= e]

instance FromJSON ValidateResult where
  parseJSON v = case v of
    A.String t | t == T.pack "valid" -> pure SpecValid
    _ -> withObject "ValidateResult" (\o -> SpecInvalid <$> o .: fromString "invalid") v

data TraceGenerationConfig = TraceGenerationConfig
  { invariant   :: !Text
  , lengthBound :: !Int
  , numTraces   :: !Int
  } deriving (Show, Eq)

instance ToJSON TraceGenerationConfig where
  toJSON c = object
    [ fromString "invariant" .= invariant c
    , fromString "lengthBound" .= lengthBound c
    , fromString "numTraces" .= numTraces c
    ]

instance FromJSON TraceGenerationConfig where
  parseJSON = withObject "TraceGenerationConfig" $ \o ->
    TraceGenerationConfig
      <$> o .: fromString "invariant"
      <*> o .: fromString "lengthBound"
      <*> o .: fromString "numTraces"

data TraceGenerationResult
  = TracesGenerated ![ItfTrace]
  | GenerationError !Text
  deriving (Show, Eq)

newtype ApalacheError = ApalacheError { unApalacheError :: Text }
  deriving (Show, Eq)

data TraceState = TraceState
  { actionTake :: !Text
  , parameters :: !(Map Text Value)
  , stateVars  :: !(Map Text Value)
  } deriving (Show, Eq)

data ItfTrace = ItfTrace
  { traceVars   :: ![Text]
  , paramVars   :: ![Text]
  , traceStates :: ![TraceState]
  } deriving (Show, Eq)

data Value
  = VInt    !Integer
  | VBool   !Bool
  | VStr    !Text
  | VSet    ![Value]
  | VTuple  ![Value]
  | VRecord !(Map Text Value)
  | VNull
  deriving (Show, Eq)

instance ToJSON TraceState where
  toJSON ts = A.toJSON
    $ Map.insert (T.pack "action_taken") (VStr (actionTake ts))
    $ Map.union (parameters ts) (stateVars ts)

instance FromJSON ItfTrace where
  parseJSON = withObject "ItfTrace" $ \o -> do
    vars   <- o .: fromString "vars"
    pvs    <- o .:? fromString "param_vars" .!= ([] :: [Text])
    states <- o .: fromString "states"
    let split m = TraceState
          { actionTake = case Map.lookup (T.pack "action_taken") m of
              Just (VStr a) -> a
              _             -> T.empty
          , parameters = Map.filterWithKey (\k _ -> k `elem` pvs) m
          , stateVars  = Map.filterWithKey (\k _ -> k /= T.pack "action_taken" && k `notElem` pvs) m
          }
    pure $ ItfTrace vars pvs (map split states)

instance ToJSON ItfTrace where
  toJSON t = object
    [ fromString "vars" .= traceVars t
    , fromString "param_vars" .= paramVars t
    , fromString "states" .= traceStates t
    ]

instance FromJSON Value where
  parseJSON (A.Object o)
    | Just (A.String n) <- KM.lookup (fromString "#bigint") o
    = case T.unpack n of
        ""  -> pure VNull
        '-' : ds | all (`elem` ['0' .. '9']) ds -> pure $ VInt (read ('-' : ds))
        ds   | all (`elem` ['0' .. '9']) ds -> pure $ VInt (read ds)
        _    -> fail $ "Invalid bigint: " ++ T.unpack n

    | Just (A.Array arr) <- KM.lookup (fromString "#tup") o
    = VTuple <$> mapM A.parseJSON (F.toList arr)

    | otherwise = do
        pairs <- mapM (\(k, v) -> (toText k,) <$> A.parseJSON v) (KM.toList o)
        pure $ VRecord (Map.fromList pairs)

  parseJSON (A.Array arr) =
    VSet <$> mapM A.parseJSON (F.toList arr)

  parseJSON (A.Bool b) =
    pure $ VBool b

  parseJSON (A.String s) =
    pure $ VStr s

  parseJSON n@(A.Number _) =
    VInt <$> A.parseJSON n

  parseJSON A.Null =
    pure VNull

instance ToJSON Value where
  toJSON (VInt i) =
    object [fromString "#bigint" .= T.pack (show i)]
  toJSON (VBool b)   = A.Bool b
  toJSON (VStr s)    = A.String s
  toJSON (VSet vs)   = A.toJSON (map A.toJSON vs)
  toJSON (VTuple vs) = object [fromString "#tup" .= A.toJSON (map A.toJSON vs)]
  toJSON (VRecord m) = object [(fromText k, A.toJSON v) | (k, v) <- Map.toList m]
  toJSON VNull       = A.Null
