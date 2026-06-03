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
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

validateSpec :: ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec cfg bound = do
  (tcExit, tcOut, tcErr) <- readProcessWithExitCode "apalache-mc" (tcArgs cfg) ""
  case tcExit of
    ExitFailure _ ->
      pure $ Right $ SpecInvalid (T.pack (tcOut ++ tcErr))
    ExitSuccess -> do
      (cExit, cOut, cErr) <- readProcessWithExitCode "apalache-mc" (checkArgs cfg bound) ""
      case cExit of
        ExitSuccess -> pure $ Right SpecValid
        ExitFailure _ ->
          pure $ Right $ SpecInvalid (T.pack (cOut ++ cErr))

generateTraces :: ApalacheConfig -> TraceGenerationConfig -> IO (Either ApalacheError TraceGenerationResult)
generateTraces cfg tc = do
  (_exit, out, err) <- readProcessWithExitCode "apalache-mc" (traceArgs cfg tc) ""
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
    , [specPath cfg]
    ]

optionalArg :: String -> Maybe T.Text -> [String]
optionalArg prefix = \case
  Nothing -> []
  Just v  -> [prefix ++ T.unpack v]
