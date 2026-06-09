module MainSpec (spec) where

import Control.Exception (SomeException, try, displayException)
import Data.ByteString.Char8 qualified as B8
import Data.List (isInfixOf, isSuffixOf)
import System.Directory (doesFileExist, doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcess, readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "MainSpec" [testEndToEnd, testCounterEndToEnd]

findMirrorBinary :: IO FilePath
findMirrorBinary = do
  mRunfiles <- lookupEnv "RUNFILES_DIR"
  case mRunfiles of
    Just rf -> do
      let bazelPath = rf </> "_main" </> "app" </> "ModelMirrors"
      exists <- doesFileExist bazelPath
      if exists then pure bazelPath
      else findCabalBinary
    Nothing -> findCabalBinary

findCabalBinary :: IO FilePath
findCabalBinary = do
  exists <- doesDirectoryExist "dist-newstyle/build"
  if not exists
    then error "dist-newstyle/build not found and RUNFILES_DIR not set"
    else do
      raw <- lines <$> readProcess "find"
        [ "dist-newstyle/build"
        , "-name", "ModelMirrors"
        , "-type", "f"
        , "-executable"
        ] ""
      let candidates = filter
            (\p -> "/x/ModelMirrors/build/ModelMirrors/ModelMirrors" `isSuffixOf` p)
            raw
      case candidates of
        (p : _) -> do
          exists' <- doesFileExist p
          if exists' then pure p
          else error $ "binary listed by find but not accessible: " ++ p
        _ -> error $ "ModelMirrors binary not found. Found: " ++ show raw

findMirrorBinaryOrSkip :: IO (Maybe FilePath)
findMirrorBinaryOrSkip = do
  result <- try findMirrorBinary
  case result of
    Left (e :: SomeException) -> do
      putStrLn $ "SKIP: " ++ displayException e
      pure Nothing
    Right p -> pure (Just p)

testEndToEnd :: TestTree
testEndToEnd = testCase "DeterministicCounter end-to-end" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      let
        input = B8.pack $ unlines $ registerLine : stateLines

        registerLine =
          "{\"proto_step\":\"register\",\"apalacheConfig\":{\"specPath\":\"test/specs/DeterministicCounter.tla\",\"initPredicate\":null,\"nextPredicate\":null,\"constInit\":null,\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"paramVars\":\"\"},\"traceConfig\":{\"numTraces\":1,\"view\":null}}"

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

      (exitCode, stdout, _stderr) <- readProcessWithExitCode bin [] (B8.unpack input)

      case exitCode of
        ExitFailure n -> assertFailure $ "mirror exited " ++ show n ++ "\nstdout: " ++ stdout
        ExitSuccess -> pure ()

      let outputLines = lines stdout
      mapM_ (putStrLn . ("  " ++)) outputLines

      putStrLn ""
      putStrLn "  --- protocol trace ---"

      let annotated = zipWith annotate [1 :: Int ..] outputLines
      mapM_ putStrLn annotated

      putStrLn ""

      let
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

      assertBool ("expected " ++ show (length expected) ++ " messages, got " ++ show (length outputLines))
        (length outputLines == length expected)

      let checkMsg ls n step = do
            let line = ls !! (n - 1)
                needle = "\"proto_step\":\"" ++ step ++ "\""
            assertBool ("msg " ++ show n ++ ": expected proto_step=" ++ show step ++ "\n  got: " ++ take 120 line)
              (needle `isInfixOf` line)

      sequence_ $ zipWith (checkMsg outputLines) [1 :: Int ..] expected

testCounterEndToEnd :: TestTree
testCounterEndToEnd = testCase "Counter end-to-end" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      let
        registerLine =
          "{\"proto_step\":\"register\",\"apalacheConfig\":{\"specPath\":\"test/specs/Counter.tla\",\"initPredicate\":null,\"nextPredicate\":null,\"constInit\":\"CInit\",\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"paramVars\":\"parameters\"},\"traceConfig\":{\"numTraces\":1,\"view\":null}}"

        mkReport c a s = concat
          [ "{\"proto_step\":\"report_state\",\"state\":{"
          , "\"count\":{\"#bigint\":\"", show c, "\"}"
          , ",\"action_taken\":\"", a, "\""
          , ",\"step_count\":{\"#bigint\":\"", show s, "\"}"
          , "}}"
          ]

        stateLines = concat $ replicate 2
          [ mkReport (0 :: Int)  "init" (0 :: Int)
          , mkReport (2 :: Int)  "tick" (1 :: Int)
          , mkReport (4 :: Int)  "tick" (2 :: Int)
          , mkReport (6 :: Int)  "tick" (3 :: Int)
          , mkReport (8 :: Int)  "tick" (4 :: Int)
          , mkReport (10 :: Int) "tick" (5 :: Int)
          ]

        input = B8.pack $ unlines $ registerLine : stateLines

      putStrLn ""
      putStrLn "  --- mirror stdout ---"

      (exitCode, stdout, _stderr) <- readProcessWithExitCode bin [] (B8.unpack input)

      case exitCode of
        ExitFailure n -> assertFailure $ "mirror exited " ++ show n ++ "\nstdout: " ++ stdout
        ExitSuccess -> pure ()

      let outputLines = lines stdout
      mapM_ (putStrLn . ("  " ++)) outputLines

      putStrLn ""
      putStrLn "  --- protocol trace ---"

      let annotated = zipWith annotate [1 :: Int ..] outputLines
      mapM_ putStrLn annotated

      putStrLn ""

      let
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

      assertBool ("expected " ++ show (length expected) ++ " messages, got " ++ show (length outputLines))
        (length outputLines == length expected)

      let checkMsg ls n step = do
            let line = ls !! (n - 1)
                needle = "\"proto_step\":\"" ++ step ++ "\""
            assertBool ("msg " ++ show n ++ ": expected proto_step=" ++ show step ++ "\n  got: " ++ take 120 line)
              (needle `isInfixOf` line)

      sequence_ $ zipWith (checkMsg outputLines) [1 :: Int ..] expected

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
