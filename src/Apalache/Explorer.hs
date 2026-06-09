module Apalache.Explorer
  ( Explorer (..)
  , startApalacheServer
  , stopApalacheServer
  , withApalacheServer
  , newExplorer
  , exploreInit
  , exploreNext
  , exploreCheck
  , exploreQueryState
  , exploreQueryOperator
  , exploreAssumeState
  , exploreRollback
  , exploreDispose
  , exploreUntilViolation
  ) where

import Apalache.Command (apalacheBin)
import Apalache.Rpc.Client
import Apalache.Rpc.Types
import Apalache.Types (ItfTrace, Value)
import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as B64 (encode)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Process
  ( createProcess
  , proc
  , terminateProcess
  , waitForProcess
  )

data Explorer = Explorer
  { explServer    :: !ApalacheServer
  , explClient    :: !RpcClient
  , explSessionId :: !Text
  , explSnap      :: !Int
  , explParams    :: !SpecParams
  }

startApalacheServer :: Maybe Int -> IO ApalacheServer
startApalacheServer mPort = do
  bin <- apalacheBin
  port <- case mPort of
    Just p -> pure p
    Nothing -> pure 8822
  let args =
        [ "server"
        , "--port=" ++ show port
        , "--server-type=explorer"
        ]
  (_, _, _, ph) <- createProcess (proc bin args)
  client <- newRpcClient port
  waitForServer client 60
  pure $ ApalacheServer port ph

stopApalacheServer :: ApalacheServer -> IO ()
stopApalacheServer server = do
  terminateProcess (serverProcess server)
  _ <- waitForProcess (serverProcess server)
  pure ()

withApalacheServer :: Maybe Int -> (ApalacheServer -> IO a) -> IO a
withApalacheServer mPort action = do
  server <- startApalacheServer mPort
  action server `finally` stopApalacheServer server

waitForServer :: RpcClient -> Int -> IO ()
waitForServer client maxRetries = go maxRetries
  where
    go 0 = pure ()
    go n = do
      result <- health client
      case result of
        Right _ -> pure ()
        _ -> do
          threadDelay 500000
          go (n - 1)

newExplorer
  :: ApalacheServer
  -> ApalacheSpec
  -> [Text]
  -> [Text]
  -> IO (Either RpcError Explorer)
newExplorer server spec invs exports = do
  let b64Sources = map (encodeB64 . TE.encodeUtf8) (getSpecSources spec)
      params = LoadSpecParams
        { lspSources    = b64Sources
        , lspInit       = Nothing
        , lspNext       = Nothing
        , lspInvariants = invs
        , lspExports    = exports
        }
  client <- newRpcClient (serverPort server)
  result <- loadSpec client params
  case result of
    Left err -> pure $ Left err
    Right lsr -> pure $ Right $ Explorer
      { explServer    = server
      , explClient    = client
      , explSessionId = lsrSessionId lsr
      , explSnap      = lsrSnapshotId lsr
      , explParams    = lsrSpecParams lsr
      }

exploreInit :: Explorer -> IO (Either RpcError Explorer)
exploreInit expl = do
  let nInits = length (spInitTransitions (explParams expl))
  if nInits == 0
    then pure $ Right expl
    else do
      let params = AssumeTransitionParams
            { atpSessionId    = explSessionId expl
            , atpTransitionId = 0
            , atpCheckEnabled = True
            , atpTimeoutSec   = Nothing
            }
      atResult <- assumeTransition (explClient expl) params
      case atResult of
        Left err -> pure $ Left err
        Right _ -> do
          let nsParams = NextStateParams
                { nspSessionId = explSessionId expl
                }
          nsResult <- nextStep (explClient expl) nsParams
          case nsResult of
            Left err -> pure $ Left err
            Right nsr -> pure $ Right $ expl
              { explSnap = nsrSnapshotId nsr
              }

exploreNext :: Explorer -> Int -> IO (Either RpcError (Explorer, TransitionStatus))
exploreNext expl tid = do
  let params = AssumeTransitionParams
        { atpSessionId    = explSessionId expl
        , atpTransitionId = tid
        , atpCheckEnabled = True
        , atpTimeoutSec   = Nothing
        }
  atResult <- assumeTransition (explClient expl) params
  case atResult of
    Left err -> pure $ Left err
    Right atr -> case atrStatus atr of
      TransEnabled -> do
        let nsParams = NextStateParams
              { nspSessionId = explSessionId expl
              }
        nsResult <- nextStep (explClient expl) nsParams
        case nsResult of
          Left err -> pure $ Left err
          Right nsr -> pure $ Right
            ( expl { explSnap = nsrSnapshotId nsr }
            , TransEnabled
            )
      _ -> pure $ Right (expl, atrStatus atr)

exploreCheck
  :: Explorer
  -> Int
  -> InvariantKind
  -> IO (Either RpcError (InvariantStatus, Maybe ItfTrace))
exploreCheck expl iid kind = do
  let params = CheckInvariantParams
        { cipSessionId   = explSessionId expl
        , cipInvariantId = iid
        , cipKind        = kind
        , cipTimeoutSec  = Nothing
        }
  ciResult <- checkInvariant (explClient expl) params
  case ciResult of
    Left err -> pure $ Left err
    Right cir -> pure $ Right (cirStatus cir, cirTrace cir)

exploreQueryState :: Explorer -> IO (Either RpcError (Map Text Value))
exploreQueryState expl = do
  let params = QueryParams
        { qpSessionId = explSessionId expl
        , qpKinds     = [QueryState]
        , qpOperator  = Nothing
        , qpTimeoutSec = Nothing
        }
  qResult <- query (explClient expl) params
  case qResult of
    Left err -> pure $ Left err
    Right qr -> case qrState qr of
      Just s  -> pure $ Right s
      Nothing -> pure $ Left $ RpcParseError (T.pack "query did not return state")

exploreQueryOperator :: Explorer -> Text -> IO (Either RpcError Value)
exploreQueryOperator expl opName = do
  let params = QueryParams
        { qpSessionId = explSessionId expl
        , qpKinds     = [QueryOperator]
        , qpOperator  = Just opName
        , qpTimeoutSec = Nothing
        }
  qResult <- query (explClient expl) params
  case qResult of
    Left err -> pure $ Left err
    Right qr -> case qrOperatorValue qr of
      Just v  -> pure $ Right v
      Nothing -> pure $ Left $ RpcParseError (T.pack "query did not return operator value")

exploreAssumeState
  :: Explorer
  -> Map Text Value
  -> IO (Either RpcError (Explorer, TransitionStatus))
exploreAssumeState expl equalities = do
  let params = AssumeStateParams
        { aspSessionId    = explSessionId expl
        , aspCheckEnabled = True
        , aspTimeoutSec   = Nothing
        , aspEqualities   = equalities
        }
  asResult <- assumeState (explClient expl) params
  case asResult of
    Left err -> pure $ Left err
    Right asr -> pure $ Right
      ( expl { explSnap = asrSnapshotId asr }
      , asrStatus asr
      )

exploreRollback :: Explorer -> Int -> IO (Either RpcError Explorer)
exploreRollback expl snap = do
  let params = RollbackParams
        { rpSessionId  = explSessionId expl
        , rpSnapshotId = snap
        }
  rbResult <- rollback (explClient expl) params
  case rbResult of
    Left err -> pure $ Left err
    Right () -> pure $ Right $ expl { explSnap = snap }

exploreDispose :: Explorer -> IO (Either RpcError ())
exploreDispose expl = do
  let params = DisposeSpecParams
        { dspSessionId = explSessionId expl
        }
  disposeSpec (explClient expl) params

exploreUntilViolation :: Explorer -> IO (Either RpcError (Int, ItfTrace))
exploreUntilViolation expl = go 0 expl
  where
    go n e = do
      result <- exploreNext e 0
      case result of
        Left err -> pure $ Left err
        Right (_, TransDisabled) -> pure $ Left $ RpcProtocolError 0 (T.pack "transition disabled")
        Right (e', _) -> do
          ciResult <- exploreCheck e' 0 StateInvariant
          case ciResult of
            Left err -> pure $ Left err
            Right (InvViolated, Just trace) -> pure $ Right (n + 1, trace)
            Right _ -> go (n + 1) e'

encodeB64 :: ByteString -> Text
encodeB64 = TE.decodeUtf8 . B64.encode
