module Protocol.Client
  ( Client (..)
  , runClient
  , cannedClient
  , fixedClient
  ) where

import Apalache.Types (TraceGenerationConfig, ValidateResult (..), Value)
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
  , clientHandler   :: Text -> IO (Map Text Value)
  }

runClient :: Transport t => Client t -> FilePath -> TraceGenerationConfig -> IO (Either Text ())
runClient client specPath config = do
  sendMsg (clientTransport client) (Register specPath config)
  recvMsg (clientTransport client) >>= \case
    Left err                               -> pure (Left (T.pack err))
    Right (SpecValidated SpecValid)       -> stepLoop client
    Right (SpecValidated (SpecInvalid e)) -> pure (Left e)
    Right _                                -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))

stepLoop :: Transport t => Client t -> IO (Either Text ())
stepLoop client = do
  recvMsg (clientTransport client) >>= \case
    Left err                  -> pure (Left (T.pack err))
    Right (InitialState a _)  -> handleStep client a
    Right (NextStep a)        -> handleStep client a
    Right AllStepsDone        -> pure (Right ())
    Right (ProtocolError e)   -> pure (Left e)
    Right _                   -> pure (Left (T.pack "Unexpected message in step loop"))

handleStep :: Transport t => Client t -> Text -> IO (Either Text ())
handleStep client action = do
  actual <- clientHandler client action
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
  pure $ Client t $ \_ -> do
    rs <- readIORef ref
    case rs of
      []     -> pure Map.empty
      r : rest -> writeIORef ref rest >> pure r

fixedClient :: t -> Map Text Value -> Client t
fixedClient t state = Client t (const (pure state))
