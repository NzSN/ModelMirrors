module Engine.Interactive (stdioJSONDriver) where

import qualified Data.Map.Strict as Map
import Engine.Replay (EngineM (..), StateDriver (..), StateDiff (..))
import Engine.Types (StepCommand (..))
import Protocol.Core (MirrorMessage (..), ClientMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (sendMsg, recvMsg)
import Protocol.Transport.Stdio (StdioTransport (..))

instance EngineM IO where
  onStepResult StatesMatch = sendMsg StdioTransport StepOk
  onStepResult (StateMismatch expected actual _) =
    sendMsg StdioTransport (StepMismatch expected actual)

stdioJSONDriver :: StateDriver IO
stdioJSONDriver = StateDriver $ \cmd -> do
  sendMsg StdioTransport (commandToMessage cmd)
  resp <- recvMsg StdioTransport
  case resp of
    Right (ReportState state) -> pure state
    _                         -> pure Map.empty

commandToMessage :: StepCommand -> MirrorMessage
commandToMessage (CmdInitial act) = InitialState act
commandToMessage (CmdNextStep act) = NextStep act
