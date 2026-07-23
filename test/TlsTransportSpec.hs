module TlsTransportSpec (spec, Certs (..), genCerts, withServer) where

import Apalache.Command (generateTraceFiles)
import Apalache.Types (ApalacheConfig (..), TraceGenerationConfig (..))
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString.Char8 qualified as B8
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , SockAddr (..)
  , bind
  , close
  , defaultHints
  , getAddrInfo
  , getSocketName
  , socket
  )
import Protocol.Client (hourClockClient, runClientWithTraces)
import Protocol.Core (MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Registry (RegistryUrl (..), ServiceInfo (..), discoverServices)
import Protocol.Transport.Core (recvMsg, send)
import Protocol.Transport.Tls
  ( TlsTransport
  , certFingerprintSHA256
  , connectTls
  , connectTlsPinned
  , mkClientParams
  , mkServerParams
  , peerCertFingerprintSHA256
  , serveTls
  )
import RegistrySpec (withStubHttp)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

spec :: TestTree
spec = testGroup "TlsTransportSpec"
  [ testMtlsProtocolError
  , testRejectsWrongCaClient
  , testFingerprintMatch
  , testPinnedMismatchRejected
  , testFullSessionOverTls
  , testDiscoverThenPinnedConnect
  ]

data Certs = Certs
  { caCrt :: FilePath
  , serverCrt :: FilePath
  , serverKey :: FilePath
  , clientCrt :: FilePath
  , clientKey :: FilePath
  , rogueCaCrt :: FilePath
  , rogueCrt :: FilePath
  , rogueKey :: FilePath
  }

freePort :: IO PortNumber
freePort = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
  case addrs of
    [] -> error "freePort: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind s (addrAddress addr)
      SockAddrInet p _ <- getSocketName s
      close s
      pure p

-- | Generate a throwaway CA, server cert (IP SAN 127.0.0.1), client cert,
-- and a rogue client cert signed by a different CA, all in a temp dir.
-- Requires openssl on PATH.
genCerts :: IO Certs
genCerts = do
  tmp <- getTemporaryDirectory
  let dir = tmp ++ "/modelmirrors-tls-test"
  createDirectoryIfMissing True dir
  let f name = dir ++ "/" ++ name
  callProcess "openssl"
    [ "req", "-x509", "-newkey", "rsa:2048", "-keyout", f "ca.key"
    , "-out", f "ca.crt", "-days", "1", "-nodes", "-subj", "/CN=ModelMirrors Test CA" ]
  callProcess "openssl"
    [ "req", "-x509", "-newkey", "rsa:2048", "-keyout", f "rogue-ca.key"
    , "-out", f "rogue-ca.crt", "-days", "1", "-nodes", "-subj", "/CN=Rogue CA" ]
  writeFile (f "server.ext") "subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
  writeFile (f "client.ext") "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n"
  let issue name ca ext cn = do
        callProcess "openssl"
          [ "req", "-newkey", "rsa:2048", "-keyout", f (name ++ ".key")
          , "-out", f (name ++ ".csr"), "-nodes", "-subj", "/CN=" ++ cn ]
        callProcess "openssl"
          [ "x509", "-req", "-in", f (name ++ ".csr"), "-CA", f (ca ++ ".crt")
          , "-CAkey", f (ca ++ ".key"), "-CAcreateserial", "-out", f (name ++ ".crt")
          , "-days", "1", "-extfile", f ext ]
        callProcess "chmod" ["600", f (name ++ ".key")]
  issue "server" "ca" "server.ext" "127.0.0.1"
  issue "client" "ca" "client.ext" "test-client"
  issue "rogue" "rogue-ca" "client.ext" "rogue-client"
  pure Certs
    { caCrt = f "ca.crt"
    , serverCrt = f "server.crt"
    , serverKey = f "server.key"
    , clientCrt = f "client.crt"
    , clientKey = f "client.key"
    , rogueCaCrt = f "rogue-ca.crt"
    , rogueCrt = f "rogue.crt"
    , rogueKey = f "rogue.key"
    }

withServer :: Certs -> (PortNumber -> IO a) -> IO a
withServer certs action = do
  port <- freePort
  params <- mkServerParams (serverCrt certs) (serverKey certs) (caCrt certs)
  tid <- forkIO (serveTls params port)
  threadDelay 200000
  r <- action port
  killThread tid
  pure r

testMtlsProtocolError :: TestTree
testMtlsProtocolError = testCase "mTLS session: garbage first message gets protocol_error" $ do
  certs <- genCerts
  withServer certs $ \port -> do
    clientParams <- mkClientParams "127.0.0.1" (clientCrt certs) (clientKey certs) (caCrt certs)
    t <- connectTls clientParams "127.0.0.1" port
    send t (B8.pack "garbage")
    reply <- recvMsg t :: IO (Either String MirrorMessage)
    case reply of
      Right (ProtocolError _) -> pure ()
      other -> assertFailure ("expected protocol_error, got " ++ show other)

testRejectsWrongCaClient :: TestTree
testRejectsWrongCaClient = testCase "client cert from unknown CA is rejected" $ do
  certs <- genCerts
  withServer certs $ \port -> do
    rogueParams <- mkClientParams "127.0.0.1" (rogueCrt certs) (rogueKey certs) (rogueCaCrt certs)
    r <- try (connectTls rogueParams "127.0.0.1" port) :: IO (Either SomeException TlsTransport)
    case r of
      Left _ -> pure ()
      Right _ -> assertFailure "expected TLS handshake to fail"

testFingerprintMatch :: TestTree
testFingerprintMatch = testCase "peer fingerprint matches the server cert file" $ do
  certs <- genCerts
  withServer certs $ \port -> do
    clientParams <- mkClientParams "127.0.0.1" (clientCrt certs) (clientKey certs) (caCrt certs)
    t <- connectTls clientParams "127.0.0.1" port
    expected <- certFingerprintSHA256 (serverCrt certs)
    actual <- peerCertFingerprintSHA256 t
    actual @?= expected

testPinnedMismatchRejected :: TestTree
testPinnedMismatchRejected = testCase "connectTlsPinned rejects on fingerprint mismatch" $ do
  certs <- genCerts
  withServer certs $ \port -> do
    clientParams <- mkClientParams "127.0.0.1" (clientCrt certs) (clientKey certs) (caCrt certs)
    r <- try (connectTlsPinned clientParams "127.0.0.1" port (T.pack "0000dead")) :: IO (Either SomeException TlsTransport)
    case r of
      Left _ -> pure ()
      Right _ -> assertFailure "expected fingerprint mismatch failure"

hcApalacheCfg :: ApalacheConfig
hcApalacheCfg = ApalacheConfig
  { specPath      = "test/specs/HourClock.tla"
  , initPredicate = Nothing
  , nextPredicate = Nothing
  , constInit     = Nothing
  , invariant     = T.pack "TraceComplete"
  , lengthBound   = 13
  , paramVarNames = T.empty
  }

hcTraceConfig :: TraceGenerationConfig
hcTraceConfig = TraceGenerationConfig { numTraces = 1, view = Nothing }

-- | Full session over mTLS: pre-generate HourClock ITF traces with
-- apalache, then replay them through serveTls/connectTls with
-- runClientWithTraces + hourClockClient, ending in all_steps_done.
testFullSessionOverTls :: TestTree
testFullSessionOverTls = testCase "full RegisterTraces session over mTLS" $ do
  genResult <- generateTraceFiles hcApalacheCfg hcTraceConfig
  tracePaths <- case genResult of
    Right (_, ps) | not (null ps) -> pure ps
    Right _ -> assertFailure "no traces generated"
    Left err -> assertFailure ("pre-generate traces error: " ++ show err)
  certs <- genCerts
  withServer certs $ \port -> do
    clientParams <- mkClientParams "127.0.0.1" (clientCrt certs) (clientKey certs) (caCrt certs)
    t <- connectTls clientParams "127.0.0.1" port
    client <- hourClockClient t
    result <- runClientWithTraces client hcApalacheCfg tracePaths
    case result of
      Left err -> assertFailure ("client failed: " ++ T.unpack err)
      Right () -> pure ()

-- | Discovery -> pinned connect: a (stub) registry entry advertises the
-- running TLS server with its cert fingerprint; the client discovers it,
-- connects with connectTlsPinned, and speaks the protocol.
testDiscoverThenPinnedConnect :: TestTree
testDiscoverThenPinnedConnect = testCase "discover via registry, then pinned mTLS connect" $ do
  certs <- genCerts
  Just fp <- certFingerprintSHA256 (serverCrt certs)
  withServer certs $ \serverPort -> do
    let entry = B8.pack $ unlines
          [ "[{\"Service\":{"
          , "\"ID\":\"modelmirrors-test-" ++ show serverPort ++ "\","
          , "\"Address\":\"127.0.0.1\","
          , "\"Port\":" ++ show serverPort ++ ","
          , "\"Meta\":{\"cert-sha256\":\"" ++ T.unpack fp ++ "\"}"
          , "}}]"
          ]
    withStubHttp entry $ \regPort -> do
      infos <- discoverServices (RegistryUrl ("http://127.0.0.1:" ++ show regPort))
      case infos of
        [ServiceInfo _ host port (Just metaFp)] -> do
          clientParams <- mkClientParams host (clientCrt certs) (clientKey certs) (caCrt certs)
          t <- connectTlsPinned clientParams host port metaFp
          send t (B8.pack "garbage")
          reply <- recvMsg t :: IO (Either String MirrorMessage)
          case reply of
            Right (ProtocolError _) -> pure ()
            other -> assertFailure ("expected protocol_error, got " ++ show other)
        other -> assertFailure ("expected one discovered service, got " ++ show other)
