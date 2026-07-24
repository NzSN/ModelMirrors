-- | Bazel-only stub: the real TlsTransportSpec needs the cabal-only TLS
-- modules and openssl; it is excluded from the Bazel test glob.
module TlsTransportSpec (spec, Certs (..), genCerts) where

import Test.Tasty (TestTree, testGroup)

spec :: TestTree
spec = testGroup "TlsTransportSpec" []

-- | Mirrors the real Certs record so modules that import it still
-- compile; 'genCerts' fails at runtime.
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

genCerts :: IO Certs
genCerts = ioError (userError "genCerts: TLS tests are not available in the Bazel build (cabal-only)")
