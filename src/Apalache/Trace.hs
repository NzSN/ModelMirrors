module Apalache.Trace
  ( readTrace
  , findTraceFiles
  , findTraces
  ) where

import Apalache.Types (ItfTrace)

import Data.Aeson (eitherDecodeFileStrict')
import Data.List (isSuffixOf)
import System.Directory (listDirectory)
import System.FilePath ((</>), takeFileName)

-- | Read and parse a single ITF trace file.
readTrace :: FilePath -> IO (Either String ItfTrace)
readTrace path = eitherDecodeFileStrict' path

-- | Find all ITF trace file paths in a directory (non-recursively).
-- Looks for files matching @*.itf.json@. Does not parse them.
findTraceFiles :: FilePath -> IO [FilePath]
findTraceFiles dir = do
  files <- listDirectory dir
  let tf = filter (\f -> ".itf.json" `isSuffixOf` takeFileName f) files
  pure $ map (dir </>) tf

-- | Find and parse all ITF trace files in a directory.
-- Looks for files matching @*.itf.json@, reads and parses them.
-- Silently skips files that fail to parse.
findTraces :: FilePath -> IO [ItfTrace]
findTraces dir = do
  paths <- findTraceFiles dir
  results <- mapM readTrace paths
  pure [t | Right t <- results]
