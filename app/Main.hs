module Main (main) where

import Data.Text qualified as T
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Mirror (runMirror)
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

main :: IO ()
main = do
  msg <- recvMsg StdioTransport
  case msg of
    Right (Register specPath config) -> runMirror StdioTransport specPath config
    Right _ -> sendMsg StdioTransport (ProtocolError (T.pack "Expected Register message"))
    Left err -> sendMsg StdioTransport (ProtocolError (T.pack err))
