module Apalache.SpecSource
  ( moduleName
  , materializeSpec
  , removeSpecDir
  ) where

import Apalache.Rpc.Types (ApalacheSpec (..))
import Control.Exception (IOException, try)
import Data.IORef (IORef, newIORef, atomicModifyIORef')
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeDirectoryRecursive
  )
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)

moduleName :: Text -> Either Text Text
moduleName src = case filter isModuleLine (T.lines src) of
  (l : _) -> parseHeader l
  []      -> Left (T.pack "no MODULE header found in spec source")
  where
    isModuleLine l = T.pack "MODULE" `T.isInfixOf` l && T.pack "-" `T.isPrefixOf` T.dropWhile (== ' ') l
    parseHeader l = case T.words l of
      (dashes : kw : name : rest)
        | T.all (== '-') dashes && kw == T.pack "MODULE"
          && not (T.all (== '-') name) && all (T.all (== '-')) rest ->
            Right name
      _ -> Left (T.pack "malformed MODULE header: " <> l)

{-# NOINLINE dirCounter #-}
dirCounter :: IORef Int
dirCounter = unsafePerformIO (newIORef 0)

materializeSpec :: ApalacheSpec -> IO (Either Text (FilePath, FilePath))
materializeSpec spec = case getSpecSources spec of
  [] -> pure (Left (T.pack "spec has no sources"))
  sources@(rootSrc : _) ->
    case mapM (\s -> (,) <$> moduleName s <*> pure s) sources of
      Left err -> pure (Left err)
      Right named -> do
        let names = map fst named
        if length (nub names) /= length names
          then pure (Left (T.pack "duplicate module names in spec sources"))
          else do
            dir <- freshSpecDir
            mapM_ (\(n, s) -> TIO.writeFile (dir </> T.unpack n ++ ".tla") s) named
            case moduleName rootSrc of
              Left err -> pure (Left err)
              Right rootName ->
                pure (Right (dir, dir </> T.unpack rootName ++ ".tla"))

removeSpecDir :: FilePath -> IO ()
removeSpecDir = removeDirectoryRecursive

freshSpecDir :: IO FilePath
freshSpecDir = do
  tmp <- getTemporaryDirectory
  n <- atomicModifyIORef' dirCounter (\m -> (m + 1, m))
  tryCreate tmp n
  where
    tryCreate tmp n = do
      let dir = tmp </> "modelmirrors-spec-" ++ show n
      r <- try (createDirectory dir)
      case r of
        Left (_ :: IOException) -> do
          n' <- atomicModifyIORef' dirCounter (\m -> (m + 1, m))
          tryCreate tmp n'
        Right () -> pure dir
