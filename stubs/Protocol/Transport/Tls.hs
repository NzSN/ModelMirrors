-- | Bazel-only stub for the cabal-only Protocol.Transport.Tls (the tls
-- dependency chain does not build under rules_haskell). Same API surface
-- as used by app/Main.hs and the transport-gated tests (which default to
-- no-op under Bazel); every function fails at runtime.
module Protocol.Transport.Tls
  ( ServerParams
  , ClientParams
  , TlsTransport
  , mkServerParams
  , mkClientParams
  , serveTls
  , serveTlsConcurrent
  , connectTls
  , certFingerprintSHA256
  ) where

import Data.Text (Text)
import Network.Socket (HostName, PortNumber)
import Protocol.Transport.Core (Transport (..))

data ServerParams = ServerParamsStub
data ClientParams = ClientParamsStub
data TlsTransport = TlsTransportStub

instance Transport TlsTransport where
  send _ _ = unsupported "send"
  recv _ = unsupported "recv"

unsupported :: String -> IO a
unsupported fn = ioError (userError (fn ++ ": TLS is not available in the Bazel build (cabal-only)"))

mkServerParams :: FilePath -> FilePath -> FilePath -> IO ServerParams
mkServerParams _ _ _ = unsupported "mkServerParams"

mkClientParams :: HostName -> FilePath -> FilePath -> FilePath -> IO ClientParams
mkClientParams _ _ _ _ = unsupported "mkClientParams"

serveTls :: ServerParams -> PortNumber -> IO ()
serveTls _ _ = unsupported "serveTls"

serveTlsConcurrent :: Int -> ServerParams -> PortNumber -> IO ()
serveTlsConcurrent _ _ _ = unsupported "serveTlsConcurrent"

connectTls :: ClientParams -> HostName -> PortNumber -> IO TlsTransport
connectTls _ _ _ = unsupported "connectTls"

certFingerprintSHA256 :: FilePath -> IO (Maybe Text)
certFingerprintSHA256 _ = unsupported "certFingerprintSHA256"

