module Engine.Core where

import Apalache.Types (ItfTrace (..), TraceState (..), Value (..))
import Engine.Types
  ( DiffHint (..)
  , PathSeg (..)
  , StateDiff (..)
  , Step (..)
  , hintPath
  )
import Data.List ((\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

maxDiffDepth :: Int
maxDiffDepth = 8

maxDiffHints :: Int
maxDiffHints = 50

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
      allKeys = Map.keys (Map.union expected' actual')
      hints = capHints (concatMap checkKey allKeys)
        where
          checkKey k =
            case (Map.lookup k expected', Map.lookup k actual') of
              (Just ev, Just av) -> diffValue [Field k] ev av
              (Just ev, Nothing) -> [HMissing [Field k] ev]
              (Nothing, Just av) -> [HExtra [Field k] av]
              (Nothing, Nothing) -> []
  in case hints of
       [] -> StatesMatch
       _  -> StateMismatch expected' actual' hints

diffValue :: [PathSeg] -> Value -> Value -> [DiffHint]
diffValue path expected actual
  | expected == actual = []
  | length path >= maxDiffDepth = [HValueMismatch path expected actual]
  | otherwise = case (expected, actual) of
      (VRecord em, VRecord am) -> diffFields path em am
      (VMap em, VMap am)       -> diffFields path em am
      (VSeq es, VSeq as)       -> diffElems path es as
      (VTuple es, VTuple as)   -> diffElems path es as
      (VVariant t1 v1, VVariant t2 v2)
        | t1 == t2  -> diffValue (path ++ [Field t1]) v1 v2
        | otherwise -> [HValueMismatch path expected actual]
      (VSet es, VSet as)       -> diffSet path es as
      _
        | sameShape expected actual -> [HValueMismatch path expected actual]
        | otherwise                 -> [HTypeMismatch path expected actual]

diffFields :: [PathSeg] -> Map Text Value -> Map Text Value -> [DiffHint]
diffFields path expected actual = concatMap check (Map.keys (Map.union expected actual))
  where
    check k = case (Map.lookup k expected, Map.lookup k actual) of
      (Just ev, Just av) -> diffValue (path ++ [Field k]) ev av
      (Just ev, Nothing) -> [HMissing (path ++ [Field k]) ev]
      (Nothing, Just av) -> [HExtra (path ++ [Field k]) av]
      (Nothing, Nothing) -> []

diffElems :: [PathSeg] -> [Value] -> [Value] -> [DiffHint]
diffElems path expected actual = common ++ missing ++ extra
  where
    common = concat
      [ diffValue (path ++ [Index i]) e a
      | (i, e, a) <- zip3 [0..] expected actual
      ]
    missing =
      [ HMissing (path ++ [Index i]) e
      | (i, e) <- zip [length actual ..] (drop (length actual) expected)
      ]
    extra =
      [ HExtra (path ++ [Index i]) a
      | (i, a) <- zip [length expected ..] (drop (length expected) actual)
      ]

diffSet :: [PathSeg] -> [Value] -> [Value] -> [DiffHint]
diffSet path expected actual =
     [ HMissing path e | e <- expected \\ actual ]
  ++ [ HExtra path a   | a <- actual \\ expected ]

sameShape :: Value -> Value -> Bool
sameShape a b = case (a, b) of
  (VInt _, VInt _)                 -> True
  (VBool _, VBool _)               -> True
  (VStr _, VStr _)                 -> True
  (VSet _, VSet _)                 -> True
  (VSeq _, VSeq _)                 -> True
  (VTuple _, VTuple _)             -> True
  (VRecord _, VRecord _)           -> True
  (VMap _, VMap _)                 -> True
  (VVariant _ _, VVariant _ _)     -> True
  (VUnserializable _, VUnserializable _) -> True
  (VNull, VNull)                   -> True
  _                                -> False

capHints :: [DiffHint] -> [DiffHint]
capHints hints =
  let (kept, rest) = splitAt maxDiffHints hints
  in case rest of
       []      -> kept
       (h : _) -> kept ++ [HTruncated (hintPath h)]

isMetaKey :: Text -> Bool
isMetaKey k = (T.length k > 0 && T.head k == '#') ||
              k == T.pack "action_taken" ||
              k == T.pack "parameters"
