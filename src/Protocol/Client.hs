module Protocol.Client
  ( Client (..)
  , runClient
  , runClientWithSpec
  , runClientWithTraces
  , runClientGenTraces
  , runClientGenTracesWithSpec
  , runClientExplore
  , runClientValidate
  , submitValidateAsync
  , submitGenTracesAsync
  , pollJob
  , awaitJob
  , cancelJob
  , runClientValidateAsync
  , runClientGenTracesAsync
  , exploreSession
  , cannedClient
  , fixedClient
  , hourClockClient
  ) where

import Apalache.Rpc.Types (ApalacheSpec)
import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult (..), Value (..))
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Core
  ( ClientMessage (..)
  , JobId
  , JobOutcome (..)
  , JobPhase (..)
  , MirrorMessage (..)
  , TraceContent
  , renderDiffHints
  )
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)

data Client t = Client
  { clientTransport :: t
  , clientHandler   :: Text -> Map Text Value -> IO (Map Text Value)
  }

runClient :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> IO (Either Text ())
runClient client apCfg tc = runClientWithSpec client apCfg tc Nothing

runClientWithSpec :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> Maybe ApalacheSpec -> IO (Either Text ())
runClientWithSpec client apCfg tc mSpec = do
  sendMsg (clientTransport client) (Register apCfg tc mSpec)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right (RegisterError e)               -> pure (Left e)
    Right (ProtocolError e)               -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

runClientWithTraces :: Transport t => Client t -> ApalacheConfig -> [FilePath] -> IO (Either Text ())
runClientWithTraces client apCfg traces = do
  sendMsg (clientTransport client) (RegisterTraces apCfg traces)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right (RegisterError e)               -> pure (Left e)
    Right (ProtocolError e)               -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

runClientGenTraces :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> IO (Either Text ())
runClientGenTraces client apCfg tc destPath = runClientGenTracesWithSpec client apCfg tc destPath Nothing

runClientGenTracesWithSpec :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO (Either Text ())
runClientGenTracesWithSpec client apCfg tc destPath mSpec = do
  sendMsg (clientTransport client) (RegisterGenTraces apCfg tc destPath mSpec)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (GenTracesDone _ _)             -> pure (Right ())
    Right (RegisterError e)                -> pure (Left e)
    Right (ProtocolError e)                -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected GenTracesDone"))

runClientExplore :: Transport t => Client t -> ApalacheSpec -> [Text] -> [Text] -> Int -> IO (Either Text ())
runClientExplore client spec invs exports maxSteps = do
  sendMsg (clientTransport client) (RegisterExplore spec invs exports maxSteps)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right (RegisterError e)               -> pure (Left e)
    Right (ProtocolError e)               -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

runClientValidate :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ValidateResult)
runClientValidate transport cfg bound mSpec = do
  sendMsg transport (RegisterValidate cfg bound mSpec)
  recvMsg transport >>= \case
    Left err                   -> pure (Left (T.pack err))
    Right (SpecValidated v)    -> pure (Right v)
    Right (RegisterError e)    -> pure (Left e)
    Right (ProtocolError e)    -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

--------------------------------------------------------------------------------
-- Async job client API (submit -> poll / long-poll)
--------------------------------------------------------------------------------

-- | Submit a validate-only job. Returns @Right jobId@ on @job_accepted@;
-- @Left@ on @register_error@ / @protocol_error@ / transport failure (same
-- error mapping as the sync runners).
submitValidateAsync :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text JobId)
submitValidateAsync transport cfg bound mSpec = do
  sendMsg transport (RegisterValidateAsync cfg bound mSpec)
  recvMsg transport >>= \case
    Left err                    -> pure (Left (T.pack err))
    Right (JobAccepted jobId _) -> pure (Right jobId)
    Right (RegisterError e)     -> pure (Left e)
    Right (ProtocolError e)     -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected JobAccepted"))

-- | Submit a trace-generation-only job. Same result mapping as
-- 'submitValidateAsync'.
submitGenTracesAsync :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO (Either Text JobId)
submitGenTracesAsync transport cfg tc destPath mSpec = do
  sendMsg transport (RegisterGenTracesAsync cfg tc destPath mSpec)
  recvMsg transport >>= \case
    Left err                    -> pure (Left (T.pack err))
    Right (JobAccepted jobId _) -> pure (Right jobId)
    Right (RegisterError e)     -> pure (Left e)
    Right (ProtocolError e)     -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected JobAccepted"))

-- | Non-blocking poll: the job's current phase, plus its outcome when the
-- job has already reached a terminal phase.
pollJob :: Transport t => t -> JobId -> IO (Either Text (JobPhase, Maybe JobOutcome))
pollJob transport jobId = do
  sendMsg transport (QueryJob jobId)
  recvMsg transport >>= \case
    Left err                    -> pure (Left (T.pack err))
    Right (JobStatus _ phase)   -> pure (Right (phase, Nothing))
    Right (JobResult _ outcome) -> pure (Right (terminalPhaseOf outcome, Just outcome))
    Right (RegisterError e)     -> pure (Left e)
    Right (ProtocolError e)     -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected JobStatus or JobResult"))

-- | Long-poll: blocks server-side (with optional timeout in seconds) and
-- loops on @job_status@ until the job's result arrives. On server-side
-- timeout the current phase comes back as @job_status@ and the client
-- simply re-awaits.
awaitJob :: Transport t => t -> JobId -> Maybe Int -> IO (Either Text JobOutcome)
awaitJob transport jobId mTimeout = do
  sendMsg transport (AwaitJob jobId mTimeout)
  recvMsg transport >>= \case
    Left err                    -> pure (Left (T.pack err))
    Right (JobResult _ outcome) -> pure (Right outcome)
    Right (JobStatus _ phase)
      | isTerminalPhase phase    -> pollUntilResult
      | otherwise                -> awaitJob transport jobId mTimeout
    Right (RegisterError e)     -> pure (Left e)
    Right (ProtocolError e)     -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected JobStatus or JobResult"))
  where
    -- Terminal phase seen without a result (the result raced the status
    -- reply): one-shot poll to pick up the retained result.
    pollUntilResult = do
      r <- pollJob transport jobId
      pure $ case r of
        Left e                -> Left e
        Right (_, Just o)     -> Right o
        Right (phase, Nothing)
          | phase == JobUnknown -> Left (T.pack "job result lost: unknown job")
          | otherwise           -> Left (T.pack "job terminal without delivered result")

-- | Request cancellation of a job. Succeeds once the mirror acknowledges
-- with a @job_status@ reply.
cancelJob :: Transport t => t -> JobId -> IO (Either Text ())
cancelJob transport jobId = do
  sendMsg transport (CancelJob jobId)
  recvMsg transport >>= \case
    Left err                  -> pure (Left (T.pack err))
    Right (JobStatus _ _)     -> pure (Right ())
    Right (RegisterError e)   -> pure (Left e)
    Right (ProtocolError e)   -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected JobStatus"))

isTerminalPhase :: JobPhase -> Bool
isTerminalPhase phase = phase `elem` [JobDone, JobFailed, JobCancelled, JobUnknown]

terminalPhaseOf :: JobOutcome -> JobPhase
terminalPhaseOf = \case
  JobValidateDone _    -> JobDone
  JobGenTracesDone _ _ -> JobDone
  JobInfraError _      -> JobFailed

-- | Drop-in async equivalent of 'runClientValidate': submit, await, and
-- return the same result shape as the synchronous one-shot.
runClientValidateAsync :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ValidateResult)
runClientValidateAsync transport cfg bound mSpec = do
  r <- submitValidateAsync transport cfg bound mSpec
  case r of
    Left err -> pure (Left err)
    Right jobId -> do
      res <- awaitJob transport jobId Nothing
      pure $ case res of
        Left err                  -> Left err
        Right (JobValidateDone v) -> Right v
        Right (JobInfraError e)   -> Left e
        Right _ -> Left (T.pack "Unexpected job outcome: expected validate result")

-- | Drop-in async equivalent of 'runClientGenTracesWithSpec': submit,
-- await, and return @Right (paths, traceContents)@.
runClientGenTracesAsync :: Transport t => t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> Maybe ApalacheSpec -> IO (Either Text ([FilePath], [TraceContent]))
runClientGenTracesAsync transport cfg tc destPath mSpec = do
  r <- submitGenTracesAsync transport cfg tc destPath mSpec
  case r of
    Left err -> pure (Left err)
    Right jobId -> do
      res <- awaitJob transport jobId Nothing
      pure $ case res of
        Left err                       -> Left err
        Right (JobGenTracesDone ps cs) -> Right (ps, cs)
        Right (JobInfraError e)        -> Left e
        Right _ -> Left (T.pack "Unexpected job outcome: expected trace generation result")

exploreSession :: Transport t => t -> ApalacheSpec -> [Text] -> [Text] -> IO (Either Text (Int, Int, Int))
exploreSession t spec invs exports = do
  sendMsg t (RegisterExploreSession spec invs exports)
  recvMsg t >>= \case
    Left err                       -> pure (Left (T.pack err))
    Right (ExplorerReady a b c)    -> pure (Right (a, b, c))
    Right (RegisterError e)        -> pure (Left e)
    Right (ProtocolError e)        -> pure (Left e)
    Right _                        -> pure (Left (T.pack "Unexpected message: expected ExplorerReady"))

stepLoop :: Transport t => Client t -> IO (Either Text ())
stepLoop client = do
  recvMsg (clientTransport client) >>= \case
    Left err                  -> pure (Left (T.pack err))
    Right (InitialState a s)  -> handleStep client a s
    Right (NextStep a p)        -> handleStep client a p
    Right AllStepsDone        -> pure (Right ())
    Right (ProtocolError e)   -> pure (Left e)
    Right _                   -> pure (Left (T.pack "Unexpected message in step loop"))

handleStep :: Transport t => Client t -> Text -> Map Text Value -> IO (Either Text ())
handleStep client action prevState = do
  actual <- clientHandler client action prevState
  sendMsg (clientTransport client) (ReportState actual)
  recvMsg (clientTransport client) >>= \case
    Left err         -> pure (Left (T.pack err))
    Right StepOk     -> stepLoop client
    Right (StepMismatch _ _ hints) ->
      pure (Left (T.pack "Step mismatch: " <> renderDiffHints hints))
    Right (ProtocolError e)  -> pure (Left e)
    Right _          -> pure (Left (T.pack "Unexpected message: expected StepOk or StepMismatch"))

cannedClient :: t -> [Map Text Value] -> IO (Client t)
cannedClient t responses = do
  ref <- newIORef responses
  pure $ Client t $ \_ _ -> do
    rs <- readIORef ref
    case rs of
      []     -> pure Map.empty
      r : rest -> writeIORef ref rest >> pure r

fixedClient :: t -> Map Text Value -> Client t
fixedClient t state = Client t (\_ _ -> pure state)

hourClockClient :: t -> IO (Client t)
hourClockClient t = do
  ref <- newIORef Map.empty
  pure $ Client t $ \action prevState -> do
    if action == T.pack "init"
      then do
        writeIORef ref prevState
        pure prevState
      else if action == T.pack "tick"
        then do
          current <- readIORef ref
          let next = hcTick current
          writeIORef ref next
          pure next
        else readIORef ref

hcTick :: Map Text Value -> Map Text Value
hcTick state = Map.fromList
  [ (T.pack "hr", newHr)
  , (T.pack "latest_hr", VInt oldHrVal)
  , (T.pack "ticked", VBool True)
  , (T.pack "action_taken", VStr (T.pack "tick"))
  , (T.pack "nondet_picks", picks)
  , (T.pack "step_count", VInt (oldStep + 1))
  ]
  where
    oldHrVal = getInt (T.pack "hr") state
    newHr = VInt (if oldHrVal /= 12 then oldHrVal + 1 else 1)
    oldStep = getInt (T.pack "step_count") state
    picks = Map.findWithDefault VNull (T.pack "nondet_picks") state

getInt :: Text -> Map Text Value -> Integer
getInt k m = case Map.lookup k m of
  Just (VInt n) -> n
  _             -> 0
