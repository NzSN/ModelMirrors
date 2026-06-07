module Main (main) where

import Protocol.Mirror (run)
import Protocol.Transport.Stdio (StdioTransport (..))

main :: IO ()
main = run StdioTransport
