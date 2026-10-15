module TransportFramingSpec (spec) where

import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Network.Socket (ShutdownCmd (ShutdownSend), shutdown)
import Network.Socket.ByteString qualified as NBS
import Network.TLS (bye, contextClose, recvData, sendData)
import Protocol.Core (ClientMessage (ExploreNextStep), MirrorMessage (ExplorerReady))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport (..), recvMsg, sendMsg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import TransportTestSupport (bounded, expectFailure, withCerts, withTcpPeer, withTlsPeer)

newtype Recording = Recording (IORef [BS.ByteString])
instance Transport Recording where
  send (Recording ref) bs = modifyIORef' ref (++ [bs])
  recv _ = pure BS.empty

spec :: TestTree
spec = testGroup "TransportFramingNonModel"
  [ testCase "final encoded byte boundaries and unchanged JSON" testEncoded
  , testCase "TCP raw receive boundaries split UTF8 coalescing and EOF" testTcpReceive
  , testCase "TCP direct send refuses oversized or raw LF before writing" testTcpSend
  , testCase "mTLS framing direct send and receive actual records" $ withCerts testTls
  ]

testEncoded :: IO ()
testEncoded = do
  ref <- newIORef []
  let transport = Recording ref
  mapM_ (\n -> do
    let value = T.replicate (n - 2) (T.singleton 'x')
    sendMsg transport value
    last <$> readIORef ref >>= (\bs -> BS.length bs @?= n)) [65534, 65535]
  before <- readIORef ref
  expectFailure (sendMsg transport (T.replicate 65534 (T.singleton 'x')))
  readIORef ref >>= (@?= before)
  let escaped = T.pack "\"\\\nλ"
  sendMsg transport escaped
  last <$> readIORef ref >>= (@?= LBS.toStrict (A.encode escaped))
  -- Multibyte text: 32766 lambdas + one ASCII + JSON quotes = 65535.
  sendMsg transport (T.replicate 32766 (T.singleton 'λ') <> T.singleton 'x')
  last <$> readIORef ref >>= (\bs -> BS.length bs @?= 65535)
  expectFailure (sendMsg transport (T.replicate 32767 (T.singleton 'λ')))

testTcpReceive :: IO ()
testTcpReceive = do
  withTcpPeer $ \transport peer -> do
    NBS.sendAll peer (BS.replicate 65535 120)
    NBS.sendAll peer (B8.pack "\nnext\n")
    bounded (recv transport) >>= (@?= BS.replicate 65535 120)
    bounded (recv transport) >>= (@?= B8.pack "next")
    NBS.sendAll peer (BS.pack [34, 206])
    NBS.sendAll peer (BS.pack [187, 34, 10])
    (bounded (recvMsg transport) :: IO (Either String T.Text)) >>= (@?= Right (T.singleton 'λ'))
    NBS.sendAll peer (BS.pack [34, 255, 34, 10])
    malformed <- bounded (recvMsg transport) :: IO (Either String T.Text)
    assertBool "invalid UTF8 is rejected by the full-frame JSON decoder" (either (const True) (const False) malformed)
    shutdown peer ShutdownSend
    bounded (recv transport) >>= (@?= BS.empty)
  withTcpPeer $ \transport peer -> do
    NBS.sendAll peer (BS.replicate 65536 120)
    -- Peer remains open: the 65536th byte must fail without awaiting EOF.
    expectFailure (recv transport)
    NBS.recv peer 1 >>= (@?= BS.empty)
    expectFailure (recv transport)
  withTcpPeer $ \transport peer -> do
    NBS.sendAll peer (B8.pack "{}")
    shutdown peer ShutdownSend
    expectFailure (recv transport)

testTcpSend :: IO ()
testTcpSend = withTcpPeer $ \transport peer -> do
  expectFailure (send transport (BS.replicate 65536 120))
  expectFailure (send transport (B8.pack "{}\n{}"))
  sendMsg transport ExploreNextStep
  bytes <- bounded (NBS.recv peer 4096)
  bytes @?= LBS.toStrict (A.encode ExploreNextStep) <> B8.pack "\n"
  mapM_ (\n -> do
    send transport (BS.replicate n 120)
    bytes' <- gather peer (n + 1)
    bytes' @?= BS.replicate n 120 <> B8.pack "\n") [65534, 65535]
  sendMsg transport (T.replicate 65533 (T.singleton 'x'))
  gather peer 65536 >>= (@?= BS.singleton 34 <> BS.replicate 65533 120 <> BS.pack [34, 10])
  expectFailure (sendMsg transport (T.replicate 65534 (T.singleton 'x')))
  send transport (B8.pack "after")
  gather peer 6 >>= (@?= B8.pack "after\n")
  where
    gather peer n = bounded (go n [])
      where
        go 0 chunks = pure (BS.concat (reverse chunks))
        go remaining chunks = do
          bs <- NBS.recv peer remaining
          assertBool "peer remains connected" (not (BS.null bs))
          go (remaining - BS.length bs) (bs : chunks)

testTls :: FilePath -> IO ()
testTls dir = do
  withTlsPeer dir $ \transport peer -> do
    expectFailure (send transport (BS.replicate 65536 120))
    expectFailure (send transport (B8.pack "{}\n{}"))
    sendMsg transport ExploreNextStep
    bounded (recvData peer) >>= (@?= LBS.toStrict (A.encode ExploreNextStep) <> B8.pack "\n")
    sendMsg transport (T.replicate 65533 (T.singleton 'x'))
    gatherTls peer 65536 >>= (@?= BS.singleton 34 <> BS.replicate 65533 120 <> BS.pack [34, 10])
    expectFailure (sendMsg transport (T.replicate 65534 (T.singleton 'x')))
    send transport (B8.pack "after")
    bounded (recvData peer) >>= (@?= B8.pack "after\n")
    sendData peer (A.encode (ExplorerReady 1 2 3) <> LBS.singleton 10)
    (bounded (recvMsg transport) :: IO (Either String MirrorMessage)) >>= (@?= Right (ExplorerReady 1 2 3))
    sendData peer (LBS.fromStrict (B8.pack "first\nsecond\n"))
    recv transport >>= (@?= B8.pack "first")
    recv transport >>= (@?= B8.pack "second")
    sendData peer (LBS.fromStrict (BS.pack [34, 206]))
    sendData peer (LBS.fromStrict (BS.pack [187, 34, 10]))
    (recvMsg transport :: IO (Either String T.Text)) >>= (@?= Right (T.singleton 'λ'))
    sendData peer (LBS.fromStrict (BS.replicate 65535 120))
    sendData peer (LBS.singleton 10)
    bounded (recv transport) >>= (@?= BS.replicate 65535 120)
    bye peer
    bounded (recv transport) >>= (@?= BS.empty)
  withTlsPeer dir $ \transport peer -> do
    sendData peer (LBS.fromStrict (BS.replicate 65536 120))
    expectFailure (recv transport)
    expectFailure (recv transport)
  withTlsPeer dir $ \transport peer -> do
    sendData peer (LBS.fromStrict (B8.pack "{}"))
    bye peer
    expectFailure (recv transport)
  withTlsPeer dir $ \transport peer -> do
    sendData peer (LBS.fromStrict (B8.pack "{}"))
    contextClose peer
    expectFailure (recv transport)
  where
    gatherTls peer n = bounded (go n [])
      where
        go 0 chunks = pure (BS.concat (reverse chunks))
        go remaining chunks = do
          bytes <- recvData peer
          assertBool "TLS peer remains connected" (not (BS.null bytes))
          assertBool "TLS records stay within remaining frame" (BS.length bytes <= remaining)
          go (remaining - BS.length bytes) (bytes : chunks)
