-- | Enforced RAII for ModelMirrors resources.
--
-- An opaque handle + total cleanup + one-bit ownership state. The constructor
-- is not exported; the only way to obtain a 'Resource' is 'acquire' or
-- 'acquireIn'. Cleanup runs at most once (enforced by an atomic state
-- transition), release never throws (cleanup is wrapped total at acquire
-- time), and a GC finalizer backstops forgotten releases by logging a leak and
-- reclaiming the resource.
--
-- See @docs/resource-model-design.md@ for the full design.
-- (enforced RAII)
module Resource
  ( ResourceState (..)
  , Resource
  , Provenance (..)
  , ResourceError (..)
  , acquire
  , acquireIn
  , release
  , transfer
  , use
  , with
  , Registry
  , newRegistry
  , forceReleaseAll
  , resourceErrorText
  ) where

import Control.Exception (SomeException, bracket, displayException, mask, try)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (stderr)
import System.Mem.Weak (mkWeakPtr)

-- | The ownership state of a resource.
data ResourceState
  = Live          -- ^ owned, cleanup has not run yet
  | Delivered     -- ^ ownership transferred; cleanup skipped by design
  | Released      -- ^ cleanup has run
  | ReleaseFailed -- ^ cleanup was attempted but threw (logged)
  deriving (Eq, Show)

-- | Provenance of a resource value: 'Owned' means the value was materialized
-- by this process and cleanup must reclaim it; 'Borrowed' means the value
-- belongs to the caller (e.g. a config-supplied spec path) and cleanup must
-- be a no-op that never deletes it.
data Provenance
  = Owned    -- ^ created here; cleanup reclaims it
  | Borrowed -- ^ caller-owned; cleanup is a no-op
  deriving (Eq, Show)

-- | An opaque owned resource of type @a@. Fields are module-internal; the
-- value is only reachable through 'use'.
data Resource a = Resource
  { resState   :: !(IORef ResourceState)
  , resValue   :: a
  , resLabel   :: Text
  , resCleanup :: IO () -- ^ total; never throws
  }

-- | One registered handle, existentially quantified over the resource type:
-- the registry can hold resources of any @a@ and release them uniformly.
data RegEntry = forall a. RegEntry (Resource a)

-- | A dynamic-lifetime registry. Handles registered via 'acquireIn' are held
-- in acquisition order (newest first) and released (LIFO, reverse
-- acquisition order) by 'forceReleaseAll'.
newtype Registry = Registry (IORef (Bool, [RegEntry]))

-- | Errors surfaced by the resource model.
data ResourceError
  = UseAfterRelease Text -- ^ the resource was released (or delivered) before use
  | RegistryClosed       -- ^ a closed registry rejected a new acquisition
  deriving (Eq, Show)

-- | Atomically transition @Live -> Released@, reporting whether this caller
-- won the transition. The single winner runs cleanup; everyone else observes
-- a no-op. This is the enforcement point for "released at most once".
claimLive :: IORef ResourceState -> IO Bool
claimLive st = atomicModifyIORef' st $ \s -> case s of
  Live -> (Released, True)
  other -> (other, False)

-- | Atomically transition @Live -> Delivered@ (silent no-op otherwise).
markDelivered :: IORef ResourceState -> IO ()
markDelivered st = atomicModifyIORef' st $ \s -> case s of
  Live -> (Delivered, ())
  other -> (other, ())

-- | The total cleanup runner built at acquire time. Any exception from the
-- raw cleanup is caught, logged, and recorded as 'ReleaseFailed' — so
-- 'release' is total by construction (C++ noexcept destructor analogue).
totalCleanup :: IORef ResourceState -> Text -> IO () -> IO ()
totalCleanup st label raw = do
  r <- try raw
  case r of
    Right () -> pure ()
    Left (e :: SomeException) -> do
      logMsg (T.pack "release failed: " <> label <> T.pack ": " <> T.pack (displayException e))
      writeIORef st ReleaseFailed

-- | GC backstop: when the state cell becomes unreachable while still 'Live',
-- log a leak and run the total cleanup. Because the finalizer goes through
-- 'claimLive', it can never double-clean with an explicit 'release'.
finalizer :: IORef ResourceState -> Text -> IO () -> IO ()
finalizer st label cleanup = do
  won <- claimLive st
  when won $ do
    logMsg (T.pack "leak: " <> label)
    cleanup

-- | Acquire a resource, attaching the GC finalizer under 'mask' so an async
-- exception cannot interrupt between allocation and finalizer attachment. If
-- @get@ throws, nothing is registered.
acquire :: Text -> IO a -> (a -> IO ()) -> IO (Resource a)
acquire label get cleanup = mask $ \restore -> do
  v <- restore get
  st <- newIORef Live
  let total = totalCleanup st label (cleanup v)
  _ <- mkWeakPtr st (Just (finalizer st label total))
  pure (Resource st v label total)

-- | Acquire and register atomically in the same masked block, so registration
-- cannot be forgotten. A closed registry rejects the acquisition (and cleans
-- up the just-acquired resource immediately).
acquireIn :: Registry -> Text -> IO a -> (a -> IO ()) -> IO (Either ResourceError (Resource a))
acquireIn reg label get cleanup = mask $ \restore -> do
  closed <- isClosed reg
  if closed
    then pure (Left RegistryClosed)
    else do
      v <- restore get
      st <- newIORef Live
      let total = totalCleanup st label (cleanup v)
      _ <- mkWeakPtr st (Just (finalizer st label total))
      let res = Resource st v label total
      registered <- register reg res
      if registered
        then pure (Right res)
        else do
          release res
          pure (Left RegistryClosed)

-- | Idempotent, total release. The winner of the @Live -> Released@
-- transition runs cleanup; re-release is a logged no-op; releasing a
-- 'Delivered' resource is a silent no-op (ownership was transferred).
release :: Resource a -> IO ()
release res = do
  won <- claimLive (resState res)
  if won
    then resCleanup res
    else do
      s <- readIORef (resState res)
      case s of
        Delivered -> pure ()
        _ -> logMsg (T.pack "re-release ignored: " <> resLabel res)

-- | Disclaim ownership (@Live -> Delivered@): the finalizer is detached in
-- effect (a later finalizer pass observes 'Delivered' and does nothing) and
-- cleanup is skipped. The explicit form of deliberate abandonment.
transfer :: Resource a -> IO ()
transfer res = markDelivered (resState res)

-- | Run an action on the underlying value while the resource is still 'Live'.
-- Use-after-release is a runtime error ('UseAfterRelease'), not silent
-- corruption. Single-owner resources need no lock.
use :: Resource a -> (a -> IO b) -> IO (Either ResourceError b)
use res f = do
  s <- readIORef (resState res)
  case s of
    Live -> Right <$> f (resValue res)
    _ -> pure (Left (UseAfterRelease (resLabel res)))

-- | The enforced lexical form: 'bracket' over 'acquire'/'release'. On scope
-- exit the resource is 'Released' (so the finalizer, if it ever fires, is a
-- no-op).
with :: Text -> IO a -> (a -> IO ()) -> (Resource a -> IO b) -> IO b
with label get cleanup = bracket (acquire label get cleanup) release

-- | An empty, open registry.
newRegistry :: IO Registry
newRegistry = Registry <$> newIORef (True, [])

-- | Atomically close the registry, take every handle, and release them LIFO
-- (reverse acquisition order), each total. Idempotent.
forceReleaseAll :: Registry -> IO ()
forceReleaseAll (Registry ref) = do
  entries <- atomicModifyIORef' ref $ \(_, entries) -> ((False, []), entries)
  mapM_ (\(RegEntry res) -> release res) entries

isClosed :: Registry -> IO Bool
isClosed (Registry ref) = not . fst <$> readIORef ref

register :: Registry -> Resource a -> IO Bool
register (Registry ref) res =
  atomicModifyIORef' ref $ \(open, entries) ->
    if open then ((open, RegEntry res : entries), True) else ((open, entries), False)

-- | Render a 'ResourceError' as human-readable text (used by callers that
-- surface registry failures through a @Text@ error channel, e.g. the async
-- job store mapping 'RegistryClosed' to a register error).
resourceErrorText :: ResourceError -> Text
resourceErrorText = \case
  UseAfterRelease l -> T.pack "resource use after release: " <> l
  RegistryClosed    -> T.pack "resource registry closed"

-- | Minimal stderr logging (the codebase has no structured-logger module yet;
-- existing modules log to stderr directly). One line per event.
logMsg :: Text -> IO ()
logMsg = TIO.hPutStrLn stderr . (T.pack "resource: " <>)
