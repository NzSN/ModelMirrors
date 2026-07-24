module Engine.Interactive
  ( stdioJSONDriver
  , makeTransportDriver
  ) where

import Control.Exception (Exception, throwIO)
import Data.Text qualified as T
import Engine.Replay (StateDriver (..))
import Engine.Types (StepCommand (..))
import Protocol.Core (MirrorMessage (..), ClientMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, sendMsg, recvMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

data ProtocolException = ProtocolException String
  deriving Show
instance Exception ProtocolException

-- | On undecodable or unexpected input the client is told
-- 'ProtocolError' before the driver aborts, so a networked client
-- always sees an explicit error rather than a silent disconnect.
makeTransportDriver :: Transport t => t -> StateDriver IO
makeTransportDriver transport = StateDriver $ \cmd -> do
  sendMsg transport (commandToMessage cmd)
  resp <- recvMsg transport
  case resp of
    Right (ReportState state) -> pure state
    Left err -> do
      sendMsg transport (ProtocolError (T.pack err))
      throwIO $ ProtocolException $ "Protocol error: " ++ err
    Right msg -> do
      sendMsg transport (ProtocolError (T.pack ("Expected ReportState, got: " ++ show (msg :: ClientMessage))))
      throwIO $ ProtocolException $ "Expected ReportState, got: " ++ show (msg :: ClientMessage)

stdioJSONDriver :: StateDriver IO
stdioJSONDriver = makeTransportDriver StdioTransport

commandToMessage :: StepCommand -> MirrorMessage
commandToMessage (CmdInitial act state) = InitialState act state
commandToMessage (CmdNextStep act params) = NextStep act params
