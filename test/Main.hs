module Main (main) where

import qualified Apalache.CommandSpec as CommandSpec
import qualified Apalache.ServerBehaviorSpec as ServerBehaviorSpec
import qualified Apalache.SpecSourceSpec as SpecSourceSpec
import qualified Apalache.TraceSpec as TraceSpec
import qualified Apalache.TypesSpec as TypesSpec
import qualified ClientSpec
import qualified DiffHintSpec
import qualified EngineSpec
import qualified ExploreMirrorSpec
import qualified MainSpec
import qualified MinimalTraceCheckSpec
import qualified MirrorE2ESpec
import qualified MirrorProtocolSpec
import qualified MirrorStepSpec
import qualified Protocol.AsyncJobsSpec
import qualified TcpTransportSpec
import qualified TlsTransportSpec
import qualified RegistrySpec
import qualified ResourceSpec
import qualified ClientReplySpec
import qualified ServerFramingSpec
import qualified StdioTransportSpec
import qualified TlsPolicySpec
import qualified TransportFramingSpec
import System.Environment (getArgs)
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--framing-stdio-child", mode] -> StdioTransportSpec.child mode
    _ -> defaultMain tests

tests :: TestTree
tests = testGroup "ModelMirrors"
  [ ClientSpec.spec
  , DiffHintSpec.spec
  , EngineSpec.spec
  , CommandSpec.spec
  , TraceSpec.spec
  , TypesSpec.spec
  , MainSpec.spec
  , MirrorProtocolSpec.spec
  , MirrorStepSpec.spec
  , Protocol.AsyncJobsSpec.spec
  , MinimalTraceCheckSpec.spec
  , MirrorE2ESpec.spec
  , ServerBehaviorSpec.spec
  , SpecSourceSpec.spec
  , ExploreMirrorSpec.spec
  , TcpTransportSpec.spec
  , TlsTransportSpec.spec
  , RegistrySpec.spec
  , ResourceSpec.spec
  , ClientReplySpec.spec
  , ServerFramingSpec.spec
  , StdioTransportSpec.spec
  , TlsPolicySpec.spec
  , TransportFramingSpec.spec
  ]
