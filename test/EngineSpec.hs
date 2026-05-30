module EngineSpec (spec) where

import Apalache.Types (ItfTrace (..), Value (..))
import Engine.Core (traceSteps, diffState)
import Engine.Replay (EngineM (..), StateDriver (..))
import Engine.Types (Step (..), StepCommand (..), StateDiff (..), VarDiff (..))

import Data.Functor.Identity (runIdentity)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure)

spec :: IO ()
spec = do
  putStrLn "=== EngineSpec ==="
  testTraceStepsEmpty
  testTraceStepsOne
  testTraceStepsTwo
  testDiffEmptyMaps
  testDiffIdentical
  testDiffValueMismatch
  testDiffMissingVar
  testDiffExtraVar
  testDiffMixed
  testReplayEmpty
  testReplayAllMatch
  testReplayFirstMismatch
  testReplaySecondMismatch

----------------------------------------------------------------------
-- traceSteps tests

testTraceStepsEmpty :: IO ()
testTraceStepsEmpty = do
  putStrLn "[1] traceSteps empty trace ..."
  let trace = ItfTrace [] []
  let steps = traceSteps trace
  if null steps
    then putStrLn "  PASS: empty trace yields empty list"
    else do
      putStrLn "FAIL: expected empty list"
      exitFailure

testTraceStepsOne :: IO ()
testTraceStepsOne = do
  putStrLn "[2] traceSteps single state ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let trace = ItfTrace [T.pack "x"] [s0]
  let steps = traceSteps trace
  case steps of
    [Step 0 m]
      | m == s0 -> putStrLn "  PASS: single state produces Step 0"
      | otherwise -> do
          putStrLn "FAIL: state data incorrect"
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected one step, got " ++ show (length steps)
      exitFailure

testTraceStepsTwo :: IO ()
testTraceStepsTwo = do
  putStrLn "[3] traceSteps two states ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let steps = traceSteps trace
  case steps of
    [Step 0 a, Step 1 b]
      | a == s0 && b == s1 -> putStrLn "  PASS: two states produce Steps 0 and 1"
      | otherwise -> do
          putStrLn "FAIL: state data incorrect"
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected two steps, got " ++ show (length steps)
      exitFailure

----------------------------------------------------------------------
-- diffState tests

testDiffEmptyMaps :: IO ()
testDiffEmptyMaps = do
  putStrLn "[4] diffState empty maps ..."
  let result = diffState Map.empty (Map.empty :: Map Text Value)
  case result of
    StatesMatch -> putStrLn "  PASS: empty maps match"
    _ -> do
      putStrLn "FAIL: expected StatesMatch"
      exitFailure

testDiffIdentical :: IO ()
testDiffIdentical = do
  putStrLn "[5] diffState identical maps ..."
  let m = Map.fromList
        [ (T.pack "a", VInt 1)
        , (T.pack "b", VBool True)
        ]
  let result = diffState m m
  case result of
    StatesMatch -> putStrLn "  PASS: identical maps match"
    _ -> do
      putStrLn "FAIL: expected StatesMatch"
      exitFailure

testDiffValueMismatch :: IO ()
testDiffValueMismatch = do
  putStrLn "[6] diffState value mismatch ..."
  let expected = Map.singleton (T.pack "x") (VInt 1)
  let actual   = Map.singleton (T.pack "x") (VInt 2)
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [ValueMismatch k (VInt 1) (VInt 2)]
      | k == T.pack "x" -> putStrLn "  PASS: value mismatch detected"
    _ -> do
      putStrLn $ "FAIL: expected ValueMismatch, got " ++ show result
      exitFailure

testDiffMissingVar :: IO ()
testDiffMissingVar = do
  putStrLn "[7] diffState missing variable ..."
  let expected = Map.singleton (T.pack "x") (VInt 1)
  let actual   = Map.empty
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [MissingVar k (VInt 1)]
      | k == T.pack "x" -> putStrLn "  PASS: missing var detected"
    _ -> do
      putStrLn $ "FAIL: expected MissingVar, got " ++ show result
      exitFailure

testDiffExtraVar :: IO ()
testDiffExtraVar = do
  putStrLn "[8] diffState extra variable ..."
  let expected = Map.empty
  let actual   = Map.singleton (T.pack "y") (VStr (T.pack "bonus"))
  let result = diffState expected actual
  case result of
    StateMismatch _ _ [ExtraVar k (VStr s)]
      | k == T.pack "y" && s == T.pack "bonus" -> putStrLn "  PASS: extra var detected"
    _ -> do
      putStrLn $ "FAIL: expected ExtraVar, got " ++ show result
      exitFailure

testDiffMixed :: IO ()
testDiffMixed = do
  putStrLn "[9] diffState mixed differences ..."
  let expected = Map.fromList
        [ (T.pack "a", VInt 1)
        , (T.pack "b", VBool True)
        ]
  let actual = Map.fromList
        [ (T.pack "a", VInt 99)
        , (T.pack "c", VStr (T.pack "hello"))
        ]
  let result = diffState expected actual
  case result of
    StateMismatch _ _ diffs
      | length diffs == 3 -> putStrLn "  PASS: all three diffs found"
      | otherwise -> do
          putStrLn $ "FAIL: expected 3 diffs, got " ++ show (length diffs)
          exitFailure
    _ -> do
      putStrLn $ "FAIL: expected StateMismatch, got " ++ show result
      exitFailure

----------------------------------------------------------------------
-- replayTrace tests

testReplayEmpty :: IO ()
testReplayEmpty = do
  putStrLn "[10] replayTrace empty trace ..."
  let trace = ItfTrace [] []
  let report = StateDriver (\_ -> pure (Map.empty :: Map Text Value))
  let result = runIdentity (replayTrace trace report)
  if null result
    then putStrLn "  PASS: empty trace yields empty list"
    else do
      putStrLn "FAIL: expected empty list"
      exitFailure

testReplayAllMatch :: IO ()
testReplayAllMatch = do
  putStrLn "[11] replayTrace all match ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report = StateDriver $ \cmd -> pure $ case cmd of
        CmdInitial _ -> s0
        CmdNextStep _ -> s1
  let results = runIdentity (replayTrace trace report)
  case results of
    [StatesMatch, StatesMatch] -> putStrLn "  PASS: both steps match"
    _ -> do
      putStrLn $ "FAIL: expected [StatesMatch, StatesMatch], got " ++ show results
      exitFailure

testReplayFirstMismatch :: IO ()
testReplayFirstMismatch = do
  putStrLn "[12] replayTrace first mismatch ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report = StateDriver (\_ -> pure (Map.singleton (T.pack "x") (VInt 999)))
  let results = runIdentity (replayTrace trace report)
  case results of
    [StateMismatch{}] -> putStrLn "  PASS: stops on first mismatch"
    _ -> do
      putStrLn $ "FAIL: expected [StateMismatch], got " ++ show results
      exitFailure

testReplaySecondMismatch :: IO ()
testReplaySecondMismatch = do
  putStrLn "[13] replayTrace second mismatch ..."
  let s0 = Map.singleton (T.pack "x") (VInt 1)
  let s1 = Map.singleton (T.pack "x") (VInt 2)
  let trace = ItfTrace [T.pack "x"] [s0, s1]
  let report = StateDriver $ \case
        CmdInitial _ -> pure (Map.singleton (T.pack "x") (VInt 1))
        CmdNextStep _ -> pure (Map.singleton (T.pack "x") (VInt 999))
  let results = runIdentity (replayTrace trace report)
  case results of
    [StatesMatch, StateMismatch{}] -> putStrLn "  PASS: matches first, stops on second"
    _ -> do
      putStrLn $ "FAIL: expected [StatesMatch, StateMismatch], got " ++ show results
      exitFailure
