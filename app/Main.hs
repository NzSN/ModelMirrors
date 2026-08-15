module Main (main) where

import Apalache.Rpc.Types (ApalacheSpec (..))
import Apalache.Types (ApalacheConfig (..), ValidateResult (..))
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (unless)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Protocol.Client (runClientValidate)
import Protocol.Mirror (run)
import Protocol.Registry (RegistryUrl (..), ServiceInfo (..), heartbeatLoop, registerService)
import Protocol.Transport.Core (Transport)
import Protocol.Transport.Stdio (StdioTransport (..))
import Protocol.Transport.Tcp (connectTcp, serveTcp, tcpClose)
import Protocol.Transport.Tls (certFingerprintSHA256, connectTls, connectTlsPinned, mkClientParams, mkServerParams, serveTls, serveTlsConcurrent, tlsClose)
import Protocol.ValidateOpts (ValidateOpts (..), parseValidateOpts)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), die, exitSuccess, exitWith)
import System.FilePath (takeFileName)
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
    "validate" : rest -> validateCli rest
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

-- | Client-role CLI for the validate-only path: reads the spec (and its inline
-- dependencies) from the local filesystem, sends them to a remote mirror,
-- prints the verdict, and exits 0 (valid), 1 (invalid), or 2 (infrastructure
-- failure). The server never sees the client's filesystem.
validateCli :: [String] -> IO ()
validateCli argv = do
  opts <- either die pure (parseValidateOpts argv)
  contents <- mapM TIO.readFile (voSpec opts : voDeps opts)
  let spec = ApalacheSpec contents
      cfg  = ApalacheConfig
        { specPath      = takeFileName (voSpec opts)
        , initPredicate = T.pack <$> voInit opts
        , nextPredicate = T.pack <$> voNext opts
        , constInit     = T.pack <$> voCinit opts
        , invariant     = maybe T.empty T.pack (voInv opts)
        , lengthBound   = voBound opts
        , paramVarNames = T.empty
        }
  res <- try (bracket (validateTransport opts) closeTransport $ \st -> case st of
        SomeTransport t _ -> runClientValidate t cfg (voBound opts) (Just spec))
    :: IO (Either SomeException (Either Text ValidateResult))
  case res of
    Left e -> hPutStrLn stderr (displayException e) >> exitWith (ExitFailure 2)
    Right (Left err) -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
    Right (Right SpecValid) -> putStrLn "VALID" >> exitSuccess
    Right (Right (SpecInvalid o)) -> putStrLn "INVALID" >> TIO.putStr o >> exitWith (ExitFailure 1)

-- | A transport together with its close action, hiding the concrete transport
-- type so plain TCP and mTLS share one code path.
data SomeTransport = forall t. Transport t => SomeTransport t (t -> IO ())

-- | Connect over plain TCP (default) or mutually-authenticated TLS.
-- @parseValidateOpts@ guarantees @--tls@ carries cert/key/ca.
validateTransport :: ValidateOpts -> IO SomeTransport
validateTransport opts = case voTls opts of
  False -> do
    t <- connectTcp (voHost opts) (fromIntegral (voPort opts))
    pure (SomeTransport t tcpClose)
  True -> case (voCert opts, voKey opts, voCa opts) of
    (Just cert, Just key, Just ca) -> do
      params <- mkClientParams (voHost opts) cert key ca
      t <- case voPin opts of
        Nothing -> connectTls params (voHost opts) (fromIntegral (voPort opts))
        Just fp -> connectTlsPinned params (voHost opts) (fromIntegral (voPort opts)) (T.pack fp)
      pure (SomeTransport t tlsClose)
    _ -> die "--tls requires --cert, --key, and --ca"

closeTransport :: SomeTransport -> IO ()
closeTransport (SomeTransport t f) = f t
