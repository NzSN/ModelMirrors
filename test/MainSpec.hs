module MainSpec (spec) where

import Data.ByteString.Char8 qualified as B8
import Data.List (isInfixOf, isSuffixOf)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.Process (readProcess, readProcessWithExitCode)

spec :: IO ()
spec = do
  putStrLn "=== MainSpec ==="
  bin <- findMirrorBinary
  testEndToEnd bin

findMirrorBinary :: IO FilePath
findMirrorBinary = do
  raw <- lines <$> readProcess "find"
    [ "dist-newstyle/build"
    , "-name", "ModelMirros"
    , "-type", "f"
    , "-executable"
    ] ""
  let candidates = filter
        (\p -> "/x/ModelMirros/build/ModelMirros/ModelMirros" `isSuffixOf` p)
        raw
  case candidates of
    (p : _) -> do
      exists <- doesFileExist p
      if exists then pure p
      else error $ "binary listed by find but not accessible: " ++ p
    _ -> error $ "ModelMirros binary not found. Found: " ++ show raw

testEndToEnd :: FilePath -> IO ()
testEndToEnd bin = do
  putStrLn "[1] DeterministicCounter end-to-end protocol ..."
  let
    input = B8.pack $ unlines $ registerLine : stateLines

    registerLine =
      "{\"proto_step\":\"register\",\"specPath\":\"test/specs/DeterministicCounter.tla\",\"traceConfig\":{\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"numTraces\":1}}"

    stateLines = concat $ replicate 2
      [ mkReport 0 "init" 0
      , mkReport 1 "inc"  1
      , mkReport 2 "inc"  2
      , mkReport 3 "inc"  3
      , mkReport 4 "inc"  4
      , mkReport 5 "inc"  5
      ]

    mkReport :: Int -> String -> Int -> String
    mkReport c a s = concat
      [ "{\"proto_step\":\"report_state\",\"state\":{"
      , "\"count\":{\"#bigint\":\"", show c, "\"}"
      , ",\"action_taken\":\"", a, "\""
      , ",\"step_count\":{\"#bigint\":\"", show s, "\"}"
      , "}}"
      ]

  putStrLn ""
  putStrLn "  --- mirror stdout ---"

  (exitCode, stdout, stderr) <- readProcessWithExitCode bin [] (B8.unpack input)

  case exitCode of
    ExitFailure n -> do
      putStrLn $ "  FAIL: mirror exited " ++ show n
      putStrLn $ "  stdout: " ++ stdout
      putStrLn $ "  stderr: " ++ stderr
      exitFailure
    ExitSuccess -> pure ()

  let outputLines = lines stdout
  mapM_ (putStrLn . ("  " ++)) outputLines

  putStrLn ""
  putStrLn "  --- protocol trace ---"

  let annotated = zipWith annotate [1 :: Int ..] outputLines
  mapM_ putStrLn annotated

  putStrLn ""
  checkProtocol outputLines

checkProtocol :: [String] -> IO ()
checkProtocol outputLines = do
  let
    -- Per 6-step trace: initial_state + 5x(step_ok, next_step) + final step_ok
    traceMsgs =
      [ "initial_state"
      , "step_ok", "next_step"
      , "step_ok", "next_step"
      , "step_ok", "next_step"
      , "step_ok", "next_step"
      , "step_ok", "next_step"
      , "step_ok"
      ]
    expected = ["spec_validated"] ++ traceMsgs ++ traceMsgs ++ ["all_steps_done"]

  if length outputLines /= length expected
    then do
      putStrLn $ "FAIL: expected " ++ show (length expected)
        ++ " messages, got " ++ show (length outputLines)
      putStrLn "Output:"
      mapM_ (\l -> putStrLn $ "  " ++ take 100 l) outputLines
      exitFailure
    else pure ()

  sequence_ $ zipWith (checkMsg outputLines) [1 :: Int ..] expected
  putStrLn "  PASS: all 26 protocol messages in correct order"

checkMsg :: [String] -> Int -> String -> IO ()
checkMsg ls n step = do
  let line = ls !! (n - 1)
      needle = "\"proto_step\":\"" ++ step ++ "\""
  if needle `isInfixOf` line
    then pure ()
    else do
      putStrLn $ "FAIL at msg " ++ show n
        ++ ": expected proto_step=" ++ show step
      putStrLn $ "  got: " ++ take 120 line
      exitFailure

annotate :: Int -> String -> String
annotate n line
  | "spec_validated"  `isInfixOf` line = "  [" ++ show n ++ "] <- spec_validated"
  | "all_steps_done"  `isInfixOf` line = "  [" ++ show n ++ "] <- all_steps_done"
  | "protocol_error"  `isInfixOf` line = "  [" ++ show n ++ "] <- protocol_error"
  | "initial_state"   `isInfixOf` line = "  [" ++ show n ++ "] <- initial_state"
  | "next_step"       `isInfixOf` line = "  [" ++ show n ++ "] <- next_step"
  | "step_ok"         `isInfixOf` line = "  [" ++ show n ++ "] <- step_ok"
  | "step_mismatch"   `isInfixOf` line = "  [" ++ show n ++ "] <- step_mismatch"
  | otherwise                          = "  [" ++ show n ++ "] <- " ++ take 70 line
