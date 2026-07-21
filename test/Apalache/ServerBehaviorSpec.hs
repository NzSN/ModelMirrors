module Apalache.ServerBehaviorSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
  , ItfTrace
  )
import Apalache.Command (generateTraces)
import Apalache.Rpc.Types (ApalacheSpec (..), mkSpecFromFile)
import Apalache.Rpc.ServerBehavior (ServerStep (..), replayTrace)

import qualified Data.Text as T
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
