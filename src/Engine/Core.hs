module Engine.Core where

import Apalache.Types (ItfTrace (..), TraceState (..), Value (..))
import Engine.Types (Step (..), StateDiff (..), VarDiff (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

traceSteps :: ItfTrace -> [Step]
traceSteps trace = zipWith toStep [0..] (traceStates trace)
  where
    toStep i s = Step i (actionTake s) (parameters s)
      (Map.insert (T.pack "action_taken") (VStr (actionTake s))
      $ stateVars s)

diffState :: Map Text Value -> Map Text Value -> StateDiff
diffState expected actual =
  let expected' = Map.filterWithKey (\k _ -> not (isMetaKey k)) expected
      actual'   = Map.filterWithKey (\k _ -> not (isMetaKey k)) actual
      allKeys = Map.keysSet expected' <> Map.keysSet actual'
      diffs = foldr checkKey [] allKeys
        where
          checkKey k acc =
            case (Map.lookup k expected', Map.lookup k actual') of
              (Just ev, Just av) | ev == av  -> acc
              (Just ev, Just av)             -> ValueMismatch k ev av : acc
              (Just ev, Nothing)             -> MissingVar k ev : acc
              (Nothing, Just av)             -> ExtraVar k av : acc
              (Nothing, Nothing)             -> acc
  in case diffs of
       [] -> StatesMatch
       _  -> StateMismatch expected' actual' diffs

isMetaKey :: Text -> Bool
isMetaKey k = (T.length k > 0 && T.head k == '#') ||
              k == T.pack "action_taken" ||
              k == T.pack "parameters"
