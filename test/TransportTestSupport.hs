module TransportTestSupport
  ( withTcpPeer
  , withCerts
  , withTlsPeer
  , withTlsPeerParams
  , withTlsPeerConnection
  , bounded
  , expectFailure
  , PeerTimeout (..)
  , assertTlsRejectsBeforeProtocol
  ) where

import Control.Concurrent (forkFinally, forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (Exception, SomeException, bracket, catch, finally, fromException, throwIO, try)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Network.Socket
  ( Family (AF_INET), PortNumber, Socket, SocketType (Stream), SockAddr (SockAddrInet)
  , accept, bind, close, connect, defaultProtocol, getSocketName, listen
  , socket, tupleToHostAddress )
import Network.TLS
  ( ClientParams, Context, ServerParams, bye, contextClose, contextNew, handshake, recvData )
import Protocol.Core (ClientMessage (ExploreNextStep))
import Protocol.Format.Json ()
import Protocol.Transport.Core (sendMsg)
import Protocol.Transport.Tcp (TcpTransport, tcpClose, tcpTransport)
import Protocol.Transport.Tls (TlsTransport, connectTls, mkClientParams, mkServerParams, tlsClose)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertFailure, (@?=))

data PeerTimeout = PeerTimeout deriving (Show)
instance Exception PeerTimeout

bounded :: IO a -> IO a
bounded action = timeout 5000000 action >>= maybe (throwIO PeerTimeout) pure

expectFailure :: IO a -> IO ()
expectFailure action = do
  -- Catch outside timeout: otherwise a broad SomeException handler can swallow
  -- timeout's own exception and incorrectly credit a stalled read as refusal.
  result <- try (timeout 5000000 action)
  case result of
    Left (err :: SomeException) -> case fromException err of
      Just PeerTimeout -> assertFailure "peer setup timed out instead of explicitly refusing the request"
      Nothing -> pure ()
    Right Nothing -> assertFailure "expected immediate refusal, but the operation timed out"
    Right (Just _) -> assertFailure "expected an explicit failure"

openPair :: IO (Socket, Socket)
openPair = bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
  bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 1
  addr <- getSocketName listener
  client <- socket AF_INET Stream defaultProtocol
  connect client addr
  (server, _) <- accept listener
  pure (client, server)

withTcpPeer :: (TcpTransport -> Socket -> IO a) -> IO a
withTcpPeer action = bracket acquire release (uncurry action)
  where
    acquire = do
      (client, server) <- openPair
      t <- tcpTransport client
      pure (t, server)
    release (t, peer) = tcpClose t `finally` close peer

withCerts :: (FilePath -> IO a) -> IO a
withCerts action = withSystemTempDirectory "modelmirrors-framing" $ \dir -> do
  callProcess "sh" ["scripts/gen-certs.sh", dir, "127.0.0.1", "1"]
  action dir

withTlsPeer :: FilePath -> (TlsTransport -> Context -> IO a) -> IO a
withTlsPeer dir action = do
  server <- mkServerParams (dir </> "server.crt") (dir </> "server.key") (dir </> "ca.crt")
  client <- mkClientParams "127.0.0.1" (dir </> "client.crt") (dir </> "client.key") (dir </> "ca.crt")
  withTlsPeerParams server client action

-- Separate certificate identity from the loopback connection destination.
withTlsPeerParams :: ServerParams -> ClientParams -> (TlsTransport -> Context -> IO a) -> IO a
withTlsPeerParams serverParams clientParams action =
  withTlsPeerConnection serverParams (connectTls clientParams "127.0.0.1") action

withTlsPeerConnection :: ServerParams -> (PortNumber -> IO TlsTransport) -> (TlsTransport -> Context -> IO a) -> IO a
withTlsPeerConnection serverParams connectClient action =
  bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 1
    SockAddrInet port _ <- getSocketName listener
    accepted <- newEmptyMVar
    release <- newEmptyMVar
    stopped <- newEmptyMVar
    tid <- forkIO $ do
      let worker = do
            result <- try $ bracket (fst <$> accept listener) close $ \peer ->
              bracket (contextNew peer serverParams) contextClose $ \ctx -> do
                handshake ctx
                putMVar accepted (Right ctx)
                takeMVar release
            case result of
              Left (err :: SomeException) -> do
                _ <- tryPutMVar accepted (Left err)
                pure ()
              Right () -> pure ()
      worker `finally` putMVar stopped ()
    let finish = do
          _ <- tryPutMVar release ()
          killThread tid
          bounded (takeMVar stopped)
    (bracket (bounded (connectClient port)) tlsClose $ \transport -> do
      result <- bounded (takeMVar accepted)
      peer <- either (ioError . userError . show) pure result
      action transport peer `finally` (bye peer `catch` \(_ :: SomeException) -> pure ()))
      `finally` finish

-- A real TLS peer observes decrypted application bytes even on rejection.
-- The client attempts a protocol write only after connect/identity succeeds.
-- Thus the negative control proves both no returned usable transport and no
-- protocol bytes crossing the TLS boundary; handshake records are excluded.
assertTlsRejectsBeforeProtocol :: ServerParams -> (PortNumber -> IO TlsTransport) -> IO ()
assertTlsRejectsBeforeProtocol serverParams connectClient =
  bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 1
    SockAddrInet port _ <- getSocketName listener
    protocolWrites <- newIORef (0 :: Int)
    protocolBytes <- newIORef (0 :: Int)
    stopped <- newEmptyMVar
    let worker =
          bracket (fst <$> accept listener) close $ \peer ->
            bracket (contextNew peer serverParams) contextClose $ \ctx -> do
              handshake ctx
              let observe = do
                    bytes <- recvData ctx
                    if BS.null bytes then pure () else do
                      modifyIORef' protocolBytes (+ BS.length bytes)
                      observe
              observe
    tid <- forkFinally worker (putMVar stopped)
    let finish = killThread tid >> bounded (readMVar stopped) >> pure ()
        client = bracket (connectClient port) tlsClose $ \transport -> do
          modifyIORef' protocolWrites (+ 1)
          sendMsg transport ExploreNextStep
    (do
      result <- try (timeout 5000000 client)
      _ <- bounded (readMVar stopped)
      writes <- readIORef protocolWrites
      bytes <- readIORef protocolBytes
      putStrLn ("TLS_REJECTION_RECEIPT protocolWrites=" ++ show writes ++ " protocolBytes=" ++ show bytes)
      case result of
        Left (err :: SomeException) -> case fromException err of
          Just PeerTimeout -> assertFailure "TLS peer timed out; identity rejection is inconclusive"
          Nothing -> pure ()
        Right Nothing -> assertFailure "TLS identity did not explicitly fail before timeout"
        Right (Just ()) -> assertFailure "TLS identity accepted and the client sent protocol bytes"
      writes @?= 0
      bytes @?= 0) `finally` finish
