module Protocol.Transport.Core
  ( Transport (..)
  , sendMsg
  , recvMsg
  ) where

import qualified Data.Aeson as A
import Data.ByteString qualified as BS
import qualified Data.ByteString.Lazy as LBS

class Transport t where
  send :: t -> BS.ByteString -> IO ()
  recv :: t -> IO BS.ByteString

sendMsg :: (Transport t, A.ToJSON a) => t -> a -> IO ()
sendMsg t = send t . LBS.toStrict . A.encode

recvMsg :: (Transport t, A.FromJSON a) => t -> IO (Either String a)
recvMsg t = A.eitherDecodeStrict <$> recv t
