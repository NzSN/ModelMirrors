module TcpTransportSpec (spec) where

import Apalache.Types (Value (..))
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (IOException, try)
import Data.ByteString.Char8 qualified as B8
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , SockAddr (..)
  , Socket
  , accept
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , getSocketName
  , listen
  , socket
  )
import Protocol.Core (ClientMessage (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (recvMsg, send, sendMsg)
import Protocol.Transport.Tcp (TcpTransport, serveTcp, tcpTransport)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

spec :: TestTree
spec = testGroup "TcpTransportSpec"
  [ testRoundtrip
  , testRoundtripBigState
  , testServeSurvivesDrops
  ]

openBound :: PortNumber -> IO Socket
openBound port = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just (show port))
  case addrs of
    [] -> error "openBound: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind s (addrAddress addr)
      pure s

freePort :: IO PortNumber
freePort = do
  s <- openBound 0
  SockAddrInet p _ <- getSocketName s
  close s
  pure p

connectTo :: Int -> PortNumber -> IO Socket
connectTo retries port = do
  addrs <- getAddrInfo (Just defaultHints) (Just "127.0.0.1") (Just (show port))
  case addrs of
    [] -> error "connectTo: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      r <- try (connect s (addrAddress addr))
      case r of
        Right () -> pure s
        Left (_ :: IOException)
          | retries > 0 -> close s >> threadDelay 100000 >> connectTo (retries - 1) port
          | otherwise   -> close s >> error "connectTo: connection refused"

-- | A connected pair of TcpTransports over loopback, plus a cleanup action.
socketPair :: IO (TcpTransport, TcpTransport, IO ())
socketPair = do
  lsock <- openBound 0
  SockAddrInet port _ <- getSocketName lsock
  listen lsock 1
  serverMv <- newEmptyMVar
  _ <- forkIO $ do
    (conn, _) <- accept lsock
    putMVar serverMv conn
  csock <- connectTo 20 port
  ssock <- readMVar serverMv
  serverT <- tcpTransport ssock
  clientT <- tcpTransport csock
  pure (serverT, clientT, close ssock >> close csock >> close lsock)

testRoundtrip :: TestTree
testRoundtrip = testCase "message roundtrip over loopback" $ do
  (serverT, clientT, cleanup) <- socketPair
  _ <- forkIO $ do
    msg <- recvMsg serverT :: IO (Either String ClientMessage)
    case msg of
      Right ExploreNextStep -> sendMsg serverT (ExplorerReady 1 2 3)
      _ -> pure ()
  sendMsg clientT ExploreNextStep
  reply <- recvMsg clientT :: IO (Either String MirrorMessage)
  reply @?= Right (ExplorerReady 1 2 3)
  cleanup

testRoundtripBigState :: TestTree
testRoundtripBigState = testCase "bigint state survives the roundtrip" $ do
  (serverT, clientT, cleanup) <- socketPair
  let st = Map.singleton (T.pack "x") (VInt 9007199254740993)
  _ <- forkIO $ do
    msg <- recvMsg serverT :: IO (Either String ClientMessage)
    case msg of
      Right (ExploreAssumeState s) -> sendMsg serverT (ExploreState s)
      _ -> pure ()
  sendMsg clientT (ExploreAssumeState st)
  reply <- recvMsg clientT :: IO (Either String MirrorMessage)
  reply @?= Right (ExploreState st)
  cleanup

testServeSurvivesDrops :: TestTree
testServeSurvivesDrops = testCase "serveTcp accept loop survives dropped connections" $ do
  port <- freePort
  tid <- forkIO (serveTcp port)
  threadDelay 200000

  s1 <- connectTo 20 port
  close s1
  threadDelay 200000

  s2 <- connectTo 20 port
  t2 <- tcpTransport s2
  send t2 (B8.pack "garbage")
  reply <- recvMsg t2 :: IO (Either String MirrorMessage)
  case reply of
    Right (ProtocolError _) -> pure ()
    other -> assertFailure ("expected protocol_error, got " ++ show other)
  close s2

  s3 <- connectTo 20 port
  assertBool "accept loop still accepting" True
  close s3
  killThread tid
