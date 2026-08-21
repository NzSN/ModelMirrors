-- | One process-lifetime shared HTTP manager, used by both the apalache RPC
-- client and the Consul registry client. Created lazily on first use (the
-- 'dirCounter' pattern from "Apalache.SpecSource") and exposed both as a
-- 'Resource Manager' (for registration in a 'Resource.Registry' / explicit
-- lifecycle) and as the raw value (for reuse by call sites that take a
-- 'Manager' directly).
--
-- Rationale (design §4 D5): today every 'newRpcClient' and every registry
-- call allocates a fresh manager per call. A single shared manager reuses
-- one connection pool for the whole process. Its cleanup is a no-op:
-- 'closeManager' is deprecated upstream ("Manager will be closed for you
-- automatically when no longer in use") and no replacement close path exists,
-- so finalization is left to http-client's own GC, per the deprecation guidance.
-- The Resource wrapper documents the intended process-lifetime ownership; held
-- in this top-level binding it never becomes unreachable, so the GC backstop
-- cannot fire a spurious leak report.

module Apalache.HttpManager
  ( sharedManager
  , sharedManagerResource
  ) where

import qualified Data.Text as T
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import Resource (Resource, acquire, use)
import System.IO.Unsafe (unsafePerformIO)

-- | The process-lifetime manager as a 'Resource'. Never released in normal
-- operation (registered at process scope); cleanup is a no-op — see the module
-- header for why 'closeManager' is deliberately not used.
sharedManagerResource :: Resource Manager
{-# NOINLINE sharedManagerResource #-}
sharedManagerResource =
  unsafePerformIO (acquire (T.pack "http-manager") (newManager defaultManagerSettings) (\_ -> pure ()))

-- | The shared manager value, for call sites that take a 'Manager' directly.
-- Evaluated lazily; the underlying manager is created exactly once.
sharedManager :: Manager
{-# NOINLINE sharedManager #-}
sharedManager =
  unsafePerformIO $
    either
      (ioError . userError . ("shared http manager unavailable: " ++) . show)
      pure
      =<< use sharedManagerResource pure
