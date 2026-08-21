module Apalache.SpecSource
  ( moduleName
  , materializeSpec
  , removeSpecDir
  , SpecRes (..)
  , Provenance (..)
  , acquireSpec
  , acquireSpecIn
  , freshSessionDir
  , removeSessionDir
  , acquireSessionDir
  , acquireSessionDirIn
  ) where

import Apalache.Rpc.Types (ApalacheSpec (..))
import Apalache.Types (ApalacheConfig (..))
import Control.Exception (IOException, try)
import Data.Functor.Identity (Identity (..))
import Resource
  ( Provenance (..)
  , Registry
  , Resource
  , ResourceError
  , acquire
  , acquireIn
  , resourceErrorText
  )
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
import System.IO.Temp (createTempDirectory)
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

-- | Provenance of a spec resource: 'Owned' means the source was materialized
-- from an inline 'ApalacheSpec' into a mirror-owned temp dir (release deletes
-- it); 'Borrowed' means the config's own @specPath@ is used as-is and the
-- mirror must never delete it. The type itself lives in "Resource" (single
-- source of truth; re-exported here for convenience).

-- | The value carried by an acquired spec resource.
data SpecRes = SpecRes
  { specResDir        :: !(Maybe FilePath) -- ^ temp dir to remove when 'Owned'; 'Nothing' when 'Borrowed'
  , specResRootPath   :: !FilePath        -- ^ root @.tla@ path to hand to apalache
  , specResProvenance :: !Provenance
  } deriving (Show, Eq)

-- | Acquire a spec resource. Inline sources are materialized to a fresh temp
-- dir via 'materializeSpec' (owned; release removes the dir); @Nothing@ uses
-- the config's own @specPath@ as-is ('Borrowed'; release never deletes it).
-- When owned, the returned config's @specPath@ is overridden to the
-- materialized root path. Existing callers of 'materializeSpec'/'removeSpecDir'
-- are unaffected.

-- | Shared worker behind 'acquireSpec' and 'acquireSpecIn': identical
-- materialization and cleanup logic; only the acquire flavor (plain
-- @acquire@ vs registry-registered @acquireIn@) differs, so the
-- Owned/Borrowed cleanup invariants stay single-sourced.
acquireSpecWith
  :: (forall a. Text -> IO a -> (a -> IO ()) -> IO (f (Resource a)))
  -> Maybe ApalacheSpec
  -> ApalacheConfig
  -> IO (Either Text (f (Resource SpecRes), ApalacheConfig))
acquireSpecWith acq Nothing cfg = do
  fres <- acq (T.pack "spec (borrowed)") (pure (SpecRes Nothing (specPath cfg) Borrowed)) (\_ -> pure ())
  pure (Right (fres, cfg))
acquireSpecWith acq (Just spec) cfg = do
  r <- materializeSpec spec
  case r of
    Left err -> pure (Left err)
    Right (dir, rootPath) -> do
      fres <- acq (T.pack "spec (owned)") (pure (SpecRes (Just dir) rootPath Owned)) removeSpecDirWhenOwned
      pure (Right (fres, cfg { specPath = rootPath }))
  where
    removeSpecDirWhenOwned sr = case specResDir sr of
      Just d  -> removeSpecDir d
      Nothing -> pure ()

-- | Plain (unregistered) spec acquisition; see 'acquireSpecWith' for the
-- shared semantics.
acquireSpec :: Maybe ApalacheSpec -> ApalacheConfig -> IO (Either Text (Resource SpecRes, ApalacheConfig))
acquireSpec mSpec cfg = do
  r <- acquireSpecWith (\l g c -> Identity <$> acquire l g c) mSpec cfg
  pure (fmap (\(Identity res, c) -> (res, c)) r)

-- | Registry-registered form of 'acquireSpec' for the async job model: the
-- acquired spec resource is registered in the given 'Registry' atomically
-- with acquisition, so session close ('Resource.forceReleaseAll') reclaims
-- any spec dir a job still holds. Registry failures are surfaced through the
-- @Text@ error channel (the caller turns them into a register error).
acquireSpecIn :: Registry -> Maybe ApalacheSpec -> ApalacheConfig -> IO (Either Text (Resource SpecRes, ApalacheConfig))
acquireSpecIn reg mSpec cfg = do
  r <- acquireSpecWith (acquireIn reg) mSpec cfg
  pure $ case r of
    Left err             -> Left err
    Right (Left rerr, _) -> Left (resourceErrorText rerr)
    Right (Right res, c) -> Right (res, c)

-- | Create a fresh per-session temporary directory (the session dir apalache
-- uses as its run dir / cwd). Removed via 'removeSessionDir'.
freshSessionDir :: IO FilePath
freshSessionDir = do
  tmp <- getTemporaryDirectory
  createTempDirectory tmp "modelmirrors-session-"

-- | Remove a session directory created by 'freshSessionDir'.
removeSessionDir :: FilePath -> IO ()
removeSessionDir = removeDirectoryRecursive

-- | Acquire a per-session directory as a 'Resource'; release removes it
-- (total). The dynamic-lifetime form of 'withSessionDir's bracket.
acquireSessionDir :: IO (Resource FilePath)
acquireSessionDir = acquire (T.pack "session-dir") freshSessionDir removeSessionDir

-- | Registry-registered form of 'acquireSessionDir' for the async job model
-- (see 'acquireSpecIn'); returns 'Resource.ResourceError' directly since
-- acquisition here cannot fail for spec reasons.
acquireSessionDirIn :: Registry -> IO (Either ResourceError (Resource FilePath))
acquireSessionDirIn reg = acquireIn reg (T.pack "session-dir") freshSessionDir removeSessionDir
