module Protocol.Transport.Stdio
  ( StdioTransport (..)
  ) where

import Protocol.Transport.Core (Transport (..))
import Control.Exception (IOException, try)
import Data.ByteString.Char8 qualified as B8
import System.IO (hFlush, stdout)

data StdioTransport = StdioTransport

instance Transport StdioTransport where
  send _ bs = B8.putStrLn bs >> hFlush stdout
  recv _    = do
    result <- try B8.getLine :: IO (Either IOException B8.ByteString)
    pure $ either (const B8.empty) id result
