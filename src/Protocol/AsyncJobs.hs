-- | Mirror-side job machinery for the async validate-only and
-- trace-generation-only paths (docs/async-operations-design.md §4, §6, §11).
--
-- A per-session 'JobStore' owns a 'Resource.Registry'; every job resource
-- (spec, run dir, apalache child process) is acquired via the registry-backed
-- @*In@ variants from "Apalache.SpecSource" / "Apalache.Command", so
-- acquisition and registration are atomic and session close
-- ('closeJobStore' -> 'Resource.forceReleaseAll') reclaims anything still
-- live, LIFO, totally, and idempotently. Terminal transitions perform
-- targeted 'Resource.release' of the job's own resources; release is
-- CAS at-most-once, so targeted release and force-release never double-clean.
--
-- The job bodies reuse the exit-code classification of the synchronous paths
-- verbatim via 'Apalache.Command.validateSpecVia' /
-- 'generateTraceFilesVia', run over 'spawnApalacheIn' so the child process
-- handle stays reachable (in 'jhProc') and cancellation is real: releasing it
-- terminates the apalache child.
module Protocol.AsyncJobs
  ( JobStore (..)
  , JobHandle (..)
  , JobRunner
  , defaultJobRunner
  , maxValidateBound
  , newJobStore
  , newJobStoreWith
  , submitValidateJob
  , submitGenTracesJob
  , queryJob
  , awaitJob
  , cancelJob
  , closeJobStore
  , phaseText
  ) where

import Apalache.Command
  ( ApalacheResult (..)
  , generateTraceFilesVia
  , spawnApalacheIn
  , validateSpecVia
  )
import Apalache.Rpc.Types (ApalacheSpec)
import Apalache.SpecSource (SpecRes (..), acquireSessionDirIn, acquireSpecIn)
import Apalache.Types
  ( ApalacheConfig
  , ApalacheError (..)
  , TraceGenerationConfig
  )
import Control.Concurrent
  ( QSemN
  , ThreadId
  , forkIO
  , killThread
  , newQSemN
  , signalQSemN
  , threadDelay
  , waitQSemN
  )
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryPutMVar
  , tryReadMVar
  )
import qualified Control.Concurrent.MVar as MVar
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
  ( TVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, displayException, mask, try)
import Control.Monad (forM_, unless, void, when)
import Data.Foldable (traverse_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Core
  ( JobId (..)
  , JobKind (..)
  , JobOutcome (..)
  , JobPhase (..)
  )
import Resource
  ( Registry
  , Resource
  , forceReleaseAll
  , newRegistry
  , release
  , resourceErrorText
  , use
  )
import System.Directory (copyFile, createDirectoryIfMissing)
import System.FilePath (takeFileName, (</>))
import System.Process (ProcessHandle)

-- | Server-side cap on the check bound an async validate job may request.
-- Same value as the synchronous mirror guard; "Protocol.Mirror" imports this
-- module (its async 'Step' instances need 'JobStore'), so re-importing
-- Mirror here would create a module cycle — Mirror delegates to this
-- definition instead (single source of truth, no drift).
maxValidateBound :: Int
maxValidateBound = 100

-- | How the job bodies invoke apalache. Parameterized so tests can inject
-- fakes (design §9) without apalache on PATH: given the store's registry,
-- the job run dir (also the child's cwd), an observer invoked with each
-- spawned process resource (the job records it in 'jhProc' so cancel can
-- release it), and the argument list, run one invocation.
type JobRunner =
  Registry -> Maybe FilePath -> (Resource ProcessHandle -> IO ()) -> [String] -> IO (Either Text ApalacheResult)

-- | The real runner: 'spawnApalacheIn' with the on-spawn observer wired in.
defaultJobRunner :: JobRunner
defaultJobRunner reg runDir onSpawn args = do
  r <- spawnApalacheIn reg runDir args
  case r of
    Left err     -> pure (Left err)
    Right (res, phRes) -> do
      onSpawn phRes
      pure (Right res)

-- | Per-session async job store (design §4). @jsSlots@ bounds concurrent
-- apalache processes; @jsCounter@ generates @job-<n>@ ids unique per store;
-- @jsRegistry@ owns every job resource. @jsRunner@ is the injectable job
-- invocation (tests substitute fakes); @jsCapacity@ bounds the number of
-- live (non-terminal) jobs — a submit beyond it fails synchronously with
-- @job queue full@.
data JobStore = JobStore
  { jsJobs     :: MVar (Map JobId JobHandle)
  , jsSlots    :: QSemN
  , jsCounter  :: IORef Int
  , jsRegistry :: Registry
  , jsRunner   :: JobRunner
  , jsCapacity :: Int
  }

-- | One async job. 'jhResult' is written exactly once, at the terminal
-- transition (by the job thread on completion/failure or by 'cancelJob' on
-- cancellation — 'tryPutMVar' picks the single winner); terminal results are
-- retained until session close and delivery is idempotent. 'jhProc' holds
-- the running apalache child's process resource (an 'IORef' because the job
-- thread fills it after each spawn while cancel/session-close may read it
-- concurrently); releasing it terminates the child — that is what makes
-- cancellation real. 'jhSlotHeld' guards at-most-once slot signalling
-- between the job thread and a cancelling thread.
data JobHandle = JobHandle
  { jhKind     :: JobKind
  , jhPhase    :: TVar JobPhase
  , jhResult   :: MVar JobOutcome
  , jhThread   :: ThreadId
  , jhSpec     :: Resource SpecRes
  , jhRunDir   :: Resource FilePath
  , jhProc     :: IORef (Maybe (Resource ProcessHandle))
  , jhSlotHeld :: IORef Bool
  }

-- | A store with the default (real apalache) runner.
newJobStore :: Int -> IO JobStore
newJobStore capacity = newJobStoreWith capacity defaultJobRunner

-- | A store with an injected runner (tests).
newJobStoreWith :: Int -> JobRunner -> IO JobStore
newJobStoreWith capacity runner = do
  jobs <- newMVar Map.empty
  slots <- newQSemN (max 1 capacity)
  counter <- newIORef 0
  reg <- newRegistry
  pure (JobStore jobs slots counter reg runner capacity)

-- | Submit an async validate-only job. Pre-checks run synchronously in the
-- caller's (session) thread exactly like the sync path: the bound guard
-- @1..maxValidateBound@ and spec materialization (via 'acquireSpecIn').
-- Any failure yields @Left@ (the session turns it into a register error)
-- and just-acquired resources are released in place; on success the job
-- thread is forked and its id returned immediately.
submitValidateJob :: JobStore -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text JobId)
submitValidateJob store cfg bound mSpec
  | bound < 1 || bound > maxValidateBound =
      pure
        ( Left
            ( T.pack
                ( "validate bound " ++ show bound
                    ++ " outside allowed range 1.." ++ show maxValidateBound
                )
            )
        )
  | otherwise =
      submitJob store ValidateJob cfg mSpec $ \store' h cfg' ->
        validateBody store' cfg' bound h

-- | Submit an async trace-generation-only job; same synchronous pre-checks
-- (spec materialization only — there is no bound on this path).
submitGenTracesJob
  :: JobStore
  -> ApalacheConfig
  -> TraceGenerationConfig
  -> Maybe FilePath
  -> Maybe ApalacheSpec
  -> IO (Either Text JobId)
submitGenTracesJob store cfg tc destPath mSpec =
  submitJob store GenTracesJob cfg mSpec $ \store' h cfg' ->
    genTracesBody store' cfg' tc destPath h

-- | Shared submit: capacity check, registry-backed acquisition of the spec
-- and run dir, handle creation, job-thread fork, map insert. The forked
-- thread reads the handle through an 'MVar' because the handle carries the
-- 'ThreadId' of that very thread.
submitJob
  :: JobStore
  -> JobKind
  -> ApalacheConfig
  -> Maybe ApalacheSpec
  -> (JobStore -> JobHandle -> ApalacheConfig -> IO JobOutcome)
  -> IO (Either Text JobId)
submitJob store kind cfg mSpec body = do
  full <- jobStoreFull store
  if full
    then pure (Left (T.pack "job queue full"))
    else do
      specR <- acquireSpecIn (jsRegistry store) mSpec cfg
      case specR of
        Left err -> pure (Left err)
        Right (specRes, cfg') -> do
          dirR <- acquireSessionDirIn (jsRegistry store)
          case dirR of
            Left rerr -> do
              release specRes
              pure (Left (resourceErrorText rerr))
            Right runDirRes -> do
              jid <- nextJobId store
              phaseV <- newTVarIO JobPending
              resultV <- newEmptyMVar
              procR <- newIORef Nothing
              slotR <- newIORef False
              hvar <- newEmptyMVar
              forkR <- try $ forkIO $ do
                Just h <- MVar.takeMVar hvar
                jobThread store h (body store h cfg')
              case forkR of
                -- The fork itself failed (e.g. thread-table exhaustion):
                -- we are still before job_accepted, so release the
                -- just-acquired resources in place (§4 step 1) and surface
                -- a register error; no thread, handle, or map entry exists.
                Left (e :: SomeException) -> do
                  release runDirRes
                  release specRes
                  pure (Left (T.pack (displayException e)))
                Right tid -> do
                  let h =
                        JobHandle
                          { jhKind = kind
                          , jhPhase = phaseV
                          , jhResult = resultV
                          , jhThread = tid
                          , jhSpec = specRes
                          , jhRunDir = runDirRes
                          , jhProc = procR
                          , jhSlotHeld = slotR
                          }
                  putMVar hvar (Just h)
                  modifyMVar_ (jsJobs store) (pure . Map.insert jid h)
                  pure (Right jid)

-- | The job thread: acquire a worker slot (Pending -> Running), run the
-- body, then perform the terminal transition (phase, exactly-once result,
-- targeted resource release). Slot release is guarded by 'jhSlotHeld' with
-- an atomic swap so the job thread and a concurrent 'cancelJob' never
-- double-signal. The acquire+flag pair runs under 'mask' to shrink the
-- window in which an async exception could strand an acquired-but-unsigned
-- slot (a kill landing exactly inside 'waitQSemN' acquires nothing, which
-- is safe).
jobThread :: JobStore -> JobHandle -> IO JobOutcome -> IO ()
jobThread store h body = do
  _ <- try go :: IO (Either SomeException ())
  pure ()
  where
    go = mask $ \restore -> do
      restore (waitQSemN (jsSlots store) 1)
      writeIORef (jhSlotHeld h) True
      r <- try (restore work)
      wasHeld <- swapSlot h
      when wasHeld (signalQSemN (jsSlots store) 1)
      case r of
        Left (e :: SomeException) ->
          finishJob store h (JobInfraError (T.pack (displayException e)))
        Right () -> pure ()
    work = do
      p0 <- readTVarIO (jhPhase h)
      unless (isTerminalPhase p0) $ do
        setPhaseIfLive h JobRunning
        out <- body
        finishJob store h out

-- | Terminal transition: set the outcome phase (unless already terminal,
-- e.g. cancelled), write the result exactly once, and targeted-release the
-- job's own resources (process first, then run dir, then spec — release is
-- idempotent and total, so racing with cancel/session close is safe).
finishJob :: JobStore -> JobHandle -> JobOutcome -> IO ()
finishJob _store h out = do
  setPhaseIfLive h (outcomePhase out)
  void (tryPutMVar (jhResult h) out)
  releaseProc h
  release (jhRunDir h)
  release (jhSpec h)

validateBody :: JobStore -> ApalacheConfig -> Int -> JobHandle -> IO JobOutcome
validateBody store cfg bound h = do
  rdir <- use (jhRunDir h) pure
  case rdir of
    Left rerr -> pure (JobInfraError (resourceErrorText rerr))
    Right dir -> do
      let run = jsRunner store (jsRegistry store) (Just dir) (recordProc h)
      res <- validateSpecVia run (Just dir) cfg bound
      pure $ case res of
        Left (ApalacheError e) -> JobInfraError e
        Right v                -> JobValidateDone v

genTracesBody
  :: JobStore -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> JobHandle -> IO JobOutcome
genTracesBody store cfg tc destPath h = do
  rdir <- use (jhRunDir h) pure
  case rdir of
    Left rerr -> pure (JobInfraError (resourceErrorText rerr))
    Right dir -> do
      let run = jsRunner store (jsRegistry store) (Just dir) (recordProc h)
      res <- generateTraceFilesVia run (Just dir) cfg tc
      case res of
        Left (ApalacheError e) -> pure (JobInfraError e)
        Right (outDir, paths) -> do
          -- Same dest-path copy-then-report flow as the synchronous
          -- MkRunMirrorGenTraces path.
          finalPaths <- case destPath of
            Just d | d /= outDir -> do
              createDirectoryIfMissing True d
              forM_ paths $ \p -> copyFile p (d </> takeFileName p)
              pure (map (\p -> d </> takeFileName p) paths)
            _ -> pure paths
          contentsRes <- readTraceContents finalPaths
          pure $ case contentsRes of
            Left err   -> JobInfraError err
            Right cs   -> JobGenTracesDone finalPaths cs

-- | Trace-content readback, same as the synchronous path: parse each
-- generated ITF file as JSON.
readTraceContents :: [FilePath] -> IO (Either Text [A.Value])
readTraceContents ps = fmap sequence (traverse readOne ps)
  where
    readOne p = do
      bs <- LBS.readFile p
      pure $ case A.decode bs of
        Just v  -> Right v
        Nothing -> Left (T.pack ("failed to parse generated trace: " ++ p))

-- | Non-blocking poll. Unknown ids come back in-band as 'JobUnknown'.
-- Terminal jobs also carry their (retained, idempotently deliverable)
-- outcome.
queryJob :: JobStore -> JobId -> IO (JobPhase, Maybe JobOutcome)
queryJob store jid = do
  m <- readMVar (jsJobs store)
  case Map.lookup jid m of
    Nothing -> pure (JobUnknown, Nothing)
    Just h -> do
      p <- readTVarIO (jhPhase h)
      if isTerminalPhase p
        then do
          out <- tryReadMVar (jhResult h)
          pure (p, out)
        else pure (p, Nothing)

-- | Long-poll: block on the job's result 'MVar', with an optional timeout
-- in seconds. Timeout yields @Left@ carrying the current phase (per §3, the
-- client may re-await); unknown ids yield @Left "unknown"@.
awaitJob :: JobStore -> JobId -> Maybe Int -> IO (Either Text JobOutcome)
awaitJob store jid mTimeout = do
  m <- readMVar (jsJobs store)
  case Map.lookup jid m of
    Nothing -> pure (Left (phaseText JobUnknown))
    Just h -> case mTimeout of
      Nothing -> Right <$> readMVar (jhResult h)
      Just secs -> do
        now <- tryReadMVar (jhResult h)
        case now of
          Just out -> pure (Right out)
          Nothing -> do
            raceVar <- newEmptyMVar
            t1 <- forkIO (readMVar (jhResult h) >>= \o -> void (tryPutMVar raceVar (Right o)))
            t2 <- forkIO (threadDelay (secs * 1000000) >> void (tryPutMVar raceVar (Left ())))
            r <- takeMVar raceVar
            killThread t1
            killThread t2
            case r of
              Right o -> pure (Right o)
              Left () -> do
                p <- readTVarIO (jhPhase h)
                pure (Left (phaseText p))

-- | Cancel a job (design §6): terminate the apalache child by releasing its
-- process resource, mark the phase 'JobCancelled', write the terminal
-- result (unblocking awaiters), kill the job thread, targeted-release the
-- job's spec and run dir, and return the worker slot if the job held one.
-- Unknown ids are a no-op (the session answers @job_status unknown@).
cancelJob :: JobStore -> JobId -> IO ()
cancelJob store jid = do
  m <- readMVar (jsJobs store)
  case Map.lookup jid m of
    Nothing -> pure ()
    Just h -> do
      p <- readTVarIO (jhPhase h)
      unless (isTerminalPhase p) $ do
        releaseProc h
        setPhaseIfLive h JobCancelled
        void (tryPutMVar (jhResult h) (JobInfraError (T.pack "job cancelled")))
        killThread (jhThread h)
        wasHeld <- swapSlot h
        when wasHeld (signalQSemN (jsSlots store) 1)
        release (jhRunDir h)
        release (jhSpec h)

-- | Session close: kill any still-live job's child and thread, then
-- force-release everything the registry owns (LIFO, total, idempotent).
closeJobStore :: JobStore -> IO ()
closeJobStore store = do
  m <- readMVar (jsJobs store)
  forM_ (Map.elems m) $ \h -> do
    p <- readTVarIO (jhPhase h)
    unless (isTerminalPhase p) $ do
      releaseProc h
      setPhaseIfLive h JobCancelled
      void (tryPutMVar (jhResult h) (JobInfraError (T.pack "job cancelled")))
      killThread (jhThread h)
      wasHeld <- swapSlot h
      when wasHeld (signalQSemN (jsSlots store) 1)
  forceReleaseAll (jsRegistry store)

--------------------------------------------------------------------------------
-- internals

recordProc :: JobHandle -> Resource ProcessHandle -> IO ()
recordProc h phRes = writeIORef (jhProc h) (Just phRes)

releaseProc :: JobHandle -> IO ()
releaseProc h = do
  mp <- readIORef (jhProc h)
  traverse_ release mp

swapSlot :: JobHandle -> IO Bool
swapSlot h = atomicModifyIORef' (jhSlotHeld h) (\b -> (False, b))

setPhaseIfLive :: JobHandle -> JobPhase -> IO ()
setPhaseIfLive h p = atomically $ do
  cur <- readTVar (jhPhase h)
  unless (isTerminalPhase cur) (writeTVar (jhPhase h) p)

isTerminalPhase :: JobPhase -> Bool
isTerminalPhase p = p == JobDone || p == JobFailed || p == JobCancelled

outcomePhase :: JobOutcome -> JobPhase
outcomePhase (JobInfraError _) = JobFailed
outcomePhase _                 = JobDone

nextJobId :: JobStore -> IO JobId
nextJobId store =
  JobId . T.pack . ("job-" ++) . show
    <$> atomicModifyIORef' (jsCounter store) (\n -> (n + 1, n))

jobStoreFull :: JobStore -> IO Bool
jobStoreFull store = do
  m <- readMVar (jsJobs store)
  phases <- traverse (readTVarIO . jhPhase) (Map.elems m)
  pure (length (filter (not . isTerminalPhase) phases) >= jsCapacity store)

-- | Wire-facing phase names (used by 'awaitJob' timeouts).
phaseText :: JobPhase -> Text
phaseText = \case
  JobPending   -> T.pack "pending"
  JobRunning   -> T.pack "running"
  JobDone      -> T.pack "done"
  JobFailed    -> T.pack "failed"
  JobCancelled -> T.pack "cancelled"
  JobUnknown   -> T.pack "unknown"
