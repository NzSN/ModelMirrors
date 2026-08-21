module ResourceSpec (spec) where

import Resource
  ( Resource
  , ResourceError (RegistryClosed, UseAfterRelease)
  , acquire
  , acquireIn
  , forceReleaseAll
  , newRegistry
  , release
  , transfer
  , use
  , with
  )

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeException, finally, throwTo, try)
import Control.Monad (unless)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (removeFile)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO
  ( hClose
  , hFlush
  , openTempFile
  , stderr
  )
import System.Mem (performGC)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

spec :: TestTree
spec = testGroup "ResourceSpec"
  [ testGroup "acquire/release"
      [ testAcquireReleaseRunsCleanup
      , testDoubleReleaseIsNoOp
      , testUseGivesValue
      , testUseAfterReleaseFails
      , testTransferSkipsCleanup
      , testWithRunsCleanup
      , testWithRunsCleanupOnException
      , testConcurrentReleaseOnce
      , testWithRunsCleanupOnAsyncException
      , testCleanupThrowsIsTotal
      , testAcquireThrowingGetterRegistersNothing
      ]
  , testGroup "GC backstop"
      [ testGcBackstopRunsCleanup
      , testGcBackstopLogsLeak
      ]
  , testGroup "registry"
      [ testForceReleaseAllLifo
      , testAcquireInAfterCloseRejected
      , testAcquireInCleansUpOnRegistrationRejection
      , testForceReleaseAllIdempotent
      , testRegistryPreventsPrematureFinalize
      ]
  ]

-- | A tiny mock resource: increments a counter on cleanup.
newMock :: IORef Int -> IO (Resource ())
newMock counter = acquire (T.pack "mock") (pure ()) (\_ -> modifyIORef' counter (+ 1))

testAcquireReleaseRunsCleanup :: TestTree
testAcquireReleaseRunsCleanup = testCase "acquire then release runs cleanup exactly once" $ do
  counter <- newIORef (0 :: Int)
  r <- newMock counter
  release r
  n <- readIORef counter
  n @?= 1

testDoubleReleaseIsNoOp :: TestTree
testDoubleReleaseIsNoOp = testCase "double release is a logged no-op" $ do
  counter <- newIORef (0 :: Int)
  r <- newMock counter
  release r
  release r
  release r
  n <- readIORef counter
  n @?= 1

testUseGivesValue :: TestTree
testUseGivesValue = testCase "use exposes the underlying value while Live" $ do
  r <- acquire (T.pack "val") (pure (5 :: Int)) (\_ -> pure ())
  use r (\v -> pure (v * 2)) >>= \case
    Right 10 -> release r
    other -> assertFailure ("expected Right 10, got " ++ show other)

testUseAfterReleaseFails :: TestTree
testUseAfterReleaseFails = testCase "use after release is UseAfterRelease" $ do
  r <- acquire (T.pack "gone") (pure ()) (\_ -> pure ())
  release r
  use r (\_ -> pure ()) >>= \case
    Left (UseAfterRelease lbl) -> lbl @?= T.pack "gone"
    other -> assertFailure ("expected UseAfterRelease, got " ++ show other)

testTransferSkipsCleanup :: TestTree
testTransferSkipsCleanup = testCase "transfer skips cleanup and delivers the resource" $ do
  counter <- newIORef (0 :: Int)
  r <- newMock counter
  transfer r
  n <- readIORef counter
  n @?= 0
  -- release after transfer is a silent no-op
  release r
  n2 <- readIORef counter
  n2 @?= 0
  -- and the delivered resource can no longer be used
  use r (\_ -> pure ()) >>= \case
    Left (UseAfterRelease _) -> pure ()
    other -> assertFailure ("expected UseAfterRelease after transfer, got " ++ show other)

testWithRunsCleanup :: TestTree
testWithRunsCleanup = testCase "with releases on normal scope exit" $ do
  counter <- newIORef (0 :: Int)
  result <- with (T.pack "w") (pure ()) (\() -> modifyIORef' counter (+ 1)) (\_ -> pure (42 :: Int))
  result @?= 42
  n <- readIORef counter
  n @?= 1

testWithRunsCleanupOnException :: TestTree
testWithRunsCleanupOnException = testCase "with releases under a synchronous exception" $ do
  counter <- newIORef (0 :: Int)
  result <- try (with (T.pack "w") (pure ()) (\() -> modifyIORef' counter (+ 1)) (\_ -> error "boom"))
  case (result :: Either SomeException Int) of
    Left _ -> do
      n <- readIORef counter
      n @?= 1
    Right _ -> assertFailure "body should have thrown"

testConcurrentReleaseOnce :: TestTree
testConcurrentReleaseOnce = testCase "concurrent releases run cleanup exactly once" $ do
  counter <- newIORef (0 :: Int)
  r <- newMock counter
  _ <- mapM (\_ -> forkIO (release r)) [1 .. 20 :: Int]
  threadDelay 200000
  n <- readIORef counter
  n @?= 1

testWithRunsCleanupOnAsyncException :: TestTree
testWithRunsCleanupOnAsyncException = testCase "with releases under an asynchronous exception" $ do
  counter <- newIORef (0 :: Int)
  done <- newEmptyMVar
  tid <- forkIO $ do
    result <- try (with (T.pack "async") (pure ()) (\() -> modifyIORef' counter (+ 1)) (\_ -> threadDelay 1000000 >> pure ()))
    putMVar done (result :: Either SomeException ())
  threadDelay 100000
  throwTo tid (userError "async boom")
  _ <- takeMVar done
  n <- readIORef counter
  n @?= 1

testCleanupThrowsIsTotal :: TestTree
testCleanupThrowsIsTotal = testCase "release never throws even when cleanup throws" $ do
  r <- acquire (T.pack "bad") (pure ()) (\_ -> error "cleanup boom")
  result <- try (release r)
  case (result :: Either SomeException ()) of
    Left e -> assertFailure ("release should be total, got " ++ show e)
    Right () -> pure ()

testAcquireThrowingGetterRegistersNothing :: TestTree
testAcquireThrowingGetterRegistersNothing = testCase "a throwing getter registers nothing" $ do
  counter <- newIORef (0 :: Int)
  result <- try (acquire (T.pack "throw") (error "get boom") (\() -> modifyIORef' counter (+ 1)) >>= \_ -> pure ())
  case (result :: Either SomeException ()) of
    Left _ -> do
      n <- readIORef counter
      n @?= 0
    Right _ -> assertFailure "getter should have thrown"

-- | Drop a resource so only the GC finalizer can reclaim it.
dropResource :: IORef Int -> IO ()
dropResource counter = do
  _ <- newMock counter
  pure ()

testGcBackstopRunsCleanup :: TestTree
testGcBackstopRunsCleanup = testCase "GC backstop reclaims a forgotten Live resource" $ do
  counter <- newIORef (0 :: Int)
  dropResource counter
  performGC
  pollUntil ((== (1 :: Int)) <$> readIORef counter) 2000
  n <- readIORef counter
  n @?= 1

testGcBackstopLogsLeak :: TestTree
testGcBackstopLogsLeak = testCase "GC backstop logs leak: <label> to stderr" $ do
  counter <- newIORef (0 :: Int)
  (path, h) <- openTempFile "/tmp" "resource-leak"
  oldErr <- hDuplicate stderr
  ( do
      hDuplicateTo h stderr
      dropResource counter
      performGC
      pollUntil ((== (1 :: Int)) <$> readIORef counter) 2000
      hFlush stderr
    )
    `finally` hDuplicateTo oldErr stderr
  hClose h
  content <- readFile path
  removeFile path
  assertBool ("expected 'leak:' in stderr, got: " ++ content) ("leak:" `isInfixOf` content)

testForceReleaseAllLifo :: TestTree
testForceReleaseAllLifo = testCase "forceReleaseAll releases LIFO (reverse acquisition order)" $ do
  reg <- newRegistry
  order <- newIORef ([] :: [Text])
  let mock l = acquireIn reg l (pure ()) (\() -> modifyIORef' order (++ [l]))
  r1 <- mock (T.pack "r1")
  r2 <- mock (T.pack "r2")
  r3 <- mock (T.pack "r3")
  case (r1, r2, r3) of
    (Right _, Right _, Right _) -> do
      forceReleaseAll reg
      o <- readIORef order
      o @?= [T.pack "r3", T.pack "r2", T.pack "r1"]
    _ -> assertFailure "acquireIn should have succeeded"

testAcquireInAfterCloseRejected :: TestTree
testAcquireInAfterCloseRejected = testCase "acquireIn after close is rejected" $ do
  reg <- newRegistry
  r1 <- acquireIn reg (T.pack "a") (pure ()) (\_ -> pure ())
  forceReleaseAll reg
  r2 <- acquireIn reg (T.pack "b") (pure ()) (\_ -> pure ())
  case r1 of
    Right _ -> pure ()
    Left _ -> assertFailure "first acquireIn should succeed"
  case r2 of
    Left RegistryClosed -> pure ()
    _ -> assertFailure "acquireIn after close should be rejected"

testAcquireInCleansUpOnRegistrationRejection :: TestTree
testAcquireInCleansUpOnRegistrationRejection = testCase "a registration rejected mid-flight cleans up immediately" $ do
  reg <- newRegistry
  counter <- newIORef (0 :: Int)
  -- the getter closes the registry between the open-check and registration, so
  -- registration is rejected and the just-acquired resource must be cleaned up
  r <- acquireIn reg (T.pack "race") (forceReleaseAll reg >> pure ()) (\() -> modifyIORef' counter (+ 1))
  case r of
    Left RegistryClosed -> pure ()
    _ -> assertFailure "registry closed by getter should reject the acquisition"
  n <- readIORef counter
  n @?= 1 -- immediate cleanup of the acquired-then-rejected resource

testForceReleaseAllIdempotent :: TestTree
testForceReleaseAllIdempotent = testCase "forceReleaseAll is idempotent" $ do
  reg <- newRegistry
  counter <- newIORef (0 :: Int)
  r <- acquireIn reg (T.pack "x") (pure ()) (\() -> modifyIORef' counter (+ 1))
  case r of
    Right _ -> pure ()
    Left _ -> assertFailure "acquireIn should succeed"
  forceReleaseAll reg
  forceReleaseAll reg
  n <- readIORef counter
  n @?= 1

testRegistryPreventsPrematureFinalize :: TestTree
testRegistryPreventsPrematureFinalize = testCase "registry keeps a dropped handle alive until close" $ do
  reg <- newRegistry
  counter <- newIORef (0 :: Int)
  let leakIntoReg = do
        _ <- acquireIn reg (T.pack "reg") (pure ()) (\() -> modifyIORef' counter (+ 1))
        pure ()
  leakIntoReg
  performGC
  threadDelay 200000
  n <- readIORef counter
  n @?= 0 -- still registered; finalizer must not run
  forceReleaseAll reg
  n2 <- readIORef counter
  n2 @?= 1

-- | Poll a predicate every 50ms until it holds or we give up.
pollUntil :: IO Bool -> Int -> IO ()
pollUntil p ms
  | ms <= 0 = pure ()
  | otherwise = do
      done <- p
      unless done $ do
        threadDelay 50000
        pollUntil p (ms - 50)
