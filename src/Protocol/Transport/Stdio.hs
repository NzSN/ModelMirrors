module Protocol.Transport.Stdio
  ( StdioTransport (..)
  ) where

import Protocol.Transport.Core (Transport (..))
import Data.ByteString.Char8 qualified as B8
import Protocol.Transport.Framing (readHandleFrame, validatePayload)
import System.IO (Handle, hClose, hFlush, hGetEncoding, hSetBinaryMode, stdin, stdout)

data StdioTransport = StdioTransport

instance Transport StdioTransport where
  send _ bs = do
    validatePayload bs
    ensureBinary stdout
    B8.hPutStrLn stdout bs
    hFlush stdout
  recv _ = do
    ensureBinary stdin
    readHandleFrame stdin (hClose stdin)

-- Do not reset an already-binary Handle between frames: its buffered bytes
-- may contain a coalesced next frame.
ensureBinary :: Handle -> IO ()
ensureBinary handle = hGetEncoding handle >>= \case
  Nothing -> pure ()
  Just _ -> hSetBinaryMode handle True
