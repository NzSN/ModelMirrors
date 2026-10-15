module ServerFramingSpec (spec) where

import Apalache.Command (ApalacheResult (..))
import Apalache.Types (ApalacheConfig (..), ValidateResult (SpecValid))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Network.Socket.ByteString qualified as NBS
import Protocol.AsyncJobs (newJobStoreWith, queryJob)
import Protocol.Core (ClientMessage (..), JobOutcome (..), JobPhase (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Mirror (runAsyncSession)
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TransportTestSupport (bounded, withTcpPeer)

cfg :: ApalacheConfig
cfg = ApalacheConfig "test/specs/HourClock.tla" Nothing Nothing Nothing (T.pack "TraceComplete") 1 T.empty

spec :: TestTree
spec = testGroup "ServerFramingNonModel"
  [ testCase "server fake backend normal async request reply and owned cleanup" $
      withTcpPeer $ \server peer -> do
        store <- newJobStoreWith 1 (\_ _ _ _ -> pure (Right (ApalacheResult ExitSuccess "ok" "")))
        done <- newEmptyMVar
        _ <- forkIO (try (runAsyncSession server store) >>= putMVar done)
        write peer (RegisterValidateAsync cfg 1 Nothing)
        accepted <- readReply peer
        jid <- case accepted of
          Right (JobAccepted job _) -> pure job
          other -> assertFailure (show other) >> error "unreachable"
        write peer (AwaitJob jid Nothing)
        readReply peer >>= (@?= Right (JobResult jid (JobValidateDone SpecValid)))
        NBS.sendAll peer (BS.pack [93, 10])
        _ <- readReply peer
        result <- bounded (takeMVar done)
        case result of
          Left (err :: SomeException) -> assertFailure (show err)
          Right _ -> pure ()
  , testCase "oversized server request cancels only that session's fake job" $
      withTcpPeer $ \server peer -> withTcpPeer $ \otherServer otherPeer -> do
        entered <- newEmptyMVar
        otherEntered <- newEmptyMVar
        release <- newEmptyMVar
        otherRelease <- newEmptyMVar
        let blocking started gate _ dir _ _ = do
              putMVar started dir
              _ <- readMVar gate
              pure (Right (ApalacheResult ExitSuccess "ok" ""))
        store <- newJobStoreWith 1 (blocking entered release)
        otherStore <- newJobStoreWith 1 (blocking otherEntered otherRelease)
        done <- newEmptyMVar
        otherDone <- newEmptyMVar
        _ <- forkIO (try (runAsyncSession server store) >>= putMVar done)
        _ <- forkIO (try (runAsyncSession otherServer otherStore) >>= putMVar otherDone)
        write peer (RegisterValidateAsync cfg 1 Nothing)
        _ <- readReply peer
        runDir <- bounded (takeMVar entered)
        write otherPeer (RegisterValidateAsync cfg 1 Nothing)
        otherAccepted <- readReply otherPeer
        otherJid <- case otherAccepted of
          Right (JobAccepted job _) -> pure job
          other -> assertFailure (show other) >> error "unreachable"
        _ <- bounded (takeMVar otherEntered)
        NBS.sendAll peer (BS.replicate 65536 120)
        result <- bounded (takeMVar done)
        case result of
          Left (_ :: SomeException) -> pure ()
          Right _ -> assertFailure "expected exceptional framing refusal"
        NBS.recv peer 1 >>= (@?= BS.empty)
        case runDir of
          Nothing -> assertFailure "fake job did not receive its owned run directory"
          Just dir -> doesDirectoryExist dir >>= (@?= False)
        (phase, _) <- queryJob otherStore otherJid
        phase @?= JobRunning
        putMVar otherRelease ()
        write otherPeer (AwaitJob otherJid Nothing)
        readReply otherPeer >>= (@?= Right (JobResult otherJid (JobValidateDone SpecValid)))
        NBS.sendAll otherPeer (BS.pack [93, 10])
        _ <- readReply otherPeer
        otherResult <- bounded (takeMVar otherDone)
        case otherResult of
          Left (err :: SomeException) -> assertFailure (show err)
          Right _ -> pure ()
  ]
  where
    write peer message = NBS.sendAll peer (LBS.toStrict (A.encode message) <> BS.singleton 10)
    readReply peer = bounded $ do
      bytes <- line peer []
      pure (A.eitherDecodeStrict bytes :: Either String MirrorMessage)
    line peer acc = do
      byte <- NBS.recv peer 1
      assertBool "server must reply before EOF" (not (BS.null byte))
      if byte == BS.singleton 10 then pure (BS.pack (reverse acc)) else line peer (BS.head byte : acc)
