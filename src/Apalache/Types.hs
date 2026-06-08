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
  , invariant     :: !Text
  , lengthBound   :: !Int
  , paramVarNames :: !Text
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

instance ToJSON ApalacheConfig where
  toJSON c = object
    [ fromString "specPath" .= specPath c
    , fromString "initPredicate" .= initPredicate c
    , fromString "nextPredicate" .= nextPredicate c
    , fromString "constInit" .= constInit c
    , fromString "invariant" .= invariant c
    , fromString "lengthBound" .= lengthBound c
    , fromString "paramVars" .= paramVarNames c
    ]

instance FromJSON ApalacheConfig where
  parseJSON = withObject "ApalacheConfig" $ \o ->
    ApalacheConfig
      <$> o .: fromString "specPath"
      <*> o .:? fromString "initPredicate" .!= Nothing
      <*> o .:? fromString "nextPredicate" .!= Nothing
      <*> o .:? fromString "constInit" .!= Nothing
      <*> o .:? fromString "invariant" .!= T.empty
      <*> o .:? fromString "lengthBound" .!= 10
      <*> o .:? fromString "paramVars" .!= T.empty

data TraceGenerationConfig = TraceGenerationConfig
  { numTraces   :: !Int
  , view        :: !(Maybe Text)
  } deriving (Show, Eq)

instance ToJSON TraceGenerationConfig where
  toJSON c = object
    [ fromString "numTraces" .= numTraces c
    , fromString "view" .= view c
    ]

instance FromJSON TraceGenerationConfig where
  parseJSON = withObject "TraceGenerationConfig" $ \o ->
    TraceGenerationConfig
      <$> o .:? fromString "numTraces" .!= 1
      <*> o .:? fromString "view" .!= Nothing

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
  , traceParams :: !(Map Text Value)
  , traceStates :: ![TraceState]
  } deriving (Show, Eq)

applyParamVars :: [Text] -> ItfTrace -> ItfTrace
applyParamVars pvs t = t
  { paramVars = pvs ++ paramVars t
  , traceStates = map (resplit pvs (traceVars t)) (traceStates t)
  }
  where
    resplit pvs' vars s = s
      { actionTake = actionTake s
      , parameters = Map.filterWithKey (\k _ -> k `elem` pvs')
        (Map.union (parameters s) (stateVars s))
      , stateVars  = Map.filterWithKey (\k _ -> k /= T.pack "action_taken" && k `notElem` pvs' && k `elem` vars)
        (Map.union (parameters s) (stateVars s))
      }

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
    cns    <- o .:? fromString "params" .!= ([] :: [Text])
    rawStates <- o .: fromString "states"
    let split m = TraceState
          { actionTake = case Map.lookup (T.pack "action_taken") m of
              Just (VStr a) -> a
              _             -> T.empty
          , parameters = Map.filterWithKey (\k _ -> k `elem` pvs) m
          , stateVars  = Map.filterWithKey (\k _ -> k `elem` vars && k /= T.pack "action_taken" && k `notElem` pvs) m
          }
        constants = case rawStates of
          (m : _) -> Map.filterWithKey (\k _ -> k `elem` cns) m
          [] -> Map.empty
    pure $ ItfTrace vars pvs constants (map split rawStates)

instance ToJSON ItfTrace where
  toJSON t = object
    [ fromString "vars" .= traceVars t
    , fromString "param_vars" .= paramVars t
    , fromString "params" .= Map.keys (traceParams t)
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

    | Just (A.Array arr) <- KM.lookup (fromString "#map") o
    = let parseEntry v = case v of
            A.Array pairArr -> case F.toList pairArr of
              [k, jsonV] -> do
                kVal <- A.parseJSON k
                vVal <- A.parseJSON jsonV
                pure (valueToText kVal, vVal)
              _ -> fail "Expected [key, value] pair in #map entry"
            _ -> fail "Expected array in #map entry"
          valueToText (VInt i) = T.pack (show i)
          valueToText (VStr s) = s
          valueToText v        = T.pack (show v)
      in VRecord . Map.fromList <$> mapM parseEntry (F.toList arr)

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
