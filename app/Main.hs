module Main (main) where

import Control.Concurrent (forkIO)
import Control.Monad (unless)
import Data.Text qualified as T
import Protocol.Mirror (run)
import Protocol.Registry (RegistryUrl (..), ServiceInfo (..), heartbeatLoop, registerService)
import Protocol.Transport.Stdio (StdioTransport (..))
import Protocol.Transport.Tcp (serveTcp)
import Protocol.Transport.Tls (certFingerprintSHA256, mkServerParams, serveTls, serveTlsConcurrent)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import System.Posix.Unistd (getSystemID, nodeName)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--serve", portStr] -> serveTcp (fromIntegral (read portStr :: Int))
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca] ->
      serveOne portStr cert key ca Nothing 4
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca, "--jobs", nStr] ->
      serveOne portStr cert key ca Nothing (read nStr)
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca, "--registry", regUrl] ->
      serveOne portStr cert key ca (Just regUrl) 4
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca, "--registry", regUrl, "--jobs", nStr] ->
      serveOne portStr cert key ca (Just regUrl) (read nStr)
    ["--server", portStr, "--tls", "--cert", cert, "--key", key, "--ca", ca, "--jobs", nStr, "--registry", regUrl] ->
      serveOne portStr cert key ca (Just regUrl) (read nStr)
    "--server" : _ -> die "usage: ModelMirrors --server <port> --tls --cert <cert> --key <key> --ca <ca> [--registry <url>] [--jobs <n>]"
    _ -> run StdioTransport >> pure ()

serveOne :: String -> FilePath -> FilePath -> FilePath -> Maybe String -> Int -> IO ()
serveOne portStr cert key ca mReg jobs = do
  params <- mkServerParams cert key ca
  let port = fromIntegral (read portStr :: Int)
  case mReg of
    Nothing -> pure ()
    Just regUrl -> do
      fp <- certFingerprintSHA256 cert
      host <- nodeName <$> getSystemID
      let reg = RegistryUrl regUrl
          sid = T.pack ("modelmirrors-" ++ host ++ "-" ++ portStr)
      ok <- registerService reg (ServiceInfo sid host port fp)
      unless ok (hPutStrLn stderr "warning: service registration failed; serving unregistered")
      _ <- forkIO (heartbeatLoop reg sid)
      pure ()
  if jobs <= 1
    then serveTls params port
    else serveTlsConcurrent jobs params port
