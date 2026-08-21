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
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain $ testGroup "ModelMirrors"
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
  ]