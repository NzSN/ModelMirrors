module TlsPolicySpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.X509 (SignedCertificate)
import Data.X509.CertificateStore (readCertificateStore)
import Data.X509.File (readSignedObject)
import Data.X509.Validation (FailedReason (CacheSaysNo), ValidationCache (..), ValidationCacheResult (..))
import Network.TLS
  ( CertificateChain (CertificateChain), ClientHooks (..), ClientParams (..)
  , Credentials (Credentials), ServerParams (..), Shared (..), credentialLoadX509 )
import Protocol.Core (ClientMessage (ExploreNextStep), MirrorMessage (ExplorerReady))
import Protocol.Format.Json ()
import Protocol.Transport.Core (recvMsg, sendMsg)
import Protocol.Transport.Tls (certFingerprintSHA256, connectTls, connectTlsPinned, mkClientParams, mkServerParams, tlsTransport)
import System.FilePath ((</>))
import System.Process (callProcess)
#ifndef mingw32_HOST_OS
import Data.Bits ((.&.))
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
#endif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TransportTestSupport
  ( assertTlsRejectsBeforeProtocol, bounded, expectFailure, withCerts
  , withTlsPeerConnection, withTlsPeerParams )

spec :: TestTree
spec = testGroup "TlsPolicyNonModel"
  [ testCase "client and server exact 0600 predicate preserves key modes and bytes" $ withCerts testModes
  , testCase "SAN-only rejects CN-only before protocol bytes" $ withCerts testCNOnly
  , testCase "SAN-only accepts correct IP SAN with a different CN" $ withCerts testIPWithoutCN
  , testCase "SAN-only DNS IP wildcard cache and pin controls" $ withCerts testIdentity
  ]

testModes :: FilePath -> IO ()
#ifdef mingw32_HOST_OS
testModes _ = putStrLn "POSIX key-mode matrix is not applicable on Windows"
#else
testModes dir = do
  let key = dir </> "mode.key"
  original <- BS.readFile (dir </> "server.key")
  BS.writeFile key original
  forM_ [0o0000, 0o0400, 0o0600, 0o0640, 0o0644, 0o0700, 0o1600, 0o2600, 0o4600] $ \mode -> do
    setFileMode key mode
    actual <- (.&. 0o7777) . fileMode <$> getFileStatus key
    actual @?= mode
    let serverCheck = mkServerParams (dir </> "server.crt") key (dir </> "ca.crt") >> pure ()
        clientCheck = mkClientParams "127.0.0.1" (dir </> "server.crt") key (dir </> "ca.crt") >> pure ()
    if mode == 0o0600 then serverCheck >> clientCheck else expectFailure serverCheck >> expectFailure clientCheck
    ((.&. 0o7777) . fileMode <$> getFileStatus key) >>= (@?= mode)
    setFileMode key 0o0600
    BS.readFile key >>= (@?= original)
#endif

server :: FilePath -> IO ServerParams
server dir = mkServerParams (dir </> "server.crt") (dir </> "server.key") (dir </> "ca.crt")

client :: FilePath -> String -> IO ClientParams
client dir host = mkClientParams host (dir </> "client.crt") (dir </> "client.key") (dir </> "ca.crt")

variant :: FilePath -> ServerParams -> String -> String -> Maybe String -> IO ServerParams
variant dir base name cn san = do
  let key = dir </> (name ++ ".key")
      request = dir </> (name ++ ".csr")
      cert = dir </> (name ++ ".crt")
      ext = dir </> (name ++ ".ext")
  writeFile ext ("basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" ++ maybe "" (\value -> "subjectAltName=" ++ value ++ "\n") san)
  callProcess "openssl" ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", request, "-subj", "/CN=" ++ cn]
  callProcess "openssl" ["x509", "-req", "-in", request, "-CA", dir </> "ca.crt", "-CAkey", dir </> "ca.key", "-CAcreateserial", "-out", cert, "-days", "1", "-extfile", ext]
  credential <- credentialLoadX509 cert key >>= either (ioError . userError) pure
  pure base { serverShared = (serverShared base) { sharedCredentials = Credentials [credential] } }

testCNOnly :: FilePath -> IO ()
testCNOnly dir = do
  base <- server dir
  cnOnly <- variant dir base "cn-only" "service.example.test" Nothing
  cp <- client dir "service.example.test"
  assertTlsRejectsBeforeProtocol cnOnly (connectTls cp "127.0.0.1")

testIPWithoutCN :: FilePath -> IO ()
testIPWithoutCN dir = do
  base <- server dir
  ip <- variant dir base "ip-correct-cn-wrong" "wrong.example.test" (Just "IP:127.0.0.1")
  cp <- client dir "127.0.0.1"
  withTlsPeerParams ip cp $ \transport peer -> do
    sendMsg transport ExploreNextStep
    -- The raw TLS server still uses the normal adapter for its reply.
    peerTransport <- tlsTransport peer
    (bounded (recvMsg peerTransport) :: IO (Either String ClientMessage)) >>= (@?= Right ExploreNextStep)
    sendMsg peerTransport (ExplorerReady 1 2 3)
    (bounded (recvMsg transport) :: IO (Either String MirrorMessage)) >>= (@?= Right (ExplorerReady 1 2 3))

testIdentity :: FilePath -> IO ()
testIdentity dir = do
  base <- server dir
  let attempt params host = client dir host >>= \cp -> withTlsPeerParams params cp (\_ _ -> pure ())
      reject params host = do
        cp <- client dir host
        assertTlsRejectsBeforeProtocol params (connectTls cp "127.0.0.1")
  dns <- variant dir base "dns" "wrong.example.test" (Just "DNS:service.example.test")
  attempt dns "service.example.test"
  reject dns "wrong.example.test"
  wildcard <- variant dir base "wildcard" "unused.example.test" (Just "DNS:*.example.test")
  attempt wildcard "worker.example.test"
  reject wildcard "nested.worker.example.test"
  reject wildcard "example.test"
  attempt base "127.0.0.1"
  reject base "127.0.0.2"
  cnOnly <- variant dir base "cn-only" "service.example.test" Nothing
  cnIp <- variant dir base "cn-ip" "127.0.0.1" Nothing
  reject cnIp "127.0.0.1"
  wrongIp <- variant dir base "wrong-ip" "127.0.0.1" (Just "IP:127.0.0.2")
  reject wrongIp "127.0.0.1"
  dnsOnly <- variant dir base "dns-only" "127.0.0.1" (Just "DNS:127.0.0.1")
  reject dnsOnly "127.0.0.1"
  ipOnly <- variant dir base "ip-only" "service.example.test" (Just "IP:127.0.0.1")
  reject ipOnly "service.example.test"
  emailDns <- variant dir base "email-dns" "service.example.test" (Just "email:service@example.test")
  reject emailDns "service.example.test"
  emailIp <- variant dir base "email-ip" "127.0.0.1" (Just "email:service@example.test")
  reject emailIp "127.0.0.1"
  ipv6 <- variant dir base "ipv6" "wrong.example.test" (Just "IP:::1")
  attempt ipv6 "::1"
  attempt ipv6 "0:0:0:0:0:0:0:1"
  reject ipv6 "::2"
  cnIpv6 <- variant dir base "cn-ipv6" "::1" Nothing
  reject cnIpv6 "::1"
  mixed <- variant dir base "mixed" "wrong.example.test" (Just "DNS:service.example.test,IP:127.0.0.1")
  attempt mixed "service.example.test"
  attempt mixed "127.0.0.1"
  let startCn = mkServerParams (dir </> "cn-only.crt") (dir </> "cn-only.key") (dir </> "ca.crt")
  expectFailure startCn
  cp <- client dir "127.0.0.1"
  fp <- certFingerprintSHA256 (dir </> "server.crt") >>= maybe (assertFailure "missing fingerprint" >> error "unreachable") pure
  assertBool "fixture fingerprint contains lowercase hex letters" (T.any (`elem` ['a' .. 'f']) fp)
  withTlsPeerConnection base (\port -> connectTlsPinned cp "127.0.0.1" port fp) (\_ _ -> pure ())
  assertTlsRejectsBeforeProtocol base (\port -> connectTlsPinned cp "127.0.0.1" port (T.toUpper fp))
  assertTlsRejectsBeforeProtocol base (\port -> connectTlsPinned cp "127.0.0.1" port (T.replicate 64 (T.singleton '0')))
  cnCp <- client dir "service.example.test"
  cnFp <- certFingerprintSHA256 (dir </> "cn-only.crt") >>= maybe (assertFailure "missing CN fixture fingerprint" >> error "unreachable") pure
  assertTlsRejectsBeforeProtocol cnOnly (\port -> connectTlsPinned cnCp "127.0.0.1" port cnFp)
  -- Trust/cache controls operate on the real hook and original signed leaves.
  store <- readCertificateStore (dir </> "ca.crt") >>= maybe (assertFailure "missing CA store" >> error "unreachable") pure
  queries <- newIORef (0 :: Int)
  let cache result = ValidationCache (\_ _ _ -> modifyIORef' queries (+ 1) >> pure result) (\_ _ _ -> pure ())
      check hostname filename selectedStore selectedCache = do
        params <- client dir hostname
        certs <- readSignedObject (dir </> filename) :: IO [SignedCertificate]
        onServerCertificate (clientHooks params) selectedStore selectedCache (hostname, B8.empty) (CertificateChain certs)
      denied reasons = assertBool "SAN/cache/CA validation must reject" (not (null reasons))
  check "service.example.test" "cn-only.crt" store (cache ValidationCachePass) >>= denied
  check "127.0.0.1" "wrong-ip.crt" store (cache ValidationCachePass) >>= denied
  readIORef queries >>= (@?= 0)
  check "service.example.test" "dns.crt" store (cache (ValidationCacheDenied "test-denied")) >>= (@?= [CacheSaysNo "test-denied"])
  readIORef queries >>= (@?= 1)
  check "service.example.test" "dns.crt" store (cache ValidationCachePass) >>= (@?= [])
  withCerts $ \otherDir -> do
    wrongStore <- readCertificateStore (otherDir </> "ca.crt") >>= maybe (assertFailure "missing wrong CA store" >> error "unreachable") pure
    check "service.example.test" "dns.crt" wrongStore (cache ValidationCacheUnknown) >>= denied
    untrusted <- mkClientParams "service.example.test" (dir </> "client.crt") (dir </> "client.key") (otherDir </> "ca.crt")
    assertTlsRejectsBeforeProtocol dns (connectTls untrusted "127.0.0.1")
