module Protocol.Transport.Mock
  ( MockTransport
  , newMockTransport
  ) where

import Control.Concurrent.Chan
import qualified Data.ByteString as BS
import Protocol.Transport.Core (Transport (..))

data MockTransport = MockTransport
  { chanRead  :: Chan BS.ByteString
  , chanWrite :: Chan BS.ByteString
  }

instance Transport MockTransport where
  send t = writeChan (chanWrite t)
  recv t = readChan (chanRead t)

newMockTransport :: IO (MockTransport, MockTransport)
newMockTransport = do
  c1 <- newChan
  c2 <- newChan
  let clientEnd = MockTransport c1 c2
      mirrorEnd = MockTransport c2 c1
  pure (clientEnd, mirrorEnd)
