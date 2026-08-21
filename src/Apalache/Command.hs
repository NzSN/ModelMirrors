module Apalache.Command
  ( validateSpec
  , validateSpecIn
  , generateTraces
  , generateTracesIn
  , generateTraceFiles
  , generateTraceFilesIn
  , apalacheBin
  , ApalacheResult (..)
  , spawnApalache
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

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, try)
import qualified Data.Text as T
import Resource (Resource, acquire)
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetContents)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , cwd
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  , terminateProcess
  , waitForProcess
  )

-- Launches @apalache-mc@: honor the @APALACHE_MC@ override if set, otherwise
-- rely on it being on @PATH@. There is no Bazel runfiles fallback; this is a
-- cabal-only project.
apalacheBin :: IO FilePath
apalacheBin = do
  mEnv <- lookupEnv "APALACHE_MC"
  case mEnv of
    Just path -> pure path
    Nothing -> pure "apalache-mc"

validateSpec :: ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec = validateSpecIn Nothing

-- | Like 'validateSpec', but with an explicit @--run-dir@ so concurrent
-- sessions never share apalache output directories.
--
-- Isolation: apalache 0.57 writes @_apalache-out\/<Spec>\/<timestamp>\/@
-- and @tmp\/@ into the process CWD even when @--run-dir@ is given, so
-- passing the flag alone would still litter the mirror process's working
-- directory. When a run dir is supplied, both the typecheck and the check
-- process additionally run with @cwd = runDir@, and a relative 'specPath'
-- is absolutized first (it would no longer resolve once the child's cwd
-- moves). All stray output then lands inside the per-session temp dir.
-- Behavior is unchanged when @runDir@ is 'Nothing'.
--
-- Exit-code classification (verified against apalache 0.57):
--   * 255 (parse\/config\/infrastructure error) -> 'Left'
--     ('RegisterError' tier on the mirror).
--   * typecheck failure (exit 120) or invariant violation (exit 12) ->
--     'Right' ('SpecInvalid' tier). A spec that fails typechecking is a
--     spec-authored defect, like an invariant violation, so it is reported
--     as the client's verdict; 'RegisterError' is reserved for the mirror
--     being unable to run apalache at all (255) or for spec-materialization
--     failures.
--   * both phases exit 0 -> 'Right' 'SpecValid'.
validateSpecIn :: Maybe FilePath -> ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpecIn runDir cfg bound = do
  bin <- apalacheBin
  -- Only when a run dir is given: absolutize specPath up front so both
  -- child processes (whose cwd is the run dir) still find the spec.
  cfg' <- case runDir of
    Just _  -> (\p -> cfg { specPath = p }) <$> makeAbsolute (specPath cfg)
    Nothing -> pure cfg
  (tcExit, tcOut, tcErr) <- runApalache bin (tcArgs runDir cfg')
  case tcExit of
    ExitFailure 255 ->
      pure $ Left $ ApalacheError (T.pack (tcOut ++ tcErr))
    ExitFailure _ ->
      pure $ Right $ SpecInvalid (T.pack (tcOut ++ tcErr))
    ExitSuccess -> do
      (cExit, cOut, cErr) <- runApalache bin (checkArgs runDir cfg' bound)
      case cExit of
        ExitFailure 255 ->
          pure $ Left $ ApalacheError (T.pack (cOut ++ cErr))
        ExitSuccess ->
          pure $ Right SpecValid
        ExitFailure _ ->
          pure $ Right $ SpecInvalid (T.pack (cOut ++ cErr))
  where
    runApalache bin args =
      readCreateProcessWithExitCode ((proc bin args) { cwd = runDir }) ""

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

-- | @typecheck@ argument list. Apalache 0.57 accepts @--run-dir@ on
-- typecheck and still writes @_apalache-out@\/@tmp@ into the CWD, so the
-- caller also pins the child's cwd (see 'validateSpecIn'); passing the flag
-- keeps the typecheck output directory consistent with the check phase.
tcArgs :: Maybe FilePath -> ApalacheConfig -> [String]
tcArgs runDir cfg =
  concat
    [ ["typecheck"]
    , maybe [] (\d -> ["--run-dir=" ++ d]) runDir
    , [specPath cfg]
    ]

checkArgs :: Maybe FilePath -> ApalacheConfig -> Int -> [String]
checkArgs runDir cfg bound =
  concat
    [ ["check"]
    , ["--length=" ++ show bound]
    , maybe [] (\d -> ["--run-dir=" ++ d]) runDir
    , optionalArg "--inv=" (nonEmptyText (invariant cfg))
    , optionalArg "--init=" (initPredicate cfg)
    , optionalArg "--next=" (nextPredicate cfg)
    , optionalArg "--cinit=" (constInit cfg)
    , [specPath cfg]
    ]

-- | @Just t@ when @t@ is non-empty, so @optionalArg@ skips empty invariants.
nonEmptyText :: T.Text -> Maybe T.Text
nonEmptyText t = if T.null t then Nothing else Just t

-- | @check@ argument list for trace generation. @--inv@ is gated on a
-- non-empty invariant exactly like 'checkArgs': an unconditional
-- @--inv=@ with an empty value is an apalache config error (exit 255),
-- which would fail the whole trace path for specs without an invariant.
traceArgs :: Maybe FilePath -> ApalacheConfig -> TraceGenerationConfig -> [String]
traceArgs runDir cfg tc =
  concat
    [ ["check"]
    , optionalArg "--inv=" (nonEmptyText (invariant cfg))
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

-- | The full outcome of a single apalache invocation.
data ApalacheResult = ApalacheResult
  { arExitCode :: !ExitCode
  , arStdOut   :: !String
  , arStdErr   :: !String
  } deriving (Show, Eq)

-- | Run one apalache invocation (the binary resolved by 'apalacheBin') and
-- return its full outcome alongside a 'Resource ProcessHandle'. The handle's
-- cleanup is idempotent 'terminateProcess'+'waitForProcess': terminating an
-- already-exited child is a no-op and 'waitForProcess' returns the recorded
-- exit code immediately, so releasing after completion (or dropping the
-- handle) is safe. This is the wrapper the async job model will use to close
-- the cancellation kill-window; the existing 'validateSpecIn'/'generateTracesIn'/
-- 'generateTraceFilesIn' helpers are unchanged.
spawnApalache :: [String] -> IO (ApalacheResult, Resource ProcessHandle)
spawnApalache args = do
  bin <- apalacheBin
  (_, mOut, mErr, ph) <-
    createProcess (proc bin args)
      { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
  case (mOut, mErr) of
    (Just hOut, Just hErr) -> do
      res <- acquire (T.pack "apalache-process") (pure ph) stopApalacheProcess
      (out, err) <- drainOutputs hOut hErr
      hClose hOut
      hClose hErr
      exitCode <- waitForProcess ph
      pure (ApalacheResult exitCode out err, res)
    _ -> do
      -- Unreachable (we asked for CreatePipe), but be defensive so the
      -- launched process is never left running.
      _ <- try (terminateProcess ph) :: IO (Either SomeException ())
      _ <- try (waitForProcess ph) :: IO (Either SomeException ExitCode)
      ioError (userError "spawnApalache: expected stdout/stderr pipes from createProcess")

-- | Idempotent process stop: 'terminateProcess' then 'waitForProcess', each
-- guarded so cleanup never throws even when the process already exited.
stopApalacheProcess :: ProcessHandle -> IO ()
stopApalacheProcess ph = do
  _ <- try (terminateProcess ph) :: IO (Either SomeException ())
  _ <- try (waitForProcess ph) :: IO (Either SomeException ExitCode)
  pure ()

-- | Drain a process's stdout and stderr concurrently (as
-- 'readCreateProcessWithExitCode' does internally) so a chatty apalache
-- cannot deadlock the reader on a full pipe buffer.
drainOutputs :: Handle -> Handle -> IO (String, String)
drainOutputs hOut hErr = do
  outVar <- newEmptyMVar
  errVar <- newEmptyMVar
  _ <- forkIO (readAll hOut >>= putMVar outVar)
  _ <- forkIO (readAll hErr >>= putMVar errVar)
  (,) <$> takeMVar outVar <*> takeMVar errVar
  where
    readAll h = do
      s <- try (hGetContents h >>= \t -> evaluate (length t) >> pure t)
      pure (either (const "") id (s :: Either SomeException String))
