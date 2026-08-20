module Main (main) where

import Apalache.Rpc.Types (ApalacheSpec (..))
import Apalache.Types (ApalacheConfig (..), ValidateResult (..))
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, bracket, displayException, finally, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Protocol.Client (runClientValidate)
import Protocol.Discover (DiscoveredPeer (..), candidateFingerprint, tryCandidates)
import Protocol.Mirror (run)
import Protocol.Registry
  ( RegistryUrl (..)
  , ServiceInfo (..)
  , deregisterService
  , discoverServices
  , heartbeatLoop
  , registerService
  )
import Protocol.ServerOpts (ServerOpts (..), parseServeCli, parseServerOpts)
import Protocol.Transport.Core (Transport)
import Protocol.Transport.Stdio (StdioTransport (..))
import Protocol.Transport.Tcp (connectTcp, serveTcpOn, tcpClose)
import Protocol.Transport.Tls
  ( certFingerprintSHA256
  , connectTls
  , connectTlsPinned
  , mkClientParams
  , mkServerParams
  , serveTls
  , serveTlsOn
  , serveTlsConcurrentOn
  , tlsClose
  )
import Protocol.ValidateOpts (ValidateOpts (..), parseValidateOpts)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), die, exitSuccess, exitWith)
import System.FilePath (takeFileName)
import System.IO (hPutStrLn, stderr)
#ifndef mingw32_HOST_OS
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)
import System.Posix.Unistd (getSystemID, nodeName)
#endif

main :: IO ()
main = do
  args <- getArgs
  case args of
    "--serve" : rest -> serveCli rest
    "--server" : rest -> serveOne =<< (either die pure (parseServerOpts rest))
    "validate" : rest -> validateCli rest
    _ -> run StdioTransport >> pure ()

--------------------------------------------------------------------------------
-- Server CLI
--------------------------------------------------------------------------------

-- | @--serve@ accepts @<port>@ or @<port> --bind <addr>@.
serveCli :: [String] -> IO ()
serveCli argv = do
  (port, mBind) <- either die pure (parseServeCli argv)
  serveTcpOn (maybe "" id mBind) (fromIntegral port)

-- | Advertised hostname used as the registry registration address.
advertisedHost :: IO String
#ifdef mingw32_HOST_OS
advertisedHost = maybe "unknown" id <$> lookupEnv "COMPUTERNAME"
#else
advertisedHost = nodeName <$> getSystemID
#endif

-- | Start the mTLS server. Registers with a registry (explicit @--registry@
-- flag wins over the @MODELMIRRORS_REGISTRY@ env var), forks the heartbeat,
-- and deregisters best-effort on shutdown (signals and normal exits on POSIX;
-- normal exits only on Windows, where signal handlers are not installed).
serveOne :: ServerOpts -> IO ()
serveOne opts = do
  params <- mkServerParams (soCert opts) (soKey opts) (soCa opts)
  let port = fromIntegral (soPort opts)
      bindAddr = maybe "" id (soBind opts)
  mRegUrl <- case soRegistry opts of
    Just u -> pure (Just u)
    Nothing -> lookupEnv "MODELMIRRORS_REGISTRY"
  mReg <- case mRegUrl of
    Nothing -> pure Nothing
    Just regUrl -> do
      -- A discoverable server must be able to publish its pin.
      mFp <- certFingerprintSHA256 (soCert opts)
      fp <- case mFp of
        Just f -> pure f
        Nothing -> die ("cannot register with registry: no certificate found in " ++ soCert opts)
      host <- advertisedHost
      let reg = RegistryUrl regUrl
          sid = T.pack ("modelmirrors-" ++ host ++ "-" ++ show (soPort opts))
      ok <- registerService reg (ServiceInfo sid host port (Just fp))
      if ok
        then do
          _ <- forkIO (heartbeatLoop reg sid)
          pure (Just (reg, sid))
        else do
          hPutStrLn stderr "warning: service registration failed; serving unregistered"
          pure Nothing
        -- We deliberately do NOT deregister here: registration itself failed.
  let serve = case soJobs opts of
        n | n <= 1 -> if null bindAddr then serveTls params port else serveTlsOn bindAddr params port
          | otherwise -> serveTlsConcurrentOn n bindAddr params port
  case mReg of
    Nothing -> serve
    Just (reg, sid) -> do
#ifndef mingw32_HOST_OS
      -- POSIX: deregister and exit cleanly on SIGINT/SIGTERM. On Windows we
      -- rely on the 'finally' below (signal-synchronous cleanup is not
      -- portable there).
      _ <- installHandler sigINT  (Catch (cleanupHandler reg sid)) Nothing
      _ <- installHandler sigTERM (Catch (cleanupHandler reg sid)) Nothing
#endif
      serve `finally` deregisterService reg sid

#ifndef mingw32_HOST_OS
-- | Best-effort deregistration on a caught signal, then clean exit.
cleanupHandler :: RegistryUrl -> Text -> IO ()
cleanupHandler reg sid = do
  deregisterService reg sid
  exitSuccess
#endif

--------------------------------------------------------------------------------
-- Validate-only CLI
--------------------------------------------------------------------------------

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
  case voRegistry opts of
    Just url -> do
      mSt <- registryTransport opts (RegistryUrl url)
      case mSt of
        Nothing -> exitWith (ExitFailure 2)
        Just st -> reportValidate $ try (bracket (pure st) closeTransport (\st' -> case st' of
          SomeTransport t _ -> runClientValidate t cfg (voBound opts) (Just spec)))
    Nothing ->
      reportValidate $ try (bracket (validateDirectTransport opts) closeTransport (\st' -> case st' of
        SomeTransport t _ -> runClientValidate t cfg (voBound opts) (Just spec)))

-- | Run a validation session and map the result to an exit code.
reportValidate :: IO (Either SomeException (Either Text ValidateResult)) -> IO ()
reportValidate act = do
  res <- act
  case res of
    Left e -> hPutStrLn stderr (displayException e) >> exitWith (ExitFailure 2)
    Right (Left err) -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
    Right (Right SpecValid) -> putStrLn "VALID" >> exitSuccess
    Right (Right (SpecInvalid o)) -> putStrLn "INVALID" >> TIO.putStr o >> exitWith (ExitFailure 1)

-- | Discover mirrors via @--registry@, try each candidate in order, and
-- return the first transport that connects. Per-candidate failures are
-- caught and the next candidate is tried. If every candidate fails (or the
-- registry returned no candidates), print a clear error and return 'Nothing'
-- (the caller then exits 2).
registryTransport :: ValidateOpts -> RegistryUrl -> IO (Maybe SomeTransport)
registryTransport opts regUrl = do
  infos <- discoverServices regUrl
  let peers = map (\si -> DiscoveredPeer (siHost si) (siPort si) (siCertFingerprint si)) infos
      explicitPin = T.pack <$> voPin opts
  res <- tryCandidates peers $ \peer -> do
    let host = dpHost peer
    r <- try $ do
      params <- mkClientParams host (needCert opts) (needKey opts) (needCa opts)
      let mfp = candidateFingerprint explicitPin peer
      t <- case mfp of
        Just fp -> connectTlsPinned params host (dpPort peer) fp
        Nothing -> connectTls params host (dpPort peer)
      pure (SomeTransport t tlsClose)
    pure $ case r of
      Right st -> Right st
      Left (e :: SomeException) -> Left (displayException e)
  case res of
    Right st -> pure (Just st)
    Left errs -> do
      hPutStrLn stderr ("registry discovery failed: " ++ errs)
      pure Nothing

needCert :: ValidateOpts -> FilePath
needCert o = case voCert o of
  Just c -> c
  Nothing -> error "registry requires --cert (parser invariant violated)"
needKey :: ValidateOpts -> FilePath
needKey o = case voKey o of
  Just k -> k
  Nothing -> error "registry requires --key (parser invariant violated)"
needCa :: ValidateOpts -> FilePath
needCa o = case voCa o of
  Just c -> c
  Nothing -> error "registry requires --ca (parser invariant violated)"

-- | A transport together with its close action, hiding the concrete transport
-- type so plain TCP and mTLS share one code path.
data SomeTransport = forall t. Transport t => SomeTransport t (t -> IO ())

-- | Connect over plain TCP (default) or mutually-authenticated TLS.
-- @parseValidateOpts@ guarantees @--tls@ carries cert/key/ca.
validateDirectTransport :: ValidateOpts -> IO SomeTransport
validateDirectTransport opts = case voTls opts of
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
