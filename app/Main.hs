module Main (main) where

import Protocol.Mirror (run)
import Protocol.Transport.Stdio (StdioTransport (..))
import Protocol.Transport.Tcp (serveTcp)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--serve", portStr] -> serveTcp (fromIntegral (read portStr :: Int))
    _ -> run StdioTransport >> pure ()
