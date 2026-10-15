module StdioTransportSpec (spec, child) where

import Control.Exception (SomeException, bracket, catch)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Protocol.Transport.Core (Transport (..), sendMsg)
import Protocol.Transport.Stdio (StdioTransport (StdioTransport))
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush, hSetBinaryMode)
import System.Process
  ( CreateProcess (..), StdStream (CreatePipe), createProcess, proc
  , terminateProcess, waitForProcess )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, (@?=), testCase)
import TransportTestSupport (bounded)

child :: String -> IO ()
child "echo" = do
  frame <- recv StdioTransport
  if BS.null frame then pure () else send StdioTransport frame >> child "echo"
child "oversize-send" = do
  send StdioTransport (BS.replicate 65536 120) `catch` \(_ :: SomeException) -> pure ()
  send StdioTransport (B8.pack "marker")
child "oversize-json" = do
  sendMsg StdioTransport (replicate 65534 'x') `catch` \(_ :: SomeException) -> pure ()
  send StdioTransport (B8.pack "marker")
child _ = ioError (userError "invalid stdio test mode")

withChild :: String -> (Handle -> Handle -> IO a) -> IO (a, ExitCode)
withChild mode action = do
  executable <- getExecutablePath
  let create = createProcess (proc executable ["--framing-stdio-child", mode])
        { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  bracket create cleanup $ \(Just input, Just output, _, process) -> do
    hSetBinaryMode input True
    hSetBinaryMode output True
    result <- action input output
    hClose input
    code <- bounded (waitForProcess process)
    pure (result, code)
  where
    cleanup (input, output, errors, process) = do
      terminateProcess process `catch` \(_ :: SomeException) -> pure ()
      _ <- bounded (waitForProcess process)
      mapM_ (maybe (pure ()) (\h -> hClose h `catch` \(_ :: SomeException) -> pure ())) [input, output, errors]

spec :: TestTree
spec = testGroup "StdioFramingNonModel"
  [ testCase "actual stdio preserves coalesced lines split UTF8 and byte caps" $ do
      (_, code) <- withChild "echo" $ \input output -> do
        B8.hPutStr input (B8.pack "first\nsecond\n")
        hFlush input
        bounded (B8.hGetLine output) >>= (@?= B8.pack "first")
        bounded (B8.hGetLine output) >>= (@?= B8.pack "second")
        BS.hPut input (BS.pack [34, 206])
        hFlush input
        BS.hPut input (BS.pack [187, 34, 10])
        hFlush input
        bounded (B8.hGetLine output) >>= (@?= BS.pack [34, 206, 187, 34])
        mapM_ (\n -> do
          B8.hPutStrLn input (BS.replicate n 120)
          hFlush input
          bounded (B8.hGetLine output) >>= (@?= BS.replicate n 120)) [65534, 65535]
      code @?= ExitSuccess
  , testCase "unterminated stdio frame fails and emits no payload" $ do
      (bytes, code) <- withChild "echo" $ \input output -> do
        B8.hPutStr input (B8.pack "{}")
        hClose input
        bounded (BS.hGetContents output)
      assertBool "truncated input exits with failure" (code /= ExitSuccess)
      bytes @?= BS.empty
  , testCase "stdio oversized input fails before EOF and cannot resume suffix" $ do
      (bytes, code) <- withChild "echo" $ \input output -> do
        BS.hPut input (BS.replicate 65536 120)
        hFlush input
        -- Keep stdin open while awaiting failure: no EOF is needed.
        bounded (BS.hGetContents output)
      assertBool "oversize input exits with failure" (code /= ExitSuccess)
      bytes @?= BS.empty
  , testCase "direct and encoded stdio oversized sends write zero bytes" $ do
      mapM_ (\mode -> do
        (bytes, code) <- withChild mode $ \_ output -> bounded (BS.hGetContents output)
        bytes @?= B8.pack "marker\n"
        code @?= ExitSuccess) ["oversize-send", "oversize-json"]
  ]
