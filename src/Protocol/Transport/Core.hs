module Protocol.Transport.Core
  ( Transport (..)
  , sendMsg
  , recvMsg
  ) where

import qualified Data.Aeson as A
import Data.ByteString qualified as BS
import qualified Data.ByteString.Lazy as LBS
import Protocol.Transport.Framing (validatePayload)

class Transport t where
  send :: t -> BS.ByteString -> IO ()
  recv :: t -> IO BS.ByteString

sendMsg :: (Transport t, A.ToJSON a) => t -> a -> IO ()
sendMsg t value = do
  let payload = LBS.toStrict (A.encode value)
  validatePayload payload
  send t payload

recvMsg :: (Transport t, A.FromJSON a) => t -> IO (Either String a)
recvMsg t = do
  payload <- recv t
  validatePayload payload
  pure (A.eitherDecodeStrict payload)
