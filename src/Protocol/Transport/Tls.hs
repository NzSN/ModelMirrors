module Protocol.Transport.Tls
  ( TlsTransport
  , tlsTransport
  , mkServerParams
  , mkClientParams
  , serveTls
  , connectTls
  , connectTlsPinned
  , certFingerprintSHA256
  , peerCertFingerprintSHA256
  ) where

import Control.Exception (SomeException, bracket, bracketOnError, try)
import Control.Monad (forever)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Hourglass (Elapsed (..), Seconds (..), timeConvert)
import Time.System (timeCurrent)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
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
  , withSocketsDo
  )
import Network.Socket.ByteString qualified as NSB
import Network.TLS
  ( Backend (..)
  , CertificateChain (..)
  , ClientHooks (..)
  , ClientParams (..)
  , Context
  , Credentials (..)
  , ServerHooks (..)
  , ServerParams (..)
  , Shared (..)
  , Supported (..)
  , Version (..)
  , contextNew
  , credentialLoadX509
  , defaultParamsClient
  , defaultParamsServer
  , defaultValidationCache
  , getServerCertificateChain
  , handshake
  , recvData
  , sendData
  , validateClientCertificate
  )
import Data.X509 (SignedCertificate, certValidity, encodeSignedObject, getCertificate)
import Data.X509.CertificateStore (readCertificateStore)
import Data.X509.File (readSignedObject)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Text (Text)
import Data.Text qualified as T
import Protocol.Mirror (run)
import Protocol.Transport.Core (Transport (..))
import System.IO (hPrint, hPutStrLn, stderr)
import System.Posix.Files (fileMode, getFileStatus)

data TlsTransport = TlsTransport Context (IORef BS.ByteString)

tlsTransport :: Context -> IO TlsTransport
tlsTransport ctx = TlsTransport ctx <$> newIORef BS.empty

instance Transport TlsTransport where
  send (TlsTransport ctx _) bs = sendData ctx (LBS.fromStrict (B8.snoc bs '\n'))
  recv t@(TlsTransport ctx ref) = do
    buf <- readIORef ref
    case B8.elemIndex '\n' buf of
      Just i -> do
        writeIORef ref (BS.drop (i + 1) buf)
        pure (BS.take i buf)
      Nothing -> do
        chunk <- recvData ctx
        if BS.null chunk
          then pure B8.empty
          else writeIORef ref (buf <> chunk) >> recv t

-- | Build TLS 1.3-only server parameters with mutual authentication.
-- Fails (via 'ioError') if the credential files cannot be loaded, the CA
-- file contains no certificates, or the private key file is readable by
-- group or other users.
mkServerParams :: FilePath -> FilePath -> FilePath -> IO ServerParams
mkServerParams certFile keyFile caFile = do
  warnIfNearExpiry "server" certFile
  mode <- fileMode <$> getFileStatus keyFile
  if mode .&. 0o077 /= 0
    then ioError (userError ("mkServerParams: key file " ++ keyFile ++ " must not be accessible by group/other (chmod 0600)"))
    else pure ()
  credResult <- credentialLoadX509 certFile keyFile
  cred <- either (ioError . userError . ("mkServerParams: cannot load credentials: " ++)) pure credResult
  mStore <- readCertificateStore caFile
  caStore <- maybe (ioError (userError ("mkServerParams: no certificates in CA file " ++ caFile))) pure mStore
  pure defaultParamsServer
    { serverWantClientCert = True
    , serverShared = (serverShared defaultParamsServer)
        { sharedCredentials = Credentials [cred]
        , sharedCAStore = caStore
        }
    , serverSupported = (serverSupported defaultParamsServer)
        { supportedVersions = [TLS13]
        }
    , serverHooks = (serverHooks defaultParamsServer)
        { onClientCertificate = validateClientCertificate caStore defaultValidationCache
        }
    }

-- | Build TLS 1.3-only client parameters for mutual authentication.
-- The client certificate and key are required (the server requests a
-- client certificate); the CA file is used to validate the server
-- certificate chain and hostname. Fails (via 'ioError') on the same
-- conditions as 'mkServerParams'.
mkClientParams :: HostName -> FilePath -> FilePath -> FilePath -> IO ClientParams
mkClientParams host certFile keyFile caFile = do
  warnIfNearExpiry "client" certFile
  mode <- fileMode <$> getFileStatus keyFile
  if mode .&. 0o077 /= 0
    then ioError (userError ("mkClientParams: key file " ++ keyFile ++ " must not be accessible by group/other (chmod 0600)"))
    else pure ()
  credResult <- credentialLoadX509 certFile keyFile
  cred <- either (ioError . userError . ("mkClientParams: cannot load credentials: " ++)) pure credResult
  mStore <- readCertificateStore caFile
  caStore <- maybe (ioError (userError ("mkClientParams: no certificates in CA file " ++ caFile))) pure mStore
  pure (defaultParamsClient host B8.empty)
    { clientShared = (clientShared (defaultParamsClient host B8.empty))
        { sharedCredentials = Credentials [cred]
        , sharedCAStore = caStore
        }
    , clientSupported = (clientSupported (defaultParamsClient host B8.empty))
        { supportedVersions = [TLS13]
        }
    , clientHooks = (clientHooks (defaultParamsClient host B8.empty))
        { onCertificateRequest = \_ -> pure (Just cred)
        }
    }

-- | Connect to a mirror server over mutually-authenticated TLS 1.3 and
-- return a ready transport (handshake completed).
connectTls :: ClientParams -> HostName -> PortNumber -> IO TlsTransport
connectTls params host port = withSocketsDo $ do
  addrs <- getAddrInfo (Just defaultHints) (Just host) (Just (show port))
  case addrs of
    [] -> ioError (userError ("connectTls: cannot resolve " ++ host ++ ":" ++ show port))
    (addr : _) -> bracketOnError (openConn addr) close $ \sock -> do
      ctx <- contextNew (socketBackend sock) params
      handshake ctx
      tlsTransport ctx
  where
    openConn addr = do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect s (addrAddress addr)
      pure s

-- | SHA-256 fingerprint (lowercase hex) of the first certificate in a
-- PEM file, over the full DER encoding. 'Nothing' if the file contains
-- no certificates.
certFingerprintSHA256 :: FilePath -> IO (Maybe Text)
certFingerprintSHA256 certFile = do
  certs <- readSignedObject certFile :: IO [SignedCertificate]
  pure $ case certs of
    [] -> Nothing
    (c : _) -> Just (T.pack (show (hashWith SHA256 (encodeSignedObject c))))

-- | Days until the first certificate in a PEM file expires (negative
-- if already expired). 'Nothing' if the file contains no certificates.
certDaysRemaining :: FilePath -> IO (Maybe Integer)
certDaysRemaining certFile = do
  certs <- readSignedObject certFile :: IO [SignedCertificate]
  case certs of
    [] -> pure Nothing
    (c : _) -> do
      Elapsed (Seconds now) <- timeCurrent
      let (_, end) = certValidity (getCertificate c)
          Elapsed (Seconds expiry) = timeConvert end
      pure (Just (toInteger ((expiry - now) `quot` 86400)))

-- | Log a warning to stderr when the certificate in a PEM file expires
-- within 7 days (or is already expired).
warnIfNearExpiry :: String -> FilePath -> IO ()
warnIfNearExpiry label certFile = do
  mDays <- certDaysRemaining certFile
  case mDays of
    Just days | days < 7 ->
      hPutStrLn stderr ("warning: " ++ label ++ " certificate " ++ certFile
        ++ (if days < 0 then " is expired" else " expires in " ++ show days ++ " day(s)"))
    _ -> pure ()

-- | SHA-256 fingerprint of the peer's leaf certificate on an
-- established connection. 'Nothing' if the peer presented no
-- certificate.
peerCertFingerprintSHA256 :: TlsTransport -> IO (Maybe Text)
peerCertFingerprintSHA256 (TlsTransport ctx _) = do
  mChain <- getServerCertificateChain ctx
  pure $ case mChain of
    Just (CertificateChain (leaf : _)) ->
      Just (T.pack (show (hashWith SHA256 (encodeSignedObject leaf))))
    _ -> Nothing

-- | Like 'connectTls', but additionally verifies the peer certificate's
-- SHA-256 fingerprint (e.g. from a registry entry) and fails on
-- mismatch.
connectTlsPinned :: ClientParams -> HostName -> PortNumber -> Text -> IO TlsTransport
connectTlsPinned params host port expectedFp = do
  t <- connectTls params host port
  mFp <- peerCertFingerprintSHA256 t
  if mFp == Just expectedFp
    then pure t
    else ioError (userError ("connectTlsPinned: certificate fingerprint mismatch for " ++ host ++ ":" ++ show port))

socketBackend :: Socket -> Backend
socketBackend sock = Backend
  { backendFlush = pure ()
  , backendClose = close sock
  , backendSend = NSB.sendAll sock
  , backendRecv = NSB.recv sock
  }

-- | Like 'serveTcp', but each accepted connection is upgraded to a
-- mutually-authenticated TLS 1.3 session before entering the protocol
-- loop. Handshake failures and client drops are logged to stderr and
-- survived; the loop only exits via process signals or a listener
-- failure.
serveTls :: ServerParams -> PortNumber -> IO ()
serveTls params port = withSocketsDo $ do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) Nothing (Just (show port))
  case addrs of
    [] -> error ("serveTls: cannot resolve port " ++ show port)
    (addr : _) -> bracket (openListener addr) close $ \lsock -> forever $ do
      (conn, _) <- accept lsock
      r <- try $ do
        ctx <- contextNew (socketBackend conn) params
        handshake ctx
        t <- tlsTransport ctx
        _ <- run t
        pure ()
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
