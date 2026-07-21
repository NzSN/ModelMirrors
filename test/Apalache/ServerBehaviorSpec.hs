module Apalache.ServerBehaviorSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace
  )
import Apalache.Command (generateTraces)
import Apalache.Explorer
  ( Explorer (..)
  , exploreCheck
  , exploreDispose
  , exploreQueryState
  , newExplorer
  , withApalacheServer
  )
import Apalache.Rpc.Client (assumeTransition, nextStep, rollback)
import Apalache.Rpc.Types
  ( ApalacheServer (..)
  , ApalacheSpec (..)
  , AssumeTransitionParams (..)
  , InvariantKind (..)
  , NextStateParams (..)
  , RollbackParams (..)
  , RpcError (..)
  , mkSpecFromFile
  , mkSpecFromSource
  )
import Apalache.Rpc.ServerBehavior (ServerStep (..), replayTrace)

import qualified Data.Text as T
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertFailure)

spec :: TestTree
spec = testGroup "ServerBehaviorSpec"
  [ testReplayTraces
  , testReplayEvent "nextStep" (T.pack "nextStep") (T.pack "ClientUntilAdvance")
  , testReplayEvent "checkInvariant" (T.pack "checkInvariant") (T.pack "ClientUntilCheck")
  , testReplayEvent "assumeState" (T.pack "assumeState") (T.pack "ClientUntilAssumeStateCall")
  , testReplayEvent "rollback" (T.pack "rollback") (T.pack "ClientUntilRollback")
  , testReplayEvent "DISABLED assumeTransition" (T.pack "assumeTransition") (T.pack "ClientUntilDisabled")
  , testGroup "negative"
    [ testNextStepWithoutAssume
    , testDoubleAssume
    , testInvalidTransitionId
    , testInvalidRollbackSnapshot
    , testCallAfterDispose
    , testMalformedLoadSpec
    , testCheckInvariantAtReady
    ]
  ]

clientSpecFile :: FilePath
clientSpecFile = "specs/ApalacheRPCClient.tla"

protocolSpecFile :: FilePath
protocolSpecFile = "specs/AapalacheRPCProtocol.tla"

baseConfig :: ApalacheConfig
baseConfig = ApalacheConfig
  { specPath      = clientSpecFile
  , initPredicate = Nothing
  , nextPredicate = Just (T.pack "ClientHappyNext")
  , constInit     = Nothing
  , invariant     = T.empty
  , lengthBound   = 9
  , paramVarNames = T.empty
  }

liveSpec :: IO ApalacheSpec
liveSpec = do
  clientSpec <- mkSpecFromFile clientSpecFile
  protoSpec <- mkSpecFromFile protocolSpecFile
  pure $ ApalacheSpec (getSpecSources clientSpec ++ getSpecSources protoSpec)

genTraces :: ApalacheConfig -> TraceGenerationConfig -> IO [ItfTrace]
genTraces cfg tc = do
  result <- generateTraces cfg tc
  case result of
    Left err -> assertFailure $ "generateTraces failed: " ++ show err
    Right (GenerationError msg) -> assertFailure $ "trace generation error: " ++ show msg
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated traces) -> pure traces

checkReplay :: Int -> Either e [ServerStep] -> IO ()
checkReplay n (Left _) =
  assertFailure ("trace " ++ show n ++ ": replayTrace failed")
checkReplay n (Right steps) = do
  assertBool ("trace " ++ show n ++ ": no steps replayed") (not (null steps))
  let bad = filter (not . ssMatch) steps
  assertBool
    ("trace " ++ show n ++ ": " ++ show (length bad) ++ " divergent step(s):\n"
      ++ unlines (map (\s -> "  " ++ T.unpack (ssMethod s) ++ ": " ++ T.unpack (ssNote s)) bad))
    (null bad)

testReplayTraces :: TestTree
testReplayTraces = testCase "replay generated traces against live explorer server" $ do
  traces <- genTraces
    baseConfig { invariant = T.pack "ClientReplayTrace" }
    (TraceGenerationConfig { numTraces = 3, view = Just (T.pack "ClientView") })
  spec' <- liveSpec
  results <- mapM (replayTrace spec' [T.pack "Inv"] [T.pack "View"]) traces
  mapM_ (uncurry checkReplay) (zip [(1 :: Int) ..] results)

testReplayEvent :: String -> T.Text -> T.Text -> TestTree
testReplayEvent name method inv = testCase ("replay trace exercising " ++ name) $ do
  traces <- genTraces
    baseConfig { invariant = inv }
    (TraceGenerationConfig { numTraces = 1, view = Nothing })
  spec' <- liveSpec
  results <- mapM (replayTrace spec' [T.pack "Inv"] [T.pack "View"]) traces
  mapM_ (uncurry checkReplay) (zip [(1 :: Int) ..] results)
  let exercised = [ () | Right steps <- results
                       , s <- steps
                       , ssMethod s == method
                       , ssObsResult s == T.pack "ok" ]
  assertBool ("no replayed step exercised " ++ name) (not (null exercised))

callTimeoutSec :: Int
callTimeoutSec = 20 * 1000 * 1000

expectNoSuccess :: String -> IO (Either RpcError a) -> IO ()
expectNoSuccess name action = do
  r <- timeout callTimeoutSec action
  case r of
    Nothing -> pure ()
    Just (Left _) -> pure ()
    Just (Right _) -> assertFailure (name ++ ": expected error or hang, got success")

expectProtocolError :: String -> IO (Either RpcError a) -> IO ()
expectProtocolError name action = do
  r <- timeout callTimeoutSec action
  case r of
    Just (Left (RpcProtocolError _ _)) -> pure ()
    Just (Left err) -> assertFailure (name ++ ": expected protocol error, got " ++ show err)
    Nothing -> assertFailure (name ++ ": expected protocol error, call hung")
    Just (Right _) -> assertFailure (name ++ ": expected protocol error, got success")

mustExplorer :: ApalacheServer -> IO Explorer
mustExplorer server = do
  spec' <- liveSpec
  r <- newExplorer server spec' [T.pack "Inv"] [T.pack "View"]
  case r of
    Left err -> assertFailure ("could not load spec: " ++ show err)
    Right expl -> pure expl

testNextStepWithoutAssume :: TestTree
testNextStepWithoutAssume = testCase "nextStep without assumeTransition does not succeed" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    expectNoSuccess "nextStep without assume"
      (nextStep (explClient expl) (NextStateParams (explSessionId expl)))

testDoubleAssume :: TestTree
testDoubleAssume = testCase "double assumeTransition does not succeed" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    let params = AssumeTransitionParams (explSessionId expl) 0 True (Just 10)
    r1 <- assumeTransition (explClient expl) params
    case r1 of
      Left err -> assertFailure ("first assumeTransition failed: " ++ show err)
      Right _ -> expectNoSuccess "double assumeTransition"
        (assumeTransition (explClient expl) params)

testInvalidTransitionId :: TestTree
testInvalidTransitionId = testCase "assumeTransition with invalid id is a protocol error" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    expectProtocolError "assumeTransition(999)"
      (assumeTransition (explClient expl) (AssumeTransitionParams (explSessionId expl) 999 True (Just 10)))

testInvalidRollbackSnapshot :: TestTree
testInvalidRollbackSnapshot = testCase "rollback to unknown snapshot is a protocol error" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    expectProtocolError "rollback(999)"
      (rollback (explClient expl) (RollbackParams (explSessionId expl) 999))

testCallAfterDispose :: TestTree
testCallAfterDispose = testCase "session call after disposeSpec is a protocol error" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    d <- exploreDispose expl
    case d of
      Left err -> assertFailure ("disposeSpec failed: " ++ show err)
      Right _ -> expectProtocolError "query after dispose" (exploreQueryState expl)

testMalformedLoadSpec :: TestTree
testMalformedLoadSpec = testCase "loadSpec of malformed spec is a protocol error" $
  withApalacheServer Nothing $ \server ->
    expectProtocolError "malformed loadSpec"
      (newExplorer server (mkSpecFromSource (T.pack "garbage not a spec")) [] [])

testCheckInvariantAtReady :: TestTree
testCheckInvariantAtReady = testCase "checkInvariant before any step succeeds (server behavior)" $
  withApalacheServer Nothing $ \server -> do
    expl <- mustExplorer server
    r <- exploreCheck expl 0 StateInvariant
    case r of
      Left err -> assertFailure ("checkInvariant at ready failed: " ++ show err)
      Right _ -> pure ()
