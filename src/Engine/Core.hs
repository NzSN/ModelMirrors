module Engine.Core where

import Apalache.Types (ItfTrace (..), Value)
import Engine.Types (Step (..), StateDiff (..), VarDiff (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

traceSteps :: ItfTrace -> [Step]
traceSteps trace = zipWith (\i m -> Step i m) [0..] (traceStates trace)

diffState :: Map Text Value -> Map Text Value -> StateDiff
diffState expected actual =
  let allKeys = Map.keysSet expected <> Map.keysSet actual
      diffs = foldr checkKey [] allKeys
        where
          checkKey k acc =
            case (Map.lookup k expected, Map.lookup k actual) of
              (Just ev, Just av) | ev == av  -> acc
              (Just ev, Just av)             -> ValueMismatch k ev av : acc
              (Just ev, Nothing)             -> MissingVar k ev : acc
              (Nothing, Just av)             -> ExtraVar k av : acc
              (Nothing, Nothing)             -> acc
  in case diffs of
       [] -> StatesMatch
       _  -> StateMismatch expected actual diffs
