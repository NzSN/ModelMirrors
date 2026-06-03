module Main (main) where

import Apalache.Command (generateTraces, validateSpec)
import Apalache.Types
    ( ApalacheConfig (..)
    , ApalacheError (..)
    , TraceGenerationConfig (..)
    , TraceGenerationResult (..)
    , ValidateResult (..)
    )
import Data.Text qualified as T
import Engine.Interactive (stdioJSONDriver)
import Engine.Replay (EngineM (replayTrace))
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

main :: IO ()
main = do
  msg <- recvMsg StdioTransport
  case msg of
    Right (Register specPath config) -> runMirror specPath config
    Right _ -> sendMsg StdioTransport (ProtocolError (T.pack "Expected Register message"))
    Left err -> sendMsg StdioTransport (ProtocolError (T.pack err))

runMirror :: FilePath -> TraceGenerationConfig -> IO ()
runMirror specPath config = do
  let cfg = ApalacheConfig specPath Nothing Nothing Nothing
  result <- validateSpec cfg (lengthBound config)
  case result of
    Left err ->
      sendMsg StdioTransport (ProtocolError (unApalacheError err))
    Right validationResult -> do
      sendMsg StdioTransport (SpecValidated validationResult)
      case validationResult of
        SpecInvalid _ -> pure ()
        SpecValid -> do
          traceRes <- generateTraces cfg config
          case traceRes of
            Left err ->
              sendMsg StdioTransport (ProtocolError (unApalacheError err))
            Right (TracesGenerated traces) -> do
              mapM_ (`replayTrace` stdioJSONDriver) traces
              sendMsg StdioTransport AllStepsDone
            Right (GenerationError e) ->
              sendMsg StdioTransport (ProtocolError e)
