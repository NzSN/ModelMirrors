module Protocol.Transport.Stdio
  ( StdioTransport (..)
  ) where

import Protocol.Transport.Core (Transport (..))
import Data.ByteString.Char8 qualified as B8
import System.IO (hFlush, stdout)

data StdioTransport = StdioTransport

instance Transport StdioTransport where
  send _ bs = B8.putStrLn bs >> hFlush stdout
  recv _    = B8.getLine
