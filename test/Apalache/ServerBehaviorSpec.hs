module Apalache.ServerBehaviorSpec (spec) where

import Apalache.Types
  ( ApalacheConfig (..)
  , TraceGenerationConfig (..)
  , TraceGenerationResult (..)
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
  ]

clientSpecFile :: FilePath
clientSpecFile = "specs/ApalacheRPCClient.tla"

protocolSpecFile :: FilePath
protocolSpecFile = "specs/AapalacheRPCProtocol.tla"

config :: ApalacheConfig
config = ApalacheConfig
  { specPath      = clientSpecFile
  , initPredicate = Nothing
  , nextPredicate = Just (T.pack "ClientHappyNext")
  , constInit     = Nothing
  , invariant     = T.pack "ClientReplayTrace"
  , lengthBound   = 9
  , paramVarNames = T.empty
  }

traceConfig :: TraceGenerationConfig
traceConfig = TraceGenerationConfig
  { numTraces = 3
  , view      = Just (T.pack "ClientView")
  }

testReplayTraces :: TestTree
testReplayTraces = testCase "replay generated traces against live explorer server" $ do
  traceResult <- generateTraces config traceConfig
  case traceResult of
    Left err -> assertFailure $ "generateTraces failed: " ++ show err
    Right (GenerationError msg) -> assertFailure $ "trace generation error: " ++ show msg
    Right (TracesGenerated []) -> assertFailure "no traces generated"
    Right (TracesGenerated traces) -> do
      clientSpec <- mkSpecFromFile clientSpecFile
      protoSpec <- mkSpecFromFile protocolSpecFile
      let liveSpec = ApalacheSpec (getSpecSources clientSpec ++ getSpecSources protoSpec)
      results <- mapM (replayTrace liveSpec [T.pack "Inv"] [T.pack "View"]) traces
      mapM_ checkReplay (zip [(1 :: Int) ..] results)
  where
    checkReplay (n, Left err) =
      assertFailure ("trace " ++ show n ++ ": replayTrace failed: " ++ show err)
    checkReplay (n, Right steps) = do
      assertBool ("trace " ++ show n ++ ": no steps replayed") (not (null steps))
      let bad = filter (not . ssMatch) steps
      assertBool
        ("trace " ++ show n ++ ": " ++ show (length bad) ++ " divergent step(s):\n"
          ++ unlines (map (\s -> "  " ++ T.unpack (ssMethod s) ++ ": " ++ T.unpack (ssNote s)) bad))
        (null bad)
