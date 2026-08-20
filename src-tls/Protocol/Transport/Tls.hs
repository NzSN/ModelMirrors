module Protocol.Transport.Tls
  ( TlsTransport
  , tlsTransport
  , tlsClose
  , mkServerParams
  , mkClientParams
  , serveTls
  , serveTlsConcurrent
  , serveTlsOn
  , serveTlsConcurrentOn
  , connectTls
  , connectTlsPinned
  , certFingerprintSHA256
  , peerCertFingerprintSHA256
  ) where

import Control.Concurrent (forkIO, newQSem, signalQSem, threadDelay, waitQSem)
import Control.Exception (SomeException, bracket, bracketOnError, catch, try)
import Control.Monad (forever, unless, when)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
#ifndef mingw32_HOST_OS
import Data.Bits ((.&.))
#endif
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
#ifdef mingw32_HOST_OS
import Data.Word (Word8)
#endif
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
#ifdef mingw32_HOST_OS
import Network.Socket (mkSocket, socketToHandle, touchSocket, unsafeFdSocket)
#endif
import qualified Network.Socket.ByteString as NBS
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
  , bye
  , handshake
  , recvData
  , sendData
  , validateClientCertificate
  )
import Data.X509
  ( Certificate
  , SignedCertificate
  , certExtensions
  , certIssuerDN
  , certPubKey
  , certSubjectDN
  , certValidity
  , AltName (..)
  , ExtSubjectAltName (..)
  , encodeSignedObject
  , extensionGet
  , getCertificate
  )
import Data.X509.CertificateStore (CertificateStore, listCertificates, readCertificateStore)
import Data.X509.File (readSignedObject)
import Data.X509.Validation (SignatureVerification (..), verifySignedSignature)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Text (Text)
import Data.Text qualified as T
import Protocol.Mirror (run)
import Protocol.Transport.Core (Transport (..))
import Protocol.Transport.Tcp (pickListenerAddr)
import System.IO (hFlush, hPrint, hPutStrLn, stderr)
#ifdef mingw32_HOST_OS
import System.IO (BufferMode (NoBuffering), Handle, IOMode (..), hClose, hSetBuffering)
#endif
#ifndef mingw32_HOST_OS
import System.Posix.Files (fileMode, getFileStatus)
#endif

data TlsTransport = TlsTransport Context (IORef BS.ByteString)

tlsTransport :: Context -> IO TlsTransport
tlsTransport ctx = TlsTransport ctx <$> newIORef BS.empty

-- | Best-effort graceful close: send @close_notify@, ignoring the error if the
-- peer has already dropped the connection. The underlying socket is released
-- by the process on exit.
tlsClose :: TlsTransport -> IO ()
tlsClose (TlsTransport ctx _) = bye ctx `catch` \(_ :: SomeException) -> pure ()

instance Transport TlsTransport where
  send (TlsTransport ctx _) bs = do
    when tlsRxDebug (dbgLn ("TXPLAIN " ++ show (BS.length bs) ++ " " ++ B8.unpack (B8.take 90 bs)))
    sendData ctx (LBS.fromStrict (B8.snoc bs '\n'))
  recv t@(TlsTransport ctx ref) = do
    buf <- readIORef ref
    case B8.elemIndex '\n' buf of
      Just i -> do
        let line = BS.take i buf
        when tlsRxDebug (dbgLn ("RXPLAIN " ++ show (BS.length line) ++ " " ++ B8.unpack (B8.take 90 line)))
        writeIORef ref (BS.drop (i + 1) buf)
        pure line
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
#ifndef mingw32_HOST_OS
  mode <- fileMode <$> getFileStatus keyFile
  if mode .&. 0o077 /= 0
    then ioError (userError ("mkServerParams: key file " ++ keyFile ++ " must not be accessible by group/other (chmod 0600)"))
    else pure ()
#endif
  credResult <- credentialLoadX509 certFile keyFile
  cred <- either (ioError . userError . ("mkServerParams: cannot load credentials: " ++)) pure credResult
  mStore <- readCertificateStore caFile
  caStore <- maybe (ioError (userError ("mkServerParams: no certificates in CA file " ++ caFile))) pure mStore
  validateServerCertChain caStore certFile
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
        -- Require a client certificate: reject handshakes where the
        -- client presents none (default allows unverified clients through).
        , onUnverifiedClientCert = pure False
        }
    }

-- | Validate the server certificate chain against a CA store before any
-- listener is bound: the leaf must carry a non-empty Subject Alternative Name
-- (DNS or IP), and the whole chain must cryptographically verify against (and
-- conclude at) a certificate trusted by the CA store. This is a structural,
-- hostname-independent check (the server may bind a wildcard/unspecified
-- address and does not know its advertised hostname at startup).
--
-- If the validation API proves awkward for a particular deployment, this is
-- the single place to relax; do not silently drop the SAN requirement.
validateServerCertChain :: CertificateStore -> FilePath -> IO ()
validateServerCertChain caStore certFile = do
  certs <- readSignedObject certFile :: IO [SignedCertificate]
  case certs of
    [] -> ioError (userError ("mkServerParams: server certificate file " ++ certFile ++ " contains no certificates"))
    (leaf : _) -> do
      let leafCert = getCertificate leaf
      case sanEntries leafCert of
        [] -> ioError (userError ("mkServerParams: server certificate " ++ certFile ++ " has no Subject Alternative Name (DNS or IP)"))
        _ -> pure ()
      unless (chainValidates caStore certs)
        (ioError (userError ("mkServerParams: server certificate chain in " ++ certFile ++ " does not validate against the CA file")))

-- | List the leaf's Subject Alternative Name entries (DNS or IP, or others).
sanEntries :: Certificate -> [AltName]
sanEntries cert = case (extensionGet (certExtensions cert) :: Maybe ExtSubjectAltName) of
  Just (ExtSubjectAltName alts) -> alts
  Nothing -> []

-- | Verify that every certificate in @chain@ (leaf first) is signed by a
-- certificate that is either elsewhere in the chain or trusted by @caStore@.
-- @verifySignedSignature child signerPubKey@ checks the child's signature with
-- the signer's public key. A leaf-only server chain (the common case, where the
-- CA is kept out of the served file) is verified when its signer is found in
-- @caStore@.
chainValidates :: CertificateStore -> [SignedCertificate] -> Bool
chainValidates caStore chain =
  not (null chain) && all ok (zip chain [0 :: Int ..])
  where
    trusted = listCertificates caStore
    nTrusted = length trusted
    allCerts = trusted ++ chain
    ok (child, i) =
      let childCert = getCertificate child
          selfIdx = nTrusted + i
          candidates = [ sc
                       | (j, sc) <- zip [0 ..] allCerts
                       , j /= selfIdx
                       , certSubjectDN (getCertificate sc) == certIssuerDN childCert
                       ]
      in case candidates of
           (signer : _) -> verifySignedSignature child (certPubKey (getCertificate signer)) == SignaturePass
           [] -> False


-- | Build TLS 1.3-only client parameters for mutual authentication.
-- The client certificate and key are required (the server requests a
-- client certificate); the CA file is used to validate the server
-- certificate chain and hostname. Fails (via 'ioError') on the same
-- conditions as 'mkServerParams'.
mkClientParams :: HostName -> FilePath -> FilePath -> FilePath -> IO ClientParams
mkClientParams host certFile keyFile caFile = do
  warnIfNearExpiry "client" certFile
#ifndef mingw32_HOST_OS
  mode <- fileMode <$> getFileStatus keyFile
  if mode .&. 0o077 /= 0
    then ioError (userError ("mkClientParams: key file " ++ keyFile ++ " must not be accessible by group/other (chmod 0600)"))
    else pure ()
#endif
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
      bracketOnError (mkTlsBackend sock) backendClose $ \backend -> do
        ctx <- contextNew backend params
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

-- | Debug switch. With @MODELMIRRORS_DEBUG_TLS=1@, the Transport
-- instance logs plaintext lines (TXPLAIN/RXPLAIN); on Windows the TLS
-- backend also hex-dumps every backend read (TLSRX) and write (TLSTX).
tlsRxDebug :: Bool
tlsRxDebug = unsafePerformIO $ (== Just "1") <$> lookupEnv "MODELMIRRORS_DEBUG_TLS"
{-# NOINLINE tlsRxDebug #-}
#ifdef mingw32_HOST_OS
tlsTxDebug :: Bool
tlsTxDebug = unsafePerformIO $ (== Just "1") <$> lookupEnv "MODELMIRRORS_DEBUG_TLS"
{-# NOINLINE tlsTxDebug #-}
#endif

-- | Debug output helper: line + flush (stderr is block-buffered when
-- redirected, which would otherwise swallow the dumps on long-running
-- processes).
dbgLn :: String -> IO ()
dbgLn s = hPutStrLn stderr s >> hFlush stderr

#ifdef mingw32_HOST_OS
hexDump :: Int -> BS.ByteString -> String
hexDump lim bs = take (lim * 3) (concatMap (\b -> printfHex b ++ " ") (BS.unpack (BS.take lim bs)))
  where
    printfHex :: Word8 -> String
    printfHex b = let h = "0123456789abcdef" in [h !! fromIntegral (b `div` 16), h !! fromIntegral (b `mod` 16)]
#endif

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

-- | Build the TLS backend for an already-connected 'Socket'.
--
-- On Windows, GHC's Handle write path silently drops the first
-- application-data record after the TLS 1.3 handshake (the 'BS.hPut'
-- + 'hFlush' completes but the bytes never reach the peer), while raw
-- 'NBS.sendAll' delivers reliably.  Reads still go through the Handle
-- (GHC's IO-manager ReadFile path) to avoid the intermittent @WSAEINVAL@
-- that raw 'recv' on Windows can raise.  The 'Socket' is reconstructed
-- from the FD via 'mkSocket' after 'socketToHandle' has invalidated the
-- original; 'touchSocket' keeps the original alive so the FD is not
-- prematurely closed.
--
-- On POSIX the plain single-socket backend is used (the pre-dual-backend
-- behaviour); the backend-level hexdump debug switches are therefore not
-- available there.
mkTlsBackend :: Socket -> IO Backend
#ifdef mingw32_HOST_OS
mkTlsBackend sock = do
  fd <- unsafeFdSocket sock
  bracketOnError (socketToHandle sock ReadWriteMode) hClose $ \h -> do
    hSetBuffering h NoBuffering
    writeSock <- mkSocket fd
    touchSocket sock
    pure (tlsBackend writeSock h)
#else
mkTlsBackend sock = pure Backend
  { backendFlush = pure ()
  , backendClose = close sock
  , backendSend = NBS.sendAll sock
  , backendRecv = NBS.recv sock
  }
#endif

#ifdef mingw32_HOST_OS
-- | Dual backend over a raw 'Socket' (writes) and a 'Handle' (reads).
-- See 'mkTlsBackend' for why this split exists on Windows only.
tlsBackend :: Socket -> Handle -> Backend
tlsBackend writeSock h = Backend
  { backendFlush = pure ()
  , backendClose = hClose h
  , backendSend = \bs -> do
      when tlsTxDebug (dbgLn ("TLSTX " ++ show (BS.length bs) ++ " " ++ hexDump 48 bs))
      NBS.sendAll writeSock bs
      when tlsTxDebug (dbgLn ("TLSTX_DONE " ++ show (BS.length bs)))
  , backendRecv = recvAll h
  }
  where
    recvAll hnd n = do
      chunks <- loop n []
      let bs = BS.concat (reverse chunks)
      when tlsRxDebug $
        dbgLn ("TLSRX req=" ++ show n ++ " got=" ++ show (BS.length bs) ++ " hex=" ++ hexDump 80 bs)
      pure bs
      where
        loop 0 acc = pure acc
        loop left acc = do
          r <- BS.hGet hnd left
          if BS.null r
            then pure acc
            else loop (left - BS.length r) (r : acc)
#endif

-- | Like 'serveTcp', but each accepted connection is upgraded to a
-- mutually-authenticated TLS 1.3 session before entering the protocol
-- loop. Handshake failures and client drops are logged to stderr and
-- survived; the loop only exits via process signals or a listener
-- failure. Binds the all-interfaces wildcard address ('AI_PASSIVE' with
-- no host).
serveTls :: ServerParams -> PortNumber -> IO ()
serveTls = serveTlsWith Nothing

-- | Like 'serveTls', but binds only the given host address (e.g.
-- @127.0.0.1@). Kept for callers that need to restrict the listener.
serveTlsOn :: HostName -> ServerParams -> PortNumber -> IO ()
serveTlsOn host = serveTlsWith (Just host)

serveTlsWith :: Maybe HostName -> ServerParams -> PortNumber -> IO ()
serveTlsWith mhost params port = withSocketsDo $ do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) mhost (Just (show port))
  case addrs of
    [] -> error ("serveTls: cannot resolve port " ++ show port)
    _ -> bracket (openListener (pickListenerAddr addrs)) close $ \lsock -> forever $ do
      (conn, _) <- accept lsock
      r <- try $ bracket (mkTlsBackend conn) backendClose $ \b -> do
        ctx <- contextNew b params
        handshake ctx
        t <- tlsTransport ctx
        _ <- run t
        threadDelay 50000
        tlsClose t
        pure ()
      case r of
        Left (e :: SomeException) -> hPrint stderr e
        Right _ -> pure ()
  where
    openListener addr = do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption s ReuseAddr 1
      bind s (addrAddress addr)
      listen s 5
      pure s

-- | Like 'serveTls', but dispatches each accepted connection to a worker
-- thread (bounded to @jobs@ concurrent sessions). The TLS handshake
-- happens in the worker, so a slow or stalled handshake never blocks the
-- accept loop. Worker failures are logged to stderr and survived. Binds
-- the all-interfaces wildcard address.
serveTlsConcurrent :: Int -> ServerParams -> PortNumber -> IO ()
serveTlsConcurrent jobs = serveTlsConcurrentOn jobs ""

-- | Like 'serveTlsConcurrent', but binds only the given host address
-- (e.g. @127.0.0.1@).
serveTlsConcurrentOn :: Int -> HostName -> ServerParams -> PortNumber -> IO ()
serveTlsConcurrentOn jobs host0 params port = do
  let mhost = if null host0 then Nothing else Just host0
  withSocketsDo $ do
    sem <- newQSem jobs
    addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) mhost (Just (show port))
    case addrs of
      [] -> error ("serveTlsConcurrent: cannot resolve port " ++ show port)
      _ -> bracket (openListener (pickListenerAddr addrs)) close $ \lsock -> forever $ do
        (conn, _) <- accept lsock
        waitQSem sem
        _ <- forkIO $ do
          r <- try $ bracket (mkTlsBackend conn) backendClose $ \b -> do
            ctx <- contextNew b params
            handshake ctx
            t <- tlsTransport ctx
            _ <- run t
            threadDelay 50000
            tlsClose t
            pure ()
          case r of
            Left (e :: SomeException) -> hPrint stderr e
            Right _ -> pure ()
          signalQSem sem
        pure ()
    where
      openListener addr = do
        s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
        setSocketOption s ReuseAddr 1
        bind s (addrAddress addr)
        listen s 5
        pure s
