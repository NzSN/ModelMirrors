module Apalache.Command
  ( validateSpec
  , generateTraces
  , generateTracesIn
  , generateTraceFiles
  , generateTraceFilesIn
  , apalacheBin
  ) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , ValidateResult (..)
  , TraceGenerationResult (..)
  , ApalacheError (..)
  , applyParamVars
  )
import Apalache.Trace (findTraceFiles, findTraces)

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
generateTraces = generateTracesIn Nothing

-- | Like 'generateTraces', but with an explicit @--run-dir@ so
-- concurrent sessions never share apalache output directories.
generateTracesIn :: Maybe FilePath -> ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError TraceGenerationResult)
generateTracesIn runDir cfg tc = do
  bin <- apalacheBin
  (exit, out, err) <- readProcessWithExitCode bin (traceArgs runDir cfg tc) ""
  case exit of
    ExitFailure 255 ->
      pure $ Left $ ApalacheError (T.pack (out ++ err))
    _ -> do
      case parseOutputDir (out ++ err) of
        Nothing ->
          pure $ Left $ ApalacheError (T.pack "Could not determine output directory from Apalache output")
        Just outDir -> do
          traces <- findTraces outDir
          let pvs = filter (not . T.null) [paramVarNames cfg]
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

generateTraceFiles :: ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError (FilePath, [FilePath]))
generateTraceFiles = generateTraceFilesIn Nothing

-- | Like 'generateTraceFiles', but with an explicit @--run-dir@ so
-- concurrent sessions never share apalache output directories.
generateTraceFilesIn :: Maybe FilePath -> ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError (FilePath, [FilePath]))
generateTraceFilesIn runDir cfg tc = do
  bin <- apalacheBin
  (exit, out, err) <- readProcessWithExitCode bin (traceArgs runDir cfg tc) ""
  case exit of
    ExitFailure 255 ->
      pure $ Left $ ApalacheError (T.pack (out ++ err))
    _ -> do
      case parseOutputDir (out ++ err) of
        Nothing ->
          pure $ Left $ ApalacheError (T.pack "Could not determine output directory from Apalache output")
        Just outDir -> do
          paths <- findTraceFiles outDir
          pure $ Right (outDir, paths)

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
    , [specPath cfg]
    ]

traceArgs :: Maybe FilePath -> ApalacheConfig -> TraceGenerationConfig -> [String]
traceArgs runDir cfg tc =
  concat
    [ ["check"]
    , ["--inv=" ++ T.unpack (invariant cfg)]
    , ["--length=" ++ show (lengthBound cfg)]
    , ["--max-error=" ++ show (numTraces tc)]
    , ["--output-traces"]
    , maybe [] (\d -> ["--run-dir=" ++ d]) runDir
    , optionalArg "--init=" (initPredicate cfg)
    , optionalArg "--next=" (nextPredicate cfg)
    , optionalArg "--cinit=" (constInit cfg)
    , optionalArg "--view=" (view tc)
    , [specPath cfg]
    ]

optionalArg :: String -> Maybe T.Text -> [String]
optionalArg prefix = \case
  Nothing -> []
  Just v  -> [prefix ++ T.unpack v]
