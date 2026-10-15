module ClientReplySpec (spec) where

import Apalache.Types (ApalacheConfig (..), TraceGenerationConfig (..), ValidateResult (SpecValid))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Protocol.Client qualified as Client
import Protocol.Core (ClientMessage (..), JobId (..), JobKind (..), JobOutcome (..), JobPhase (..), MirrorMessage (..))
import Protocol.Format.Json ()
import Protocol.Transport.Core (Transport (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

data Script = Script (IORef [BS.ByteString]) (IORef [BS.ByteString])
instance Transport Script where
  send (Script _ writes) bs = atomicModifyIORef' writes (\xs -> (xs ++ [bs], ()))
  recv (Script replies _) = atomicModifyIORef' replies $ \case
    [] -> ([], BS.empty)
    x : xs -> (xs, x)

cfg :: ApalacheConfig
cfg = ApalacheConfig "spec.tla" Nothing Nothing Nothing T.empty 1 T.empty

jid, other :: JobId
jid = JobId (T.pack "owned")
other = JobId (T.pack "another")

script :: [MirrorMessage] -> IO (Script, IO [Either String ClientMessage])
script replies = do
  input <- newIORef (map (LBS.toStrict . A.encode) replies)
  writes <- newIORef []
  pure (Script input writes, map A.eitherDecodeStrict <$> readIORef writes)

mustFail :: Either T.Text a -> IO ()
mustFail (Left _) = pure ()
mustFail (Right _) = assertFailure "expected local reply correlation failure"

spec :: TestTree
spec = testGroup "ClientReplyNonModel"
  [ testCase "submission validates accepted kind before any await" $ do
      (t, writes) <- script [JobAccepted jid GenTracesJob]
      Client.runClientValidateAsync t cfg 1 Nothing >>= mustFail
      writes >>= (@?= [Right (RegisterValidateAsync cfg 1 Nothing)])
      (t', writes') <- script [JobAccepted jid ValidateJob]
      Client.runClientGenTracesAsync t' cfg (TraceGenerationConfig 1 Nothing) Nothing Nothing >>= mustFail
      writes' >>= (@?= [Right (RegisterGenTracesAsync cfg (TraceGenerationConfig 1 Nothing) Nothing Nothing)])
  , testCase "wrong poll and await IDs fail with no follow-up writes" $ do
      mapM_ (\reply -> do
        (t, writes) <- script [reply]
        Client.pollJob t jid >>= mustFail
        writes >>= (@?= [Right (QueryJob jid)])
        (t', writes') <- script [reply]
        Client.awaitJob t' jid Nothing >>= mustFail
        writes' >>= (@?= [Right (AwaitJob jid Nothing)]))
        [JobStatus other JobRunning, JobStatus other JobDone, JobResult other (JobValidateDone SpecValid)]
  , testCase "cancel accepts matching status and every legal terminal result" $ do
      mapM_ (\reply -> do
        (t, writes) <- script [reply]
        Client.cancelJob t jid >>= (@?= Right ())
        writes >>= (@?= [Right (CancelJob jid)]))
        [ JobStatus jid JobCancelled, JobStatus jid JobUnknown
        , JobResult jid (JobValidateDone SpecValid)
        , JobResult jid (JobGenTracesDone [] [])
        , JobResult jid (JobInfraError (T.pack "failed")) ]
      mapM_ (\reply -> do
        (t, writes) <- script [reply]
        Client.cancelJob t jid >>= mustFail
        writes >>= (@?= [Right (CancelJob jid)]))
        [JobStatus other JobCancelled, JobResult other (JobValidateDone SpecValid)]
  , testCase "matching async validate retains normal result and exact flow" $ do
      (t, writes) <- script [JobAccepted jid ValidateJob, JobStatus jid JobRunning, JobResult jid (JobValidateDone SpecValid)]
      Client.runClientValidateAsync t cfg 1 Nothing >>= (@?= Right SpecValid)
      writes >>= (@?= [Right (RegisterValidateAsync cfg 1 Nothing), Right (AwaitJob jid Nothing), Right (AwaitJob jid Nothing)])
  ]
