module Apalache.Rpc.Client
  ( rpcCall
  , newRpcClient
  , health
  , loadSpec
  , assumeTransition
  , nextStep
  , checkInvariant
  , query
  , rollback
  , disposeSpec
  , assumeState
  ) where

import Apalache.Rpc.Types
import Control.Exception (catch)
import Data.Aeson (FromJSON, ToJSON, encode, eitherDecode, toJSON)
import qualified Data.Aeson.Types as A
import Data.IORef (newIORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BSC
import Network.HTTP.Client
  ( newManager
  , defaultManagerSettings
  , httpLbs
  , parseRequest
  , RequestBody (..)
  , Request (..)
  , method
  , requestBody
  , requestHeaders
  , responseBody
  , HttpException
  )
import Network.HTTP.Types.Header (hContentType)

newRpcClient :: Int -> IO RpcClient
newRpcClient port = do
  manager <- newManager defaultManagerSettings
  ref <- newIORef 1
  pure $ RpcClient
    { rpcBaseUrl = T.pack $ "http://localhost:" ++ show port ++ "/rpc"
    , rpcManager = manager
    , rpcNextId  = ref
    }

rpcCall :: (ToJSON p, FromJSON r) => RpcClient -> Text -> p -> IO (Either RpcError r)
rpcCall client methodName params = do
  reqId <- atomicModifyIORef' (rpcNextId client) (\n -> (n + 1, n))
  let body = encode $ JsonRpcRequest methodName (toJSON params) reqId
  req <- parseRequest (T.unpack (rpcBaseUrl client))
  let req' = req
        { method = BSC.pack "POST"
        , requestBody = RequestBodyLBS body
        , requestHeaders = [(hContentType, BSC.pack "application/json")]
        }
  result <- catch (Right <$> httpLbs req' (rpcManager client))
                  (pure . Left)
  case result of
    Left (e :: HttpException) ->
      pure $ Left $ RpcHttpError (T.pack (show e))
    Right resp ->
      case eitherDecode (responseBody resp) of
        Left err -> pure $ Left $ RpcParseError (T.pack err)
        Right (JrSuccess _ val) ->
          case A.parse A.parseJSON val of
            A.Error e -> pure $ Left $ RpcParseError (T.pack e)
            A.Success r -> pure $ Right r
        Right (JrError _ code msg _) ->
          pure $ Left $ RpcProtocolError code msg

health :: RpcClient -> IO (Either RpcError HealthResult)
health client = rpcCall client (T.pack "health") ()

loadSpec :: RpcClient -> LoadSpecParams -> IO (Either RpcError LoadSpecResult)
loadSpec client = rpcCall client (T.pack "loadSpec")

assumeTransition :: RpcClient -> AssumeTransitionParams -> IO (Either RpcError AssumeTransitionResult)
assumeTransition client = rpcCall client (T.pack "assumeTransition")

nextStep :: RpcClient -> NextStateParams -> IO (Either RpcError NextStateResult)
nextStep client = rpcCall client (T.pack "nextStep")

checkInvariant :: RpcClient -> CheckInvariantParams -> IO (Either RpcError CheckInvariantResult)
checkInvariant client = rpcCall client (T.pack "checkInvariant")

query :: RpcClient -> QueryParams -> IO (Either RpcError QueryResult)
query client = rpcCall client (T.pack "query")

rollback :: RpcClient -> RollbackParams -> IO (Either RpcError ())
rollback client = rpcCall client (T.pack "rollback")

disposeSpec :: RpcClient -> DisposeSpecParams -> IO (Either RpcError ())
disposeSpec client = rpcCall client (T.pack "disposeSpec")

assumeState :: RpcClient -> AssumeStateParams -> IO (Either RpcError AssumeStateResult)
assumeState client = rpcCall client (T.pack "assumeState")
