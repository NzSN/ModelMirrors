module Engine.Types where

import Apalache.Types (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T

data Step = Step
  { stepIdx    :: !Int
  , stepAct    :: !Text
  , stepParams :: !(Map Text Value)
  , stepVars   :: !(Map Text Value)
  } deriving (Show, Eq)

data StepCommand
  = CmdInitial !Text !(Map Text Value)
  | CmdNextStep !Text !(Map Text Value)
  deriving (Show, Eq)

data PathSeg = Field !Text | Index !Int
  deriving (Show, Eq)

type Path = [PathSeg]

data DiffHint
  = HValueMismatch !Path !Value !Value
  | HMissing !Path !Value
  | HExtra !Path !Value
  | HMissingElem !Path !Value
  | HExtraElem !Path !Value
  | HTypeMismatch !Path !Value !Value
  | HTruncated !Path
  deriving (Show, Eq)

hintPath :: DiffHint -> Path
hintPath h = case h of
  HValueMismatch p _ _ -> p
  HMissing p _         -> p
  HExtra p _           -> p
  HMissingElem p _     -> p
  HExtraElem p _       -> p
  HTypeMismatch p _ _  -> p
  HTruncated p         -> p

renderPath :: Path -> Text
renderPath [] = T.pack "<state>"
renderPath (seg : segs) = go (segText seg) segs
  where
    go acc [] = acc
    go acc (s : rest) = go (acc <> segText s) rest
    segText (Field f) = T.pack "." <> f
    segText (Index i) = T.pack "[" <> T.pack (show i) <> T.pack "]"

renderValue :: Value -> Text
renderValue = T.pack . show

renderDiffHint :: DiffHint -> Text
renderDiffHint h = case h of
  HValueMismatch p e a ->
    T.pack "at " <> at p <> T.pack ": expected " <> renderValue e
      <> T.pack ", got " <> renderValue a
  HMissing p e ->
    T.pack "at " <> at p <> T.pack ": missing " <> renderValue e
  HExtra p a ->
    T.pack "at " <> at p <> T.pack ": unexpected " <> renderValue a
  HMissingElem p e ->
    T.pack "at " <> at p <> T.pack ": missing element " <> renderValue e
  HExtraElem p a ->
    T.pack "at " <> at p <> T.pack ": unexpected element " <> renderValue a
  HTypeMismatch p e a ->
    T.pack "at " <> at p <> T.pack ": expected a value of shape " <> renderValue e
      <> T.pack ", got " <> renderValue a
  HTruncated p ->
    T.pack "at " <> at p <> T.pack ": further differences truncated"
  where
    at p = case p of
      [] -> T.pack "<state>"
      _  -> T.drop 1 (renderPath p)

renderDiffHints :: [DiffHint] -> Text
renderDiffHints [] = T.pack "states differ"
renderDiffHints hs = T.intercalate (T.pack "; ") (map renderDiffHint hs)

data StateDiff
  = StatesMatch
  | StateMismatch
      !(Map Text Value)
      !(Map Text Value)
      ![DiffHint]
  deriving (Show, Eq)
