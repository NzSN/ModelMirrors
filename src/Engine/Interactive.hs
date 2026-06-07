module Engine.Interactive
  ( stdioJSONDriver
  , makeTransportDriver
  ) where

import Control.Exception (Exception, throwIO)
import Engine.Replay (StateDriver (..))
import Engine.Types (StepCommand (..))
import Protocol.Core (MirrorMessage (..), ClientMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, sendMsg, recvMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

data ProtocolException = ProtocolException String
  deriving Show
instance Exception ProtocolException

makeTransportDriver :: Transport t => t -> StateDriver IO
makeTransportDriver transport = StateDriver $ \cmd -> do
  sendMsg transport (commandToMessage cmd)
  resp <- recvMsg transport
  case resp of
    Right (ReportState state) -> pure state
    Left err -> throwIO $ ProtocolException $ "Protocol error: " ++ err
    Right msg -> throwIO $ ProtocolException $ "Expected ReportState, got: " ++ show (msg :: ClientMessage)

stdioJSONDriver :: StateDriver IO
stdioJSONDriver = makeTransportDriver StdioTransport

commandToMessage :: StepCommand -> MirrorMessage
commandToMessage (CmdInitial act state) = InitialState act state
commandToMessage (CmdNextStep act params) = NextStep act params
