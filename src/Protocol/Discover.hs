-- | Client-side service-discovery plumbing shared by the @validate@ CLI
-- and the test suite. Kept transport-agnostic so unit tests can exercise
-- candidate iteration and fingerprint selection without a live server.
module Protocol.Discover
  ( DiscoveredPeer (..)
  , candidateFingerprint
  , tryCandidates
  ) where

import Data.Text (Text)
import Network.Socket (PortNumber)

-- | A mirror discovered via the registry, plus the certificate fingerprint
-- the registry advertised for it (if any).
data DiscoveredPeer = DiscoveredPeer
  { dpHost :: String
  , dpPort :: PortNumber
  , dpFingerprint :: Maybe Text
  } deriving (Eq, Show)

-- | The fingerprint to pin for a candidate: an explicit client @--pin@
-- override wins over the registry-provided metadata.
candidateFingerprint :: Maybe Text -> DiscoveredPeer -> Maybe Text
candidateFingerprint explicitOverride peer =
  case explicitOverride of
    Just _ -> explicitOverride
    Nothing -> dpFingerprint peer

-- | Try each candidate in order with the given connector, which returns
-- 'Right' with a connected value on success or 'Left' with a diagnostic on
-- failure. Returns the first successful result, or 'Left' with the
-- concatenated diagnostics if every candidate fails (including the empty
-- candidate list).
tryCandidates :: [a] -> (a -> IO (Either String b)) -> IO (Either String b)
tryCandidates [] _ = pure (Left "no candidates discovered")
tryCandidates (c : cs) f = do
  r <- f c
  case r of
    Right b -> pure (Right b)
    Left err -> do
      rest <- tryCandidates cs f
      pure $ case rest of
        Right b -> Right b
        Left errs -> Left (err ++ "; " ++ errs)
