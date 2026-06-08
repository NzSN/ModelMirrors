module Protocol.Client
  ( Client (..)
  , runClient
  , runClientWithTraces
  , runClientGenTraces
  , cannedClient
  , fixedClient
  , hourClockClient
  ) where

import Apalache.Types (ApalacheConfig, TraceGenerationConfig, ValidateResult (..), Value (..))
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, recvMsg, sendMsg)

data Client t = Client
  { clientTransport :: t
  , clientHandler   :: Text -> Map Text Value -> IO (Map Text Value)
  }

runClient :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> IO (Either Text ())
runClient client apCfg tc = do
  sendMsg (clientTransport client) (Register apCfg tc)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right (RegisterError e)               -> pure (Left e)
    Right (ProtocolError e)               -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

runClientWithTraces :: Transport t => Client t -> [FilePath] -> IO (Either Text ())
runClientWithTraces client traces = do
  sendMsg (clientTransport client) (RegisterTraces traces)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right (RegisterError e)               -> pure (Left e)
    Right (ProtocolError e)               -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

runClientGenTraces :: Transport t => Client t -> ApalacheConfig -> TraceGenerationConfig -> Maybe FilePath -> IO (Either Text ())
runClientGenTraces client apCfg tc destPath = do
  sendMsg (clientTransport client) (RegisterGenTraces apCfg tc destPath)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (GenTracesDone _)                -> pure (Right ())
    Right (RegisterError e)                -> pure (Left e)
    Right (ProtocolError e)                -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected GenTracesDone"))

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
    Right (StepMismatch _ _) -> pure (Left (T.pack "Step mismatch"))
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
