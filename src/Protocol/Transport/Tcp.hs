module Protocol.Transport.Tcp
  ( TcpTransport
  , tcpTransport
  , connectTcp
  , tcpClose
  , serveTcp
  , serveTcpOn
  , serveTcpConcurrent
  , pickListenerAddr
  ) where

import Control.Concurrent (forkIO, newQSem, signalQSem, waitQSem)
import Control.Exception (IOException, SomeException, bracket, try)
import Control.Monad (forever)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , Family (AF_INET)
  , HostName
  , PortNumber
  , Socket
  , SocketOption (..)
  , accept
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , listen
  , setSocketOption
  , socket
  , socketToHandle
  , withSocketsDo
  )
import Protocol.Mirror (run)
import Protocol.Transport.Core (Transport (..))
import System.IO
  ( Handle
  , IOMode (..)
  , hClose
  , hFlush
  , hPrint
  , stderr
  )

newtype TcpTransport = TcpTransport Handle

tcpTransport :: Socket -> IO TcpTransport
tcpTransport sock = TcpTransport <$> socketToHandle sock ReadWriteMode

-- | Close the underlying handle. Note: 'close' on the original
-- 'Socket' is a no-op after 'tcpTransport' (socketToHandle takes
-- ownership of the file descriptor), so connections must be closed
-- through this function for the peer to see a disconnect.
tcpClose :: TcpTransport -> IO ()
tcpClose (TcpTransport h) = hClose h

-- | Pick the listener address from 'getAddrInfo' results, preferring IPv4.
-- On Windows, @AI_PASSIVE@ resolves the IPv6 wildcard first and the socket
-- would be IPv6-only (refusing IPv4 clients); on POSIX the IPv4 wildcard
-- already comes first, so this is a no-op in practice.
pickListenerAddr :: [AddrInfo] -> AddrInfo
pickListenerAddr addrs = case filter ((== AF_INET) . addrFamily) addrs of
  (a : _) -> a
  []      -> case addrs of
    (a : _) -> a
    []      -> error "pickListenerAddr: no addresses"

-- | Connect to a mirror server over plain TCP and return a ready transport
-- (the client-side counterpart of 'serveTcp'/'serveTcpConcurrent').
connectTcp :: HostName -> PortNumber -> IO TcpTransport
connectTcp host port = withSocketsDo $ do
  addrs <- getAddrInfo (Just defaultHints) (Just host) (Just (show port))
  case addrs of
    [] -> error ("connectTcp: cannot resolve " ++ host ++ ":" ++ show port)
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect s (addrAddress addr)
      tcpTransport s

instance Transport TcpTransport where
  send (TcpTransport h) bs = B8.hPutStrLn h bs >> hFlush h
  recv (TcpTransport h) = do
    r <- try (B8.hGetLine h) :: IO (Either IOException BS.ByteString)
    pure (either (const B8.empty) id r)

-- | Listen on the given port and serve one protocol session per connection,
-- sequentially. A client that drops mid-session logs to stderr and the
-- accept loop continues; the loop only exits via process signals or a
-- listener failure. Binds the all-interfaces wildcard address.
serveTcp :: PortNumber -> IO ()
serveTcp = serveTcpOn ""

-- | Like 'serveTcp', but binds only the given host address (e.g.
-- @127.0.0.1@) instead of the wildcard.
serveTcpOn :: HostName -> PortNumber -> IO ()
serveTcpOn host0 port = do
  let mhost = if null host0 then Nothing else Just host0
  withSocketsDo $ do
    addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) mhost (Just (show port))
    case addrs of
      [] -> error ("serveTcp: cannot resolve port " ++ show port)
      _  -> bracket (openListener (pickListenerAddr addrs)) close $ \lsock -> forever $ do
        (conn, _) <- accept lsock
        t <- tcpTransport conn
        r <- try (run t)
        case r of
          Left (e :: SomeException) -> hPrint stderr e
          Right _ -> pure ()
        close conn
    where
      openListener addr = do
        s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
        setSocketOption s ReuseAddr 1
        bind s (addrAddress addr)
        listen s 5
        pure s

-- | Like 'serveTcp', but dispatches each accepted connection to a worker
-- thread, bounded to at most @jobs@ concurrent sessions (excess
-- connections wait in the accept backlog until a slot frees). Worker
-- failures are logged to stderr and never take down the accept loop.
serveTcpConcurrent :: Int -> PortNumber -> IO ()
serveTcpConcurrent jobs port = withSocketsDo $ do
  sem <- newQSem jobs
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) Nothing (Just (show port))
  case addrs of
    [] -> error ("serveTcpConcurrent: cannot resolve port " ++ show port)
    _  -> bracket (openListener (pickListenerAddr addrs)) close $ \lsock -> forever $ do
      (conn, _) <- accept lsock
      waitQSem sem
      _ <- forkIO $ do
        r <- try $ do
          t <- tcpTransport conn
          _ <- run t
          pure ()
        case r of
          Left (e :: SomeException) -> hPrint stderr e
          Right _ -> pure ()
        close conn
        signalQSem sem
      pure ()
  where
    openListener addr = do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption s ReuseAddr 1
      bind s (addrAddress addr)
      listen s 5
      pure s
