module Protocol.Transport.Tcp
  ( TcpTransport
  , tcpTransport
  , tcpClose
  , serveTcp
  , serveTcpConcurrent
  ) where

import Control.Concurrent (forkIO, newQSem, signalQSem, waitQSem)
import Control.Exception (IOException, SomeException, bracket, try)
import Control.Monad (forever)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , Socket
  , SocketOption (..)
  , accept
  , bind
  , close
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

instance Transport TcpTransport where
  send (TcpTransport h) bs = B8.hPutStrLn h bs >> hFlush h
  recv (TcpTransport h) = do
    r <- try (B8.hGetLine h) :: IO (Either IOException BS.ByteString)
    pure (either (const B8.empty) id r)

-- | Listen on the given port and serve one protocol session per connection,
-- sequentially. A client that drops mid-session logs to stderr and the
-- accept loop continues; the loop only exits via process signals or a
-- listener failure.
serveTcp :: PortNumber -> IO ()
serveTcp port = withSocketsDo $ do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) Nothing (Just (show port))
  case addrs of
    [] -> error ("serveTcp: cannot resolve port " ++ show port)
    (addr : _) -> bracket (openListener addr) close $ \lsock -> forever $ do
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
    (addr : _) -> bracket (openListener addr) close $ \lsock -> forever $ do
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
