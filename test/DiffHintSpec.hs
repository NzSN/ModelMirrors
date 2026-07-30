module DiffHintSpec (spec) where

import Apalache.Types (Value (..))
import qualified Data.Aeson as A
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Engine.Core (diffState, maxDiffDepth, maxDiffHints)
import Engine.Types
  ( DiffHint (..)
  , Path
  , PathSeg (..)
  , StateDiff (..)
  , hintPath
  )
import Protocol.Format.Json ()
import Test.QuickCheck
  ( Gen
  , Property
  , chooseInt
  , conjoin
  , counterexample
  , elements
  , forAll
  , once
  , oneof
  , property
  , sized
  , vectorOf
  , (.&&.)
  , (===)
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

spec :: TestTree
spec = testGroup "DiffHintSpec"
  [ testProperty "diffState reflexive" prop_reflexive
  , testProperty "StatesMatch iff states equal" prop_soundComplete
  , testProperty "hint paths witness real differences" prop_hintWitness
  , testProperty "depth and count caps respected" prop_caps
  , testProperty "truncation fires on wide states" prop_truncation
  , testProperty "hints JSON-roundtrip" prop_jsonRoundtrip
  ]

genKey :: Gen Text
genKey = elements (map (T.pack . (:[])) "abcde")

genLeaf :: Gen Value
genLeaf = oneof
  [ VInt . fromIntegral <$> chooseInt (0, 5)
  , VBool <$> elements [True, False]
  , VStr <$> elements [T.pack "x", T.pack "y"]
  , pure VNull
  ]

genValue :: Gen Value
genValue = sized $ \n -> go (min 4 n)
  where
    go 0 = genLeaf
    go d = oneof
      [ genLeaf
      , VSet <$> (nub <$> smallList d)
      , VSeq <$> smallList d
      , VTuple <$> smallList d
      , VRecord <$> smallRecord d
      , VMap <$> smallRecord d
      , VVariant <$> genKey <*> go (d - 1)
      ]
    smallList d = do
      k <- chooseInt (0, 4)
      vectorOf k (go (d - 1))
    smallRecord d = do
      k <- chooseInt (0, 4)
      ks <- vectorOf k genKey
      Map.fromList <$> mapM (\key -> (,) key <$> go (d - 1)) ks

genState :: Gen (Map Text Value)
genState = do
  k <- chooseInt (0, 5)
  ks <- vectorOf k genKey
  Map.fromList <$> mapM (\key -> (,) key <$> genValue) ks

lookupIn :: Map Text Value -> Path -> Maybe Value
lookupIn m p = lookupPath p (VRecord m)

lookupPath :: Path -> Value -> Maybe Value
lookupPath [] v = Just v
lookupPath (seg : rest) v = case (seg, v) of
  (Field f, VRecord m) -> Map.lookup f m >>= lookupPath rest
  (Field f, VMap m)    -> Map.lookup f m >>= lookupPath rest
  (Field t, VVariant t' inner)
    | t == t' -> lookupPath rest inner
  (Index i, VSeq xs)   -> at i xs
  (Index i, VTuple xs) -> at i xs
  _ -> Nothing
  where
    at i xs
      | i >= 0 && i < length xs = lookupPath rest (xs !! i)
      | otherwise = Nothing

prop_reflexive :: Property
prop_reflexive = forAll genState $ \s -> diffState s s === StatesMatch

prop_soundComplete :: Property
prop_soundComplete = forAll genState $ \e -> forAll genState $ \a ->
  case diffState e a of
    StatesMatch -> e === a
    StateMismatch e' a' hints -> conjoin
      [ e' === e
      , a' === a
      , property (e /= a)
      , counterexample "empty hints" (not (null hints))
      ]

prop_hintWitness :: Property
prop_hintWitness = forAll genState $ \e -> forAll genState $ \a ->
  case diffState e a of
    StatesMatch -> property True
    StateMismatch _ _ hints -> conjoin (map (checkHint e a) hints)

checkHint :: Map Text Value -> Map Text Value -> DiffHint -> Property
checkHint e a h = counterexample ("hint: " ++ show h) $ case h of
  HValueMismatch p ev av -> conjoin
    [ lookupIn e p === Just ev
    , lookupIn a p === Just av
    , property (ev /= av)
    ]
  HTypeMismatch p ev av ->
    lookupIn e p === Just ev .&&. lookupIn a p === Just av
  HMissing p ev -> case (lookupIn e p, lookupIn a p) of
    (Just ev', Nothing) -> ev' === ev
    (foundE, foundA) ->
      counterexample
        ("expected " ++ show foundE ++ " / actual " ++ show foundA ++ " at " ++ show p)
        (property False)
  HExtra p av -> case (lookupIn a p, lookupIn e p) of
    (Just av', Nothing) -> av' === av
    (foundA, foundE) ->
      counterexample
        ("actual " ++ show foundA ++ " / expected " ++ show foundE ++ " at " ++ show p)
        (property False)
  HMissingElem p ev -> case (lookupIn e p, lookupIn a p) of
    (Just (VSet xs), Just (VSet ys)) ->
      property (ev `elem` xs && ev `notElem` ys)
    (foundE, foundA) ->
      counterexample
        ("expected " ++ show foundE ++ " / actual " ++ show foundA ++ " at " ++ show p)
        (property False)
  HExtraElem p av -> case (lookupIn a p, lookupIn e p) of
    (Just (VSet ys), Just (VSet xs)) ->
      property (av `elem` ys && av `notElem` xs)
    (foundA, foundE) ->
      counterexample
        ("actual " ++ show foundA ++ " / expected " ++ show foundE ++ " at " ++ show p)
        (property False)
  HTruncated _ -> property True

prop_caps :: Property
prop_caps = forAll genState $ \e -> forAll genState $ \a ->
  case diffState e a of
    StatesMatch -> property True
    StateMismatch _ _ hints -> conjoin
      [ counterexample "too many hints" (property (length hints <= maxDiffHints + 1))
      , conjoin
          [ counterexample ("path too deep: " ++ show (hintPath h))
              (property (length (hintPath h) <= maxDiffDepth))
          | h <- hints
          ]
      , case reverse hints of
          (HTruncated _ : rest) ->
            counterexample "truncation not last/unique"
              (property (all (not . isTruncated) rest))
          _ -> property (all (not . isTruncated) hints)
      ]

isTruncated :: DiffHint -> Bool
isTruncated (HTruncated _) = True
isTruncated _              = False

prop_truncation :: Property
prop_truncation = once $
  let big v = Map.fromList [ (T.pack ("k" ++ show i), VInt v) | i <- [(0 :: Int) .. 99] ]
  in case diffState (big 0) (big 1) of
       StateMismatch _ _ hints -> conjoin
         [ length hints === maxDiffHints + 1
         , case reverse hints of
             (HTruncated _ : _) -> property True
             _ -> counterexample "no truncation marker" (property False)
         ]
       StatesMatch -> counterexample "expected mismatch" (property False)

prop_jsonRoundtrip :: Property
prop_jsonRoundtrip = forAll genState $ \e -> forAll genState $ \a ->
  case diffState e a of
    StatesMatch -> property True
    StateMismatch _ _ hints -> conjoin
      [ counterexample (show h) ((A.decode (A.encode h) :: Maybe DiffHint) === Just h)
      | h <- hints
      ]
