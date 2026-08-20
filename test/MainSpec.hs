module MainSpec (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (IOException, SomeException, try, bracket, displayException)
import Control.Monad (void)
import Data.ByteString.Char8 qualified as B8
import Data.Either (isLeft)
import Data.List (isInfixOf, isSuffixOf)
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , PortNumber
  , SockAddr (..)
  , accept
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , getSocketName
  , listen
  , socket
  )
import Protocol.Discover (DiscoveredPeer (..), candidateFingerprint, tryCandidates)
import Protocol.Mirror (MirrorStep, mirrorStepActionName, run)
import Protocol.ServerOpts (ServerOpts (..), parseServeCli, parseServerOpts)
import Protocol.Transport.Tcp (serveTcpConcurrent, tcpTransport)
import Protocol.Transport.Tls (mkServerParams, serveTlsConcurrent)
import Protocol.ValidateOpts (ValidateOpts (..), parseValidateOpts)
import System.Directory (doesFileExist, doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createProcess
  , proc
  , readProcess
  , readProcessWithExitCode
  , terminateProcess
  , waitForProcess
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TlsTransportSpec (Certs (..), genCerts)

spec :: TestTree
spec = testGroup "MainSpec"
  [ testEndToEnd
  , testCounterEndToEnd
  , testParseValidateOpts
  , testValidateCliClosedPort
  , testValidateCliTcpValid
  , testValidateCliTcpInvalid
  , testValidateCliTls
  , testValidateCliProc2ProcTcpValid
  , testValidateCliProc2ProcTcpInvalid
  , testValidateCliProc2ProcTcpDeps
  , testValidateCliProc2ProcTls
  , testValidateCliProc2ProcTcpOverCap
  , testServerOpts
  , testValidateRegistryOpts
  , testDiscoverLogic
  ]

findMirrorBinary :: IO FilePath
findMirrorBinary = findCabalBinary

findCabalBinary :: IO FilePath
findCabalBinary = do
  exists <- doesDirectoryExist "dist-newstyle/build"
  if not exists
    then error "dist-newstyle/build not found"
    else do
      raw <- lines <$> readProcess "find"
        [ "dist-newstyle/build"
        , "-name", "ModelMirrors"
        , "-type", "f"
        , "-executable"
        ] ""
      let candidates = filter
            (\p -> "/x/ModelMirrors/build/ModelMirrors/ModelMirrors" `isSuffixOf` p)
            raw
      case candidates of
        (p : _) -> do
          exists' <- doesFileExist p
          if exists' then pure p
          else error $ "binary listed by find but not accessible: " ++ p
        _ -> error $ "ModelMirrors binary not found. Found: " ++ show raw

findMirrorBinaryOrSkip :: IO (Maybe FilePath)
findMirrorBinaryOrSkip = do
  result <- try findMirrorBinary
  case result of
    Left (e :: SomeException) -> do
      putStrLn $ "SKIP: " ++ displayException e
      pure Nothing
    Right p -> pure (Just p)

testEndToEnd :: TestTree
testEndToEnd = testCase "DeterministicCounter end-to-end" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      let
        input = B8.pack $ unlines $ registerLine : stateLines

        registerLine =
          "{\"proto_step\":\"register\",\"apalacheConfig\":{\"specPath\":\"test/specs/DeterministicCounter.tla\",\"initPredicate\":null,\"nextPredicate\":null,\"constInit\":null,\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"paramVars\":\"\"},\"traceConfig\":{\"numTraces\":1,\"view\":null}}"

        stateLines = concat $ replicate 2
          [ mkReport 0 "init" 0
          , mkReport 1 "inc"  1
          , mkReport 2 "inc"  2
          , mkReport 3 "inc"  3
          , mkReport 4 "inc"  4
          , mkReport 5 "inc"  5
          ]

        mkReport :: Int -> String -> Int -> String
        mkReport c a s = concat
          [ "{\"proto_step\":\"report_state\",\"state\":{"
          , "\"count\":{\"#bigint\":\"", show c, "\"}"
          , ",\"action_taken\":\"", a, "\""
          , ",\"step_count\":{\"#bigint\":\"", show s, "\"}"
          , "}}"
          ]

      putStrLn ""
      putStrLn "  --- mirror stdout ---"

      (exitCode, stdout, _stderr) <- readProcessWithExitCode bin [] (B8.unpack input)

      case exitCode of
        ExitFailure n -> assertFailure $ "mirror exited " ++ show n ++ "\nstdout: " ++ stdout
        ExitSuccess -> pure ()

      let outputLines = lines stdout
      mapM_ (putStrLn . ("  " ++)) outputLines

      putStrLn ""
      putStrLn "  --- protocol trace ---"

      let annotated = zipWith annotate [1 :: Int ..] outputLines
      mapM_ putStrLn annotated

      putStrLn ""

      let
        traceMsgs =
          [ "initial_state"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok"
          ]
        expected = ["spec_validated"] ++ traceMsgs ++ traceMsgs ++ ["all_steps_done"]

      assertBool ("expected " ++ show (length expected) ++ " messages, got " ++ show (length outputLines))
        (length outputLines == length expected)

      let checkMsg ls n step = do
            let line = ls !! (n - 1)
                needle = "\"proto_step\":\"" ++ step ++ "\""
            assertBool ("msg " ++ show n ++ ": expected proto_step=" ++ show step ++ "\n  got: " ++ take 120 line)
              (needle `isInfixOf` line)

      sequence_ $ zipWith (checkMsg outputLines) [1 :: Int ..] expected

testCounterEndToEnd :: TestTree
testCounterEndToEnd = testCase "Counter end-to-end" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      let
        registerLine =
          "{\"proto_step\":\"register\",\"apalacheConfig\":{\"specPath\":\"test/specs/Counter.tla\",\"initPredicate\":null,\"nextPredicate\":null,\"constInit\":\"CInit\",\"invariant\":\"TraceComplete\",\"lengthBound\":5,\"paramVars\":\"parameters\"},\"traceConfig\":{\"numTraces\":1,\"view\":null}}"

        mkReport c a s = concat
          [ "{\"proto_step\":\"report_state\",\"state\":{"
          , "\"count\":{\"#bigint\":\"", show c, "\"}"
          , ",\"action_taken\":\"", a, "\""
          , ",\"step_count\":{\"#bigint\":\"", show s, "\"}"
          , "}}"
          ]

        stateLines = concat $ replicate 2
          [ mkReport (0 :: Int)  "init" (0 :: Int)
          , mkReport (2 :: Int)  "tick" (1 :: Int)
          , mkReport (4 :: Int)  "tick" (2 :: Int)
          , mkReport (6 :: Int)  "tick" (3 :: Int)
          , mkReport (8 :: Int)  "tick" (4 :: Int)
          , mkReport (10 :: Int) "tick" (5 :: Int)
          ]

        input = B8.pack $ unlines $ registerLine : stateLines

      putStrLn ""
      putStrLn "  --- mirror stdout ---"

      (exitCode, stdout, _stderr) <- readProcessWithExitCode bin [] (B8.unpack input)

      case exitCode of
        ExitFailure n -> assertFailure $ "mirror exited " ++ show n ++ "\nstdout: " ++ stdout
        ExitSuccess -> pure ()

      let outputLines = lines stdout
      mapM_ (putStrLn . ("  " ++)) outputLines

      putStrLn ""
      putStrLn "  --- protocol trace ---"

      let annotated = zipWith annotate [1 :: Int ..] outputLines
      mapM_ putStrLn annotated

      putStrLn ""

      let
        traceMsgs =
          [ "initial_state"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok", "next_step"
          , "step_ok"
          ]
        expected = ["spec_validated"] ++ traceMsgs ++ traceMsgs ++ ["all_steps_done"]

      assertBool ("expected " ++ show (length expected) ++ " messages, got " ++ show (length outputLines))
        (length outputLines == length expected)

      let checkMsg ls n step = do
            let line = ls !! (n - 1)
                needle = "\"proto_step\":\"" ++ step ++ "\""
            assertBool ("msg " ++ show n ++ ": expected proto_step=" ++ show step ++ "\n  got: " ++ take 120 line)
              (needle `isInfixOf` line)

      sequence_ $ zipWith (checkMsg outputLines) [1 :: Int ..] expected

annotate :: Int -> String -> String
annotate n line
  | "spec_validated"  `isInfixOf` line = "  [" ++ show n ++ "] <- spec_validated"
  | "all_steps_done"  `isInfixOf` line = "  [" ++ show n ++ "] <- all_steps_done"
  | "protocol_error"  `isInfixOf` line = "  [" ++ show n ++ "] <- protocol_error"
  | "initial_state"   `isInfixOf` line = "  [" ++ show n ++ "] <- initial_state"
  | "next_step"       `isInfixOf` line = "  [" ++ show n ++ "] <- next_step"
  | "step_ok"         `isInfixOf` line = "  [" ++ show n ++ "] <- step_ok"
  | "step_mismatch"   `isInfixOf` line = "  [" ++ show n ++ "] <- step_mismatch"
  | otherwise                          = "  [" ++ show n ++ "] <- " ++ take 70 line
--------------------------------------------------------------------------------
-- Validate-only CLI (ModelMirrors validate)
--------------------------------------------------------------------------------

freePort :: IO PortNumber
freePort = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just "0")
  case addrs of
    [] -> error "freePort: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind s (addrAddress addr)
      SockAddrInet p _ <- getSocketName s
      close s
      pure p

-- | Run the mirror for a single accepted TCP connection and return its
-- structured step log, so integration tests can assert the mirror side of a
-- real TCP session (not just the client-visible reply).
runMirrorOneSession :: PortNumber -> IO [MirrorStep]
runMirrorOneSession port = do
  addrs <- getAddrInfo (Just defaultHints { addrFlags = [AI_PASSIVE] }) (Just "127.0.0.1") (Just (show port))
  case addrs of
    [] -> error "runMirrorOneSession: cannot resolve 127.0.0.1"
    (addr : _) -> do
      lsock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      bind lsock (addrAddress addr)
      listen lsock 5
      (conn, _) <- accept lsock
      t <- tcpTransport conn
      steps <- run t
      close conn
      close lsock
      pure steps

testParseValidateOpts :: TestTree
testParseValidateOpts = testGroup "parseValidateOpts"
  [ testCase "parses minimal required flags" $ do
      case parseValidateOpts ["--host", "h", "--port", "42", "--spec", "s.tla"] of
        Left e -> assertFailure e
        Right o -> do
          (voHost o, voPort o, voSpec o) @?= ("h", 42, "s.tla")
          voBound o @?= 10
          voDeps o @?= []
          voTls o @?= False
          voInv o @?= Nothing
  , testCase "accumulates --dep in order" $ do
      case parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--dep", "a.tla", "--dep", "b.tla"] of
        Right o -> voDeps o @?= ["a.tla", "b.tla"]
        Left e -> assertFailure e
  , testCase "collects optional predicates and --inv" $ do
      case parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--bound", "7", "--inv", "Inv", "--init", "Init", "--next", "Next", "--cinit", "CInit"] of
        Right o ->
          (voBound o, voInv o, voInit o, voNext o, voCinit o) @?=
            (7, Just "Inv", Just "Init", Just "Next", Just "CInit")
        Left e -> assertFailure e
  , testCase "missing --host is rejected" $
      assertBool "missing --host" (isLeft (parseValidateOpts ["--port", "1", "--spec", "s"]))
  , testCase "missing --spec is rejected" $
      assertBool "missing --spec" (isLeft (parseValidateOpts ["--host", "h", "--port", "1"]))
  , testCase "invalid --port is rejected" $
      assertBool "invalid --port" (isLeft (parseValidateOpts ["--host", "h", "--port", "x", "--spec", "s"]))
  , testCase "unknown option is rejected" $
      assertBool "unknown option" (isLeft (parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--bogus"]))
  , testCase "--tls requires cert/key/ca" $
      assertBool "--tls missing creds" (isLeft (parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--tls"]))
  , testCase "--pin without --tls is rejected" $
      assertBool "--pin needs --tls" (isLeft (parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--pin", "beef"]))
  , testCase "--tls with cert/key/ca and --pin parses" $ do
      case parseValidateOpts ["--host", "h", "--port", "1", "--spec", "s", "--tls", "--cert", "c", "--key", "k", "--ca", "ca", "--pin", "beef"] of
        Right o ->
          (voTls o, voCert o, voKey o, voCa o, voPin o) @?=
            (True, Just "c", Just "k", Just "ca", Just "beef")
        Left e -> assertFailure e
  ]

testValidateCliClosedPort :: TestTree
testValidateCliClosedPort = testCase "validate CLI exits 2 on connection failure" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      port <- freePort
      (exit, _out, _err) <- readProcessWithExitCode bin
        [ "validate", "--host", "127.0.0.1", "--port", show port, "--spec", "test/specs/HourClock.tla" ] ""
      exit @?= ExitFailure 2

testValidateCliTcpValid :: TestTree
testValidateCliTcpValid = testCase "validate CLI exits 0 for a valid spec over TCP" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      port <- freePort
      mv <- newEmptyMVar
      _ <- forkIO $ do
        r <- try (runMirrorOneSession port) :: IO (Either SomeException [MirrorStep])
        putMVar mv (either (Left . displayException) Right r)
      threadDelay 200000
      (exit, out, _err) <- readProcessWithExitCode bin
        [ "validate", "--host", "127.0.0.1", "--port", show port, "--spec", "test/specs/HourClock.tla" ] ""
      mirrorResult <- readMVar mv
      exit @?= ExitSuccess
      assertBool "prints VALID" ("VALID" `isInfixOf` out)
      case mirrorResult of
        Left e -> assertFailure $ "mirror failed: " ++ e
        Right steps ->
          map mirrorStepActionName steps
            @?= [T.pack "MirrorRecvRegisterValidate", T.pack "MirrorSendSpecValidatedValid"]

testValidateCliTcpInvalid :: TestTree
testValidateCliTcpInvalid = testCase "validate CLI exits 1 for a violated invariant" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      port <- freePort
      tid <- forkIO (serveTcpConcurrent 2 port)
      threadDelay 200000
      (exit, out, _err) <- readProcessWithExitCode bin
        [ "validate", "--host", "127.0.0.1", "--port", show port, "--spec", "test/specs/HourClock.tla", "--inv", "TraceComplete", "--bound", "13" ] ""
      killThread tid
      exit @?= ExitFailure 1
      assertBool "prints INVALID" ("INVALID" `isInfixOf` out)

testValidateCliTls :: TestTree
testValidateCliTls = testCase "validate CLI exits 0 over mTLS" $ do
  mbBin <- findMirrorBinaryOrSkip
  case mbBin of
    Nothing -> pure ()
    Just bin -> do
      certs <- genCerts
      port <- freePort
      params <- mkServerParams (serverCrt certs) (serverKey certs) (caCrt certs)
      tid <- forkIO (serveTlsConcurrent 2 params port)
      threadDelay 200000
      (exit, out, _err) <- readProcessWithExitCode bin
        [ "validate", "--host", "127.0.0.1", "--port", show port, "--spec", "test/specs/HourClock.tla"
        , "--tls", "--cert", clientCrt certs, "--key", clientKey certs, "--ca", caCrt certs ] ""
      killThread tid
      exit @?= ExitSuccess
      assertBool "prints VALID" ("VALID" `isInfixOf` out)

-- | Actively poll a TCP port until a connection succeeds (the mirror
-- process has bound and entered its accept loop), or blow a retry budget.
-- Unlike a fixed delay, polling is robust to slow process startup on loaded
-- CI runners: the test proceeds as soon as the listener is really up, and
-- fails fast if the mirror never becomes ready (e.g. it crashed on a bad
-- arg or port conflict). The probe connection is closed immediately; the
-- mirror's sequential accept loop treats a bare connection as a protocol
-- error session and keeps serving.
waitForMirrorPort :: Int -> PortNumber -> IO ()
waitForMirrorPort retries port = do
  addrs <- getAddrInfo (Just defaultHints) (Just "127.0.0.1") (Just (show port))
  case addrs of
    [] -> error "waitForMirrorPort: cannot resolve 127.0.0.1"
    (addr : _) -> do
      s <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      r <- try (connect s (addrAddress addr)) :: IO (Either IOException ())
      case r of
        Right () -> close s  -- listener is up; probe done
        Left (_ :: IOException)
          | retries > 0 -> close s >> threadDelay 100000 >> waitForMirrorPort (retries - 1) port
          | otherwise -> close s >> error "waitForMirrorPort: connection refused (mirror did not become ready)"

-- | Spawn the mirror executable as a separate OS process with @args@
-- (e.g. @["--serve", "PORT"]@ for plain TCP or the @--server ... --tls ...
-- @ form for mTLS), wait for it to be listening (active TCP polling, not a
-- fixed delay), run @action@ against it, then clean up by terminating the
-- process. This is the process-to-process half of the validate e2e tests:
-- both the mirror and the client are real OS processes, connected over the
-- network, not forkIO'd in-process.
withMirrorProcess :: FilePath -> [String] -> IO a -> IO a
withMirrorProcess bin args action = bracket
  (do
      (_, _, _, ph) <- createProcess (proc bin args)
        { std_out = Inherit, std_err = Inherit }
      -- The port is args[1] for both --serve PORT and --server PORT ...
      port <- case args of
        (_ : portStr : _) -> pure (fromIntegral (read portStr :: Int))
        _ -> error "withMirrorProcess: cannot determine port from args"
      waitForMirrorPort 50 port
      pure ph)
  (\ph -> terminateProcess ph >> void (waitForProcess ph))
  (const action)

-- | Process-to-process validate e2e: spawn @ModelMirrors --serve PORT@ as a
-- separate OS process, then spawn @ModelMirrors validate ...@ as another
-- separate OS process, and assert the client's verdict + exit code.
-- The mirror is never forkIO'd; both ends are real processes.
testValidateCliProc2ProcTcpValid :: TestTree
testValidateCliProc2ProcTcpValid =
  testCase "validate CLI (process-to-process) exits 0 for a valid spec over TCP" $ do
    mbBin <- findMirrorBinaryOrSkip
    case mbBin of
      Nothing -> pure ()
      Just bin -> do
        port <- freePort
        withMirrorProcess bin ["--serve", show port] $ do
          (exit, out, err) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/HourClock.tla" ] ""
          exit @?= ExitSuccess
          assertBool "prints VALID" ("VALID" `isInfixOf` out)
          assertBool "no error on stderr" (null err)

testValidateCliProc2ProcTcpInvalid :: TestTree
testValidateCliProc2ProcTcpInvalid =
  testCase "validate CLI (process-to-process) exits 1 for a violated invariant over TCP" $ do
    mbBin <- findMirrorBinaryOrSkip
    case mbBin of
      Nothing -> pure ()
      Just bin -> do
        port <- freePort
        withMirrorProcess bin ["--serve", show port] $ do
          (exit, out, _err) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/HourClock.tla", "--inv", "TraceComplete", "--bound", "13" ] ""
          exit @?= ExitFailure 1
          assertBool "prints INVALID" ("INVALID" `isInfixOf` out)

testValidateCliProc2ProcTls :: TestTree
testValidateCliProc2ProcTls =
  testCase "validate CLI (process-to-process) exits 0 over mTLS" $ do
    mbBin <- findMirrorBinaryOrSkip
    case mbBin of
      Nothing -> pure ()
      Just bin -> do
        certs <- genCerts
        port <- freePort
        withMirrorProcess bin
          [ "--server", show port, "--tls"
          , "--cert", serverCrt certs, "--key", serverKey certs, "--ca", caCrt certs ] $ do
          (exit, out, _err) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/HourClock.tla"
            , "--tls", "--cert", clientCrt certs, "--key", clientKey certs, "--ca", caCrt certs ] ""
          exit @?= ExitSuccess
          assertBool "prints VALID" ("VALID" `isInfixOf` out)

testValidateCliProc2ProcTcpDeps :: TestTree
testValidateCliProc2ProcTcpDeps =
  testCase "validate CLI (process-to-process) resolves --dep modules over TCP" $ do
    mbBin <- findMirrorBinaryOrSkip
    case mbBin of
      Nothing -> pure ()
      Just bin -> do
        port <- freePort
        withMirrorProcess bin ["--serve", show port] $ do
          -- A spec whose Next reaches count=3 within 3 steps, so the
          -- invariant count<3 is violated exactly at --bound 3 and holds
          -- through --bound 2. Exercises the --dep inline-spec path where
          -- the mirror materializes ExtMain.tla + ExtDep.tla to a temp dir.
          (badExit, badOut, _) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/ExtMain.tla", "--dep", "test/specs/ExtDep.tla"
            , "--inv", "TraceComplete", "--bound", "3" ] ""
          badExit @?= ExitFailure 1
          assertBool "prints INVALID for violated --dep spec"
            ("INVALID" `isInfixOf` badOut)
          (okExit, okOut, _) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/ExtMain.tla", "--dep", "test/specs/ExtDep.tla"
            , "--inv", "TraceComplete", "--bound", "2" ] ""
          okExit @?= ExitSuccess
          assertBool "prints VALID for satisfiable --dep spec at bound 2"
            ("VALID" `isInfixOf` okOut)

-- | Over-cap scenario: a client sending @--bound@ above 'maxValidateBound'
-- (100) must be rejected by the mirror with a @register_error@ before any
-- apalache invocation, and the CLI maps that to exit 2 (infra tier). A
-- below-min bound (0) is rejected the same way. Both run process-to-process.
testValidateCliProc2ProcTcpOverCap :: TestTree
testValidateCliProc2ProcTcpOverCap =
  testCase "validate CLI (process-to-process) rejects out-of-range bound with exit 2" $ do
    mbBin <- findMirrorBinaryOrSkip
    case mbBin of
      Nothing -> pure ()
      Just bin -> do
        port <- freePort
        withMirrorProcess bin ["--serve", show port] $ do
          -- bound > maxValidateBound (100): mirror replies register_error
          (overExit, _overOut, overErr) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/HourClock.tla", "--bound", "101" ] ""
          overExit @?= ExitFailure 2
          assertBool "reports over-cap bound range error"
            ("allowed range" `isInfixOf` overErr)
          -- bound < 1 (0): mirror replies register_error the same way
          (zeroExit, _zeroOut, zeroErr) <- readProcessWithExitCode bin
            [ "validate", "--host", "127.0.0.1", "--port", show port
            , "--spec", "test/specs/HourClock.tla", "--bound", "0" ] ""
          zeroExit @?= ExitFailure 2
          assertBool "reports zero bound range error"
            ("allowed range" `isInfixOf` zeroErr)


--------------------------------------------------------------------------------
-- Server-option parser (P1 / P2)
--------------------------------------------------------------------------------

testServerOpts :: TestTree
testServerOpts = testGroup "parseServerOpts"
  [ testCase "parses minimal server args with defaults" $ do
      case parseServerOpts ["8080", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"] of
        Left e -> assertFailure e
        Right o -> do
          (soPort o, soCert o, soKey o, soCa o) @?= (8080, "c", "k", "ca")
          soJobs o @?= 4
          soRegistry o @?= Nothing
          soBind o @?= Nothing
  , testCase "parses --bind/--registry/--jobs in any order" $ do
      case parseServerOpts
             [ "--tls", "9000", "--cert", "c", "--key", "k", "--ca", "ca"
             , "--bind", "127.0.0.1", "--registry", "http://r", "--jobs", "2" ] of
        Left e -> assertFailure e
        Right o -> do
          (soPort o, soBind o, soRegistry o, soJobs o) @?= (9000, Just "127.0.0.1", Just "http://r", 2)
  , testCase "rejects unknown option" $
      assertBool "unknown option" (isLeft (parseServerOpts ["8080", "--tls", "--cert", "c", "--key", "k", "--ca", "ca", "--bogus"]))
  , testCase "rejects duplicate --cert" $
      assertBool "duplicate cert" (isLeft (parseServerOpts ["8080", "--tls", "--cert", "c", "--cert", "c2", "--key", "k", "--ca", "ca"]))
  , testCase "rejects missing --tls" $
      assertBool "missing tls" (isLeft (parseServerOpts ["8080", "--cert", "c", "--key", "k", "--ca", "ca"]))
  , testCase "rejects missing port" $
      assertBool "missing port" (isLeft (parseServerOpts ["--tls", "--cert", "c", "--key", "k", "--ca", "ca"]))
  , testCase "rejects non-numeric port and jobs with clear messages" $ do
      assertBool "bad port" (isLeft (parseServerOpts ["abc", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"]))
      assertBool "bad jobs" (isLeft (parseServerOpts ["8080", "--tls", "--cert", "c", "--key", "k", "--ca", "ca", "--jobs", "x"]))
      case parseServerOpts ["8080", "--tls", "--cert", "c", "--key", "k", "--ca", "ca", "--jobs", "x"] of
        Left e -> assertBool ("clear jobs error: " ++ e) ("invalid --jobs" `isInfixOf` e)
        Right _ -> assertFailure "expected --jobs error"
  , testCase "parseServeCli accepts port and --bind" $ do
      parseServeCli ["1234"] @?= Right (1234, Nothing)
      parseServeCli ["1234", "--bind", "127.0.0.1"] @?= Right (1234, Just "127.0.0.1")
      assertBool "bad serve" (isLeft (parseServeCli ["abc"]))
  ]

--------------------------------------------------------------------------------
-- Registry-based validate-option parser (P3)
--------------------------------------------------------------------------------

testValidateRegistryOpts :: TestTree
testValidateRegistryOpts = testGroup "parseValidateOpts --registry"
  [ testCase "registry mode: host/port optional, tls+creds required" $ do
      case parseValidateOpts ["--spec", "s.tla", "--registry", "http://r", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"] of
        Right o -> do
          voRegistry o @?= Just "http://r"
          voTls o @?= True
        Left e -> assertFailure e
  , testCase "registry mode rejects --host combination" $
      assertBool "host not allowed" (isLeft (parseValidateOpts ["--spec", "s", "--registry", "http://r", "--host", "h", "--port", "1", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"]))
  , testCase "registry mode rejects an explicit empty --host" $
      assertBool "empty host not allowed" (isLeft (parseValidateOpts ["--spec", "s", "--registry", "http://r", "--host", "", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"]))
  , testCase "registry mode rejects an explicit --port 0" $
      assertBool "port 0 not allowed" (isLeft (parseValidateOpts ["--spec", "s", "--registry", "http://r", "--port", "0", "--tls", "--cert", "c", "--key", "k", "--ca", "ca"]))
  , testCase "registry mode requires --tls" $
      assertBool "needs tls" (isLeft (parseValidateOpts ["--spec", "s", "--registry", "http://r"]))
  , testCase "registry mode requires creds" $
      assertBool "needs creds" (isLeft (parseValidateOpts ["--spec", "s", "--registry", "http://r", "--tls"]))
  ]

--------------------------------------------------------------------------------
-- Protocol.Discover candidate logic (P3)
--------------------------------------------------------------------------------

testDiscoverLogic :: TestTree
testDiscoverLogic = testGroup "Protocol.Discover"
  [ testCase "candidateFingerprint: explicit pin wins, else registry metadata" $ do
      let peer = DiscoveredPeer "host" 1234 (Just (T.pack "regfp"))
      candidateFingerprint Nothing peer @?= Just (T.pack "regfp")
      candidateFingerprint (Just (T.pack "mypin")) peer @?= Just (T.pack "mypin")
  , testCase "tryCandidates: first success wins (first candidate fails)" $ do
      res <- tryCandidates [1 :: Int, 2, 3] $ \n -> pure $
        if n == 1 then Left "first failed" else Right (n * 10)
      res @?= Right 20
  , testCase "tryCandidates: returns concatenated errors when all fail" $ do
      res <- tryCandidates [1 :: Int, 2] $ \_ -> pure (Left "boom")
      case res of
        Left e -> assertBool ("includes both: " ++ e) (("boom; boom") `isInfixOf` e)
        Right _ -> assertFailure "expected all-fail"
  , testCase "tryCandidates: empty list reports no candidates" $ do
      res <- tryCandidates ([] :: [Int]) $ \_ -> pure (Left "unused")
      case res of
        Left e -> assertBool ("no candidates: " ++ e) ("no candidates" `isInfixOf` e)
        Right _ -> assertFailure "expected failure on empty"
  ]
