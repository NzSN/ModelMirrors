module Protocol.Registry
  ( RegistryUrl (..)
  , ServiceInfo (..)
  , registerService
  , heartbeatLoop
  , deregisterService
  , discoverServices
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as B8
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( Request (..)
  , RequestBody (..)
  , defaultManagerSettings
  , httpLbs
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  )
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Status (statusIsSuccessful)
import Network.Socket (PortNumber)

newtype RegistryUrl = RegistryUrl String

data ServiceInfo = ServiceInfo
  { siServiceId :: Text
  , siHost :: String
  , siPort :: PortNumber
  , siCertFingerprint :: Maybe Text
  } deriving (Eq, Show)

serviceName :: String
serviceName = "modelmirrors"

-- | Register a mirror service with a 30s TTL health check. Registry
-- failures are reported as 'False', not thrown.
registerService :: RegistryUrl -> ServiceInfo -> IO Bool
registerService (RegistryUrl url) info = do
  result <- try $ do
    manager <- newManager defaultManagerSettings
    req <- parseRequest (url ++ "/v1/agent/service/register")
    let body = A.object
          [ fromString "ID" A..= siServiceId info
          , fromString "Name" A..= serviceName
          , fromString "Address" A..= siHost info
          , fromString "Port" A..= (fromIntegral (siPort info) :: Int)
          , fromString "Meta" A..= maybe Map.empty (Map.singleton (T.pack "cert-sha256")) (siCertFingerprint info)
          , fromString "Check" A..= A.object [fromString "TTL" A..= (T.pack "30s")]
          ]
        req' = req
          { method = B8.pack "PUT"
          , requestBody = RequestBodyLBS (A.encode body)
          , requestHeaders = [(hContentType, B8.pack "application/json")]
          }
    resp <- httpLbs req' manager
    pure (statusIsSuccessful (responseStatus resp))
  pure (either (const False) id (result :: Either SomeException Bool))

-- | Send TTL heartbeats forever, every 10 seconds. Exceptions are
-- swallowed so a registry outage never kills the caller's accept loop;
-- a lapsed TTL simply removes the service from discovery.
heartbeatLoop :: RegistryUrl -> Text -> IO ()
heartbeatLoop (RegistryUrl url) sid = do
  manager <- newManager defaultManagerSettings
  forever $ do
    _ <- try (do
      req <- parseRequest (url ++ "/v1/agent/check/pass/service:" ++ T.unpack sid)
      void (httpLbs req { method = B8.pack "PUT" } manager)) :: IO (Either SomeException ())
    threadDelay 10000000

-- | Best-effort deregistration.
deregisterService :: RegistryUrl -> Text -> IO ()
deregisterService (RegistryUrl url) sid = void (try go :: IO (Either SomeException ()))
  where
    go = do
      manager <- newManager defaultManagerSettings
      req <- parseRequest (url ++ "/v1/agent/service/deregister/" ++ T.unpack sid)
      void (httpLbs req { method = B8.pack "PUT" } manager)

-- | Discover healthy mirror services. Fails closed: any registry or
-- parsing error yields an empty list.
discoverServices :: RegistryUrl -> IO [ServiceInfo]
discoverServices (RegistryUrl url) = do
  result <- try $ do
    manager <- newManager defaultManagerSettings
    req <- parseRequest (url ++ "/v1/health/service/" ++ serviceName ++ "?passing=true")
    resp <- httpLbs req manager
    pure (A.decode (responseBody resp) :: Maybe [A.Value])
  pure $ case result of
    Left (_ :: SomeException) -> []
    Right Nothing -> []
    Right (Just entries) -> concatMap toServiceInfo entries

toServiceInfo :: A.Value -> [ServiceInfo]
toServiceInfo (A.Object o) = maybe [] id $ do
  A.Object svc <- KM.lookup (K.fromText (T.pack "Service")) o
  A.String sid <- KM.lookup (K.fromText (T.pack "ID")) svc
  A.String host <- KM.lookup (K.fromText (T.pack "Address")) svc
  A.Number port <- KM.lookup (K.fromText (T.pack "Port")) svc
  let fp = case KM.lookup (K.fromText (T.pack "Meta")) svc of
        Just (A.Object meta) -> case KM.lookup (K.fromText (T.pack "cert-sha256")) meta of
          Just (A.String t) -> Just t
          _ -> Nothing
        _ -> Nothing
  if T.null host
    then Nothing
    else Just [ServiceInfo sid (T.unpack host) (fromIntegral (round port :: Int)) fp]
toServiceInfo _ = []
