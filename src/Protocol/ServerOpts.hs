-- | Hand-rolled, order-independent parser for the @--server@ and @--serve@
-- command lines. Kept pure and in the library so the test suite can cover it
-- directly; the pattern matches @Protocol.ValidateOpts@ (no
-- optparse-applicative dependency).
module Protocol.ServerOpts
  ( ServerOpts (..)
  , parseServerOpts
  , parseServeCli
  ) where

import Data.List (isPrefixOf)

-- | Parsed server options. @--tls@ and cert/key/ca are required; the rest are
-- optional.
data ServerOpts = ServerOpts
  { soPort     :: Int
  , soCert     :: FilePath
  , soKey      :: FilePath
  , soCa       :: FilePath
  , soRegistry :: Maybe String
  , soJobs     :: Int
  , soBind     :: Maybe String
  } deriving (Show, Eq)

-- | Internal accumulation record for the server-option parser.
data ServerOptsC = ServerOptsC
  { scPort     :: Maybe Int
  , scTls      :: Bool
  , scCert     :: Maybe FilePath
  , scKey      :: Maybe FilePath
  , scCa       :: Maybe FilePath
  , scRegistry :: Maybe String
  , scJobs     :: Maybe Int
  , scBind     :: Maybe String
  }

-- | Parse the @--server@ options (the tokens after the initial @--server@).
-- Accepts the positional port plus @--tls --cert --key --ca [--registry]
-- [--jobs] [--bind]@ in any order; rejects unknown options,
-- missing/duplicate arguments, and non-numeric port/jobs with clear messages.
parseServerOpts :: [String] -> Either String ServerOpts
parseServerOpts argv = go initial argv >>= finalize
  where
    initial = ServerOptsC Nothing False Nothing Nothing Nothing Nothing Nothing Nothing

    go :: ServerOptsC -> [String] -> Either String ServerOptsC
    go s [] = Right s
    go s (a : as) = case a of
      "--tls" ->
        if scTls s
          then Left "duplicate --tls"
          else go s { scTls = True } as
      "--cert"      -> reqString "cert"      (scCert s)     (\v -> s { scCert = Just v })     as
      "--key"       -> reqString "key"       (scKey s)      (\v -> s { scKey = Just v })      as
      "--ca"        -> reqString "ca"        (scCa s)       (\v -> s { scCa = Just v })       as
      "--registry"  -> reqString "registry"  (scRegistry s) (\v -> s { scRegistry = Just v }) as
      "--bind"      -> reqString "bind"      (scBind s)     (\v -> s { scBind = Just v })     as
      "--jobs"      -> reqInt "jobs" (scJobs s) (\v -> s { scJobs = Just v }) as
      _ | "--" `isPrefixOf` a -> Left ("unknown option: " ++ a)
        | otherwise -> case reads a :: [(Int, String)] of
            [(n, "")] | scPort s == Nothing -> go s { scPort = Just n } as
            [_] -> Left ("duplicate port argument: " ++ a)
            _ -> Left ("invalid port: " ++ a)
      where
        reqString name cur set restArgs = case restArgs of
          [] -> Left ("option " ++ name ++ " requires an argument")
          (v : rest) | cur == Nothing -> go (set v) rest
                     | otherwise -> Left ("duplicate --" ++ name)
        reqInt name cur set restArgs = case restArgs of
          [] -> Left ("option " ++ name ++ " requires an argument")
          (v : rest) -> case reads v :: [(Int, String)] of
            [(n, "")] | cur == Nothing -> go (set n) rest
                      | otherwise -> Left ("duplicate --" ++ name)
            _ -> Left ("invalid --" ++ name ++ ": " ++ v)

    finalize :: ServerOptsC -> Either String ServerOpts
    finalize s = do
      port <- case scPort s of
        Just p | p > 0 -> Right p
        _ -> Left "missing required port (expected a positive integer)"
      if not (scTls s)
        then Left "missing required --tls"
        else pure ()
      cert <- opt "cert" (scCert s)
      key  <- opt "key"  (scKey s)
      ca   <- opt "ca"   (scCa s)
      pure ServerOpts
        { soPort = port
        , soCert = cert
        , soKey = key
        , soCa = ca
        , soRegistry = scRegistry s
        , soJobs = maybe 4 id (scJobs s)
        , soBind = scBind s
        }
    opt name Nothing = Left ("missing required --" ++ name)
    opt _ (Just v) = Right v

-- | Parse the @--serve@ tokens (after the initial @--serve@): @<port>@ or
-- @<port> --bind <addr>@.
parseServeCli :: [String] -> Either String (Int, Maybe String)
parseServeCli argv = case argv of
  [p] -> num p Nothing
  [p, "--bind", addr] -> num p (Just addr)
  _ -> Left "usage: ModelMirrors --serve <port> [--bind <addr>]"
  where
    num p b = case reads p :: [(Int, String)] of
      [(n, "")] | n > 0 -> Right (n, b)
      _ -> Left ("invalid port: " ++ p)
