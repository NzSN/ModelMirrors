-- | Raw JSONL framing. Limits apply to encoded bytes, excluding the LF.
module Protocol.Transport.Framing
  ( maxPayloadBytes
  , validatePayload
  , readHandleFrame
  , FrameReader
  , newFrameReader
  , readFrame
  ) where

import Control.Exception (Exception, SomeException, catch, onException, throwIO)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO (Handle)

data FramingError = FramingError String deriving (Show)
instance Exception FramingError

maxPayloadBytes :: Int
maxPayloadBytes = 65535

-- | Check the final encoding before a transport emits any bytes. Raw LF is
-- forbidden: built-in transports append exactly one framing LF themselves.
validatePayload :: BS.ByteString -> IO ()
validatePayload bs = do
  when (BS.length bs > maxPayloadBytes) (failure "payload exceeds 65535 bytes")
  when (BS.elem 10 bs) (failure "payload contains a raw LF")

failure :: String -> IO a
failure = throwIO . FramingError

-- | A buffered Handle retains any read-ahead itself. Reading one raw byte at
-- a time preserves the nullary stdio constructor and never consumes the next
-- frame. At most 65535 bytes (plus bounded list-cell overhead) are retained.
-- IO failure and invalid framing close the input; no drain-and-resume path.
readHandleFrame :: Handle -> IO () -> IO BS.ByteString
readHandleFrame h closeInput = loop 0 [] `onException` closeQuietly closeInput
  where
    loop n acc = do
      bs <- BS.hGet h 1
      if BS.null bs
        then if n == 0 then pure BS.empty else failure "unterminated frame at EOF"
        else case BS.head bs of
          10 -> pure (BS.pack (reverse acc))
          byte
            | n == maxPayloadBytes -> failure "payload exceeds 65535 bytes"
            | otherwise -> loop (n + 1) (byte : acc)

-- The TLS library returns one decrypted record per recvData call. Keep a
-- defensive 65536-byte chunk ceiling, independent of its usual 16384-byte
-- record bound. Retained payload <=65535; unconsumed record suffix <=65536.
data ReaderState = Ready BS.ByteString | Poisoned
data FrameReader = FrameReader (IORef ReaderState) (IO BS.ByteString) (IO ())

newFrameReader :: IO BS.ByteString -> IO () -> IO FrameReader
newFrameReader input closeInput = FrameReader <$> newIORef (Ready BS.empty) <*> pure input <*> pure closeInput

readFrame :: FrameReader -> IO BS.ByteString
readFrame (FrameReader ref input closeInput) = do
  initial <- readIORef ref
  case initial of
    Poisoned -> failure "transport is closed after a framing/read failure"
    Ready suffix -> loop 0 [] suffix `onException` poison
  where
    poison = writeIORef ref Poisoned >> closeQuietly closeInput
    loop n chunks bytes = case BS.elemIndex 10 bytes of
      Just i -> do
        when (n + i > maxPayloadBytes) (failure "payload exceeds 65535 bytes")
        let payload = BS.concat (reverse (BS.take i bytes : chunks))
        writeIORef ref (Ready (BS.copy (BS.drop (i + 1) bytes)))
        pure payload
      Nothing -> do
        let total = n + BS.length bytes
        when (total > maxPayloadBytes) (failure "payload exceeds 65535 bytes")
        next <- input
        unless (BS.length next <= 65536) (failure "input chunk exceeds bounded record allowance")
        if BS.null next
          then if total == 0
            then writeIORef ref (Ready BS.empty) >> pure BS.empty
            else failure "unterminated frame at EOF"
          else loop total (if BS.null bytes then chunks else BS.copy bytes : chunks) next

closeQuietly :: IO () -> IO ()
closeQuietly action = action `catch` \(_ :: SomeException) -> pure ()
