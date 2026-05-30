module Engine.Interactive (stdioDriver) where

import qualified Data.Map.Strict as Map
import Engine.Replay (EngineM, StateDriver (..))
import Engine.Types (StepCommand (..))
import Protocol.Core (MirrorMessage (..), ClientMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (sendMsg, recvMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

instance EngineM IO

stdioDriver :: StateDriver IO
stdioDriver = StateDriver $ \cmd -> do
  sendMsg StdioTransport (commandToMessage cmd)
  resp <- recvMsg StdioTransport
  case resp of
    Right (ReportState state) -> pure state
    _                         -> pure Map.empty

commandToMessage :: StepCommand -> MirrorMessage
commandToMessage (CmdInitial state) = InitialState state
commandToMessage (CmdNextStep state) = NextStep state
