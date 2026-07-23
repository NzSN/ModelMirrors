module RegistrySpec (spec, withStubHttp, withCapturingStub, httpOk) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Monad (forever)
import Data.ByteString.Char8 qualified as B8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , SockAddr (..)
  , SocketOption (..)
  , accept
  , bind
  , close
  , defaultHints
  , getAddrInfo
  , getSocketName
  , listen
  , setSocketOption
  , socket
  )
import Network.Socket.ByteString qualified as NSB
import Protocol.Registry
  ( RegistryUrl (..)
  , ServiceInfo (..)
  , deregisterService
  , discoverServices
  , heartbeatLoop
  , registerService
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

spec :: TestTree
spec = testGroup "RegistrySpec"
  [ testDiscoverHappyPath
  , testDiscoverFailsClosed
  , testRegisterHeartbeatDeregister
  ]

consulResponse :: B8.ByteString
consulResponse = B8.pack $ unlines
  [ "["
  , "  {"
  , "    \"Service\": {"
  , "      \"ID\": \"modelmirrors-host1-8999\","
  , "      \"Address\": \"10.0.0.5\","
  , "      \"Port\": 8999,"
  , "      \"Meta\": { \"cert-sha256\": \"deadbeef\" }"
  , "    }"
  , "  },"
  , "  {"
  , "    \"Service\": {"
  , "      \"ID\": \"modelmirrors-host1-9000\","
  , "      \"Address\": \"10.0.0.6\","
  , "      \"Port\": 9000,"
  , "      \"Meta\": null"
  , "    }"
  , "  }"
  , "]"
  ]

httpOk :: B8.ByteString -> B8.ByteString
httpOk body = B8.concat
  [ B8.pack "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
  , B8.pack (show (B8.length body))
  , B8.pack "\r\n\r\n"
  , body
  ]

-- | Serve one canned HTTP response then stop.
withStubHttp :: B8.ByteString -> (PortNumber -> IO a) -> IO a
withStubHttp body action = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
  case addrs of
    [] -> error "withStubHttp: cannot resolve 127.0.0.1"
    (addr : _) -> do
      lsock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption lsock ReuseAddr 1
      bind lsock (addrAddress addr)
      listen lsock 1
      SockAddrInet port _ <- getSocketName lsock
      tid <- forkIO $ do
        (conn, _) <- accept lsock
        _ <- NSB.recv conn 65536
        NSB.sendAll conn (httpOk body)
        close conn
      r <- action port
      killThread tid
      close lsock
      pure r

-- | Serve canned empty-JSON responses forever, recording every raw
-- request (newest first) into the returned 'IORef'.
withCapturingStub :: (IORef [B8.ByteString] -> PortNumber -> IO a) -> IO a
withCapturingStub action = do
  ref <- newIORef []
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
  case addrs of
    [] -> error "withCapturingStub: cannot resolve 127.0.0.1"
    (addr : _) -> do
      lsock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption lsock ReuseAddr 1
      bind lsock (addrAddress addr)
      listen lsock 5
      SockAddrInet port _ <- getSocketName lsock
      tid <- forkIO $ forever $ do
        (conn, _) <- accept lsock
        req <- NSB.recv conn 65536
        modifyIORef' ref (req :)
        NSB.sendAll conn (httpOk (B8.pack "[]"))
        close conn
      r <- action ref port
      killThread tid
      close lsock
      pure r

testDiscoverHappyPath :: TestTree
testDiscoverHappyPath = testCase "discoverServices parses healthy service entries" $ do
  withStubHttp consulResponse $ \port -> do
    infos <- discoverServices (RegistryUrl ("http://127.0.0.1:" ++ show port))
    infos @?=
      [ ServiceInfo (T.pack "modelmirrors-host1-8999") "10.0.0.5" 8999 (Just (T.pack "deadbeef"))
      , ServiceInfo (T.pack "modelmirrors-host1-9000") "10.0.0.6" 9000 Nothing
      ]

testDiscoverFailsClosed :: TestTree
testDiscoverFailsClosed = testCase "discoverServices fails closed on garbage and on unreachable registry" $ do
  withStubHttp (B8.pack "not json") $ \port -> do
    infos <- discoverServices (RegistryUrl ("http://127.0.0.1:" ++ show port))
    infos @?= []
  port <- closedPort
  infos <- discoverServices (RegistryUrl ("http://127.0.0.1:" ++ show port))
  infos @?= []
  where
    closedPort = do
      addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
      case addrs of
        [] -> error "closedPort: cannot resolve 127.0.0.1"
        (addr : _) -> do
          s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
          bind s (addrAddress addr)
          SockAddrInet p _ <- getSocketName s
          close s
          pure p

-- | The server-side registry flow (--registry): registerService sends a
-- PUT with the service name, port, and fingerprint meta; heartbeatLoop
-- passes the TTL check; deregisterService deregisters.
testRegisterHeartbeatDeregister :: TestTree
testRegisterHeartbeatDeregister = testCase "register, heartbeat, and deregister send expected PUTs" $ do
  withCapturingStub $ \ref port -> do
    let reg = RegistryUrl ("http://127.0.0.1:" ++ show port)
        sid = T.pack "modelmirrors-test-8999"
    ok <- registerService reg (ServiceInfo sid "10.0.0.9" 8999 (Just (T.pack "beef")))
    ok @?= True
    tid <- forkIO (heartbeatLoop reg sid)
    deregisterService reg sid
    threadDelay 300000
    killThread tid
    reqs <- readIORef ref
    let texts = map B8.unpack reqs
    assertBool "register PUT with service name, port, and fingerprint meta"
      (any (\r -> "PUT /v1/agent/service/register" `isInfixOf` r
               && "\"modelmirrors\"" `isInfixOf` r
               && "\"cert-sha256\":\"beef\"" `isInfixOf` r
               && "8999" `isInfixOf` r) texts)
    assertBool "heartbeat PUT to TTL check endpoint"
      (any ("PUT /v1/agent/check/pass/service:modelmirrors-test-8999" `isInfixOf`) texts)
    assertBool "deregister PUT"
      (any ("PUT /v1/agent/service/deregister/modelmirrors-test-8999" `isInfixOf`) texts)
