module Main (main) where

import Control.Concurrent (forkIO)
import Control.Monad (unless)
import Data.Text qualified as T
import Protocol.Mirror (run)
import Protocol.Registry (RegistryUrl (..), ServiceInfo (..), heartbeatLoop, registerService)
import Protocol.Transport.Stdio (StdioTransport (..))
import Protocol.Transport.Tcp (serveTcp)
import Protocol.Transport.Tls (certFingerprintSHA256, mkServerParams, serveTls)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import System.Posix.Unistd (getSystemID, nodeName)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--serve", portStr] -> serveTcp (fromIntegral (read portStr :: Int))
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca] -> do
      params <- mkServerParams cert key ca
      serveTls params (fromIntegral (read portStr :: Int))
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca, "--registry", regUrl] -> do
      params <- mkServerParams cert key ca
      let port = fromIntegral (read portStr :: Int)
      fp <- certFingerprintSHA256 cert
      host <- nodeName <$> getSystemID
      let reg = RegistryUrl regUrl
          sid = T.pack ("modelmirrors-" ++ host ++ "-" ++ portStr)
      ok <- registerService reg (ServiceInfo sid host port fp)
      unless ok (hPutStrLn stderr "warning: service registration failed; serving unregistered")
      _ <- forkIO (heartbeatLoop reg sid)
      serveTls params port
    "--server" : _ -> die "usage: ModelMirrors --server <port> --tls --cert <cert> --key <key> --ca <ca> [--registry <url>]"
    _ -> run StdioTransport >> pure ()
