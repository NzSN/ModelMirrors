module Engine.Interactive
  ( stdioJSONDriver
  , makeTransportDriver
  ) where

import qualified Data.Map.Strict as Map
import Engine.Replay (StateDriver (..))
import Engine.Types (StepCommand (..))
import Protocol.Core (MirrorMessage (..), ClientMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport, sendMsg, recvMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

makeTransportDriver :: Transport t => t -> StateDriver IO
makeTransportDriver transport = StateDriver $ \cmd -> do
  sendMsg transport (commandToMessage cmd)
  resp <- recvMsg transport
  case resp of
    Right (ReportState state) -> pure state
    _                         -> pure Map.empty

stdioJSONDriver :: StateDriver IO
stdioJSONDriver = makeTransportDriver StdioTransport

commandToMessage :: StepCommand -> MirrorMessage
commandToMessage (CmdInitial act state) = InitialState act state
commandToMessage (CmdNextStep act params) = NextStep act params
