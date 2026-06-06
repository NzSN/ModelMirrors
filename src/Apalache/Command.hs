module Apalache.Command
  ( validateSpec
  , generateTraces
  ) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , ValidateResult (..)
  , TraceGenerationResult (..)
  , ApalacheError (..)
  , applyParamVars
  )
import Apalache.Trace (findTraces)

import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

apalacheBin :: IO FilePath
apalacheBin = do
  mEnv <- lookupEnv "APALACHE_MC"
  case mEnv of
    Just path -> pure path
    Nothing -> do
      mRf <- lookupEnv "RUNFILES_DIR"
      case mRf of
        Just rf -> do
          let runfilePath = rf </> "+apalache_mc_repository+apalache_mc" </> "apalache-mc"
          exists <- doesFileExist runfilePath
          pure $ if exists then runfilePath else "apalache-mc"
        Nothing -> pure "apalache-mc"

validateSpec :: ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec cfg bound = do
  bin <- apalacheBin
  (tcExit, tcOut, tcErr) <- readProcessWithExitCode bin (tcArgs cfg) ""
  case tcExit of
    ExitFailure _ ->
      pure $ Right $ SpecInvalid (T.pack (tcOut ++ tcErr))
    ExitSuccess -> do
      (cExit, cOut, cErr) <- readProcessWithExitCode bin (checkArgs cfg bound) ""
      case cExit of
        ExitSuccess -> pure $ Right SpecValid
        ExitFailure _ ->
          pure $ Right $ SpecInvalid (T.pack (cOut ++ cErr))

generateTraces :: ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError TraceGenerationResult)
generateTraces cfg tc = do
  bin <- apalacheBin
  (exit, out, err) <- readProcessWithExitCode bin (traceArgs cfg tc) ""
  case exit of
    ExitFailure 255 ->
      pure $ Left $ ApalacheError (T.pack (out ++ err))
    _ -> do
      case parseOutputDir (out ++ err) of
        Nothing ->
          pure $ Left $ ApalacheError (T.pack "Could not determine output directory from Apalache output")
        Just outDir -> do
          traces <- findTraces outDir
          let pvs = filter (not . T.null) [paramVarNames tc]
          let traces' = map (applyParamVars pvs) traces
          case traces' of
            [] -> pure $ Left $ ApalacheError (T.pack "No ITF trace files found in output directory")
            _  -> pure $ Right $ TracesGenerated traces'

parseOutputDir :: String -> Maybe FilePath
parseOutputDir = go . lines
  where
    go [] = Nothing
    go (l : ls) = case break (== ':') l of
      ("Output directory", ':' : ' ' : rest) -> Just rest
      _ -> go ls

tcArgs :: ApalacheConfig -> [String]
tcArgs cfg =
  "typecheck" : [specPath cfg]

checkArgs :: ApalacheConfig -> Int -> [String]
checkArgs cfg bound =
  concat
    [ ["check"]
    , ["--length=" ++ show bound]
    , optionalArg "--init=" (initPredicate cfg)
    , optionalArg "--next=" (nextPredicate cfg)
    , optionalArg "--cinit=" (constInit cfg)
    , optionalArg "--view=" (view cfg)
    , [specPath cfg]
    ]

traceArgs :: ApalacheConfig -> TraceGenerationConfig -> [String]
traceArgs cfg tc =
  concat
    [ ["check"]
    , ["--inv=" ++ T.unpack (invariant tc)]
    , ["--length=" ++ show (lengthBound tc)]
    , ["--max-error=" ++ show (numTraces tc)]
    , ["--output-traces"]
    , optionalArg "--init=" (initPredicate cfg)
    , optionalArg "--next=" (nextPredicate cfg)
    , optionalArg "--cinit=" (constInit cfg)
    , optionalArg "--view=" (view cfg)
    , [specPath cfg]
    ]

optionalArg :: String -> Maybe T.Text -> [String]
optionalArg prefix = \case
  Nothing -> []
  Just v  -> [prefix ++ T.unpack v]
