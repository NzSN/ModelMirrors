module Protocol.ValidateOpts
  ( ValidateOpts (..)
  , parseValidateOpts
  ) where

import Data.Maybe (isJust)

-- | Parsed command-line options for @ModelMirrors validate@. Pure and
-- hand-rolled (the codebase has no optparse-applicative dependency, and we
-- keep it that way).
data ValidateOpts = ValidateOpts
  { voHost     :: String
  , voPort     :: Int
  -- | Whether @--host@ was supplied. Kept separate from 'voHost' so an
  -- explicit empty value is not mistaken for "option absent".
  , voHostSet  :: Bool
  -- | Whether @--port@ was supplied. Kept separate from 'voPort' so an
  -- explicit @--port 0@ is not mistaken for "option absent".
  , voPortSet  :: Bool
  , voSpec     :: FilePath
  , voDeps     :: [FilePath]
  , voBound    :: Int
  , voInv      :: Maybe String
  , voInit     :: Maybe String
  , voNext     :: Maybe String
  , voCinit    :: Maybe String
  , voTls      :: Bool
  , voCert     :: Maybe FilePath
  , voKey      :: Maybe FilePath
  , voCa       :: Maybe FilePath
  , voPin      :: Maybe String
  , voRegistry :: Maybe String
  } deriving (Show, Eq)

defaultBound :: Int
defaultBound = 10

parseValidateOpts :: [String] -> Either String ValidateOpts
parseValidateOpts = go defaults
  where
    defaults = ValidateOpts
      { voHost     = ""
      , voPort     = 0
      , voHostSet  = False
      , voPortSet  = False
      , voSpec     = ""
      , voDeps     = []
      , voBound    = defaultBound
      , voInv      = Nothing
      , voInit     = Nothing
      , voNext     = Nothing
      , voCinit    = Nothing
      , voTls      = False
      , voCert     = Nothing
      , voKey      = Nothing
      , voCa       = Nothing
      , voPin      = Nothing
      , voRegistry = Nothing
      }

    go o [] = finalize o
    go o (a : as) = case a of
      "--host"  -> arg a as $ \v r -> go o { voHost = v, voHostSet = True } r
      "--port"  -> arg a as $ \v r -> case reads v of
                      [(p, "")] -> go o { voPort = p, voPortSet = True } r
                      _ -> Left ("invalid --port: " ++ v)
      "--spec"  -> arg a as $ \v r -> go o { voSpec = v } r
      "--dep"   -> arg a as $ \v r -> go o { voDeps = voDeps o ++ [v] } r
      "--bound" -> arg a as $ \v r -> case reads v of
                      [(n, "")] -> go o { voBound = n } r
                      _ -> Left ("invalid --bound: " ++ v)
      "--inv"   -> arg a as $ \v r -> go o { voInv = Just v } r
      "--init"  -> arg a as $ \v r -> go o { voInit = Just v } r
      "--next"  -> arg a as $ \v r -> go o { voNext = Just v } r
      "--cinit" -> arg a as $ \v r -> go o { voCinit = Just v } r
      "--tls"   -> go o { voTls = True } as
      "--cert"  -> arg a as $ \v r -> go o { voCert = Just v } r
      "--key"   -> arg a as $ \v r -> go o { voKey = Just v } r
      "--ca"    -> arg a as $ \v r -> go o { voCa = Just v } r
      "--pin"   -> arg a as $ \v r -> go o { voPin = Just v } r
      "--registry" -> arg a as $ \v r -> go o { voRegistry = Just v } r
      _         -> Left ("unknown option: " ++ a)

    arg :: String -> [String] -> (String -> [String] -> Either String ValidateOpts) -> Either String ValidateOpts
    arg name [] _ = Left ("option " ++ name ++ " requires an argument")
    arg _ (v : as) k = k v as

    finalize o
      | isJust (voRegistry o) = registryFinalize o
      | otherwise = directFinalize o

    -- Direct-connect mode: --host/--port are required and discovery is not
    -- used.
    directFinalize o
      | null (voHost o) = Left "missing required --host"
      | voPort o <= 0   = Left "missing required --port"
      | null (voSpec o) = Left "missing required --spec"
      | isJust (voPin o) && not (voTls o) = Left "--pin requires --tls"
      | voTls o = case (voCert o, voKey o, voCa o) of
          (Just _, Just _, Just _) -> Right o
          _ -> Left "--tls requires --cert, --key, and --ca"
      | otherwise = Right o

    -- Registry-discovery mode: mTLS-only, and mutually exclusive with
    -- direct --host/--port (we pick rejecting the combination over a
    -- registry-first fallback to direct).
    registryFinalize o
      | null (voSpec o) = Left "missing required --spec"
      | voHostSet o     = Left "--registry cannot be combined with --host"
      | voPortSet o     = Left "--registry cannot be combined with --port"
      | isJust (voPin o) && not (voTls o) = Left "--pin requires --tls"
      | not (voTls o) = Left "--registry requires --tls"
      | otherwise = case (voCert o, voKey o, voCa o) of
          (Just _, Just _, Just _) -> Right o
          _ -> Left "--registry requires --cert, --key, and --ca"
