{-# LANGUAGE BangPatterns, CPP, MagicHash, OverloadedStrings, MonoPatBinds #-}
-- | Support for HTTP response encoding.
--
-- TODO: Improve documentation.
module Blaze.ByteString.Builder.HTTP (
  -- * Chunked HTTP transfer encoding
    chunkedTransferEncoding
  , chunkedTransferTerminator
  ) where

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
#include "MachDeps.h"
#endif

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
import GHC.Base
import GHC.Word (Word32(..))
#else
import Data.Word
#endif

import Foreign

import Data.Monoid
import qualified Data.ByteString       as S
import Data.ByteString.Char8 ()

import Foreign

import Blaze.ByteString.Builder.Internal.Write
import Data.ByteString.Builder
import Data.ByteString.Builder.Internal
-- import Blaze.ByteString.Builder.Internal.Types
-- import Blaze.ByteString.Builder.Internal.UncheckedShifts
import Blaze.ByteString.Builder.ByteString (copyByteString)

import qualified Blaze.ByteString.Builder.Char8 as Char8


{-# INLINE shiftr_w32 #-}
shiftr_w32 :: Word32 -> Int -> Word32

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftr_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftRL#`   i)
#else
shiftr_w32 = shiftR
#endif


-- only required by test-code
-- import qualified Data.ByteString.Lazy as L
-- import qualified Blaze.ByteString.Builder.ByteString  as B
-- import Data.ByteString.Char8 ()


-- | Write a CRLF sequence.
writeCRLF :: Write
writeCRLF = Char8.writeChar '\r' `mappend` Char8.writeChar '\n'
{-# INLINE writeCRLF #-}

-- | Execute a write
{-# INLINE execWrite #-}
execWrite :: Write -> Ptr Word8 -> IO ()
execWrite w op = do
    _ <- runPoke (getPoke w) op
    return ()


------------------------------------------------------------------------------
-- Hex Encoding Infrastructure
------------------------------------------------------------------------------

{-
pokeWord16Hex :: Word16 -> Ptr Word8 -> IO ()
pokeWord16Hex x op = do
    pokeNibble 0 12
    pokeNibble 1  8
    pokeNibble 2  4
    pokeNibble 3  0
  where
    pokeNibble off s
        | n <  10   = pokeWord8 off (fromIntegral $ 48 + n)
        | otherwise = pokeWord8 off (fromIntegral $ 55 + n)
        where
          n = shiftr_w16 x s .&. 0xF

    pokeWord8 :: Int -> Word8 -> IO ()
    pokeWord8 off = poke (op `plusPtr` off)

writeWord16Hex :: Word16 -> Write
writeWord16Hex = exactWrite 4 . pokeWord16Hex

-}

pokeWord32HexN :: Int -> Word32 -> Ptr Word8 -> IO ()
pokeWord32HexN n0 w0 op0 =
    go w0 (op0 `plusPtr` (n0 - 1))
  where
    go !w !op
      | op < op0  = return ()
      | otherwise = do
          let nibble :: Word8
              nibble = fromIntegral w .&. 0xF
              hex | nibble < 10 = 48 + nibble
                  | otherwise   = 55 + nibble
          poke op hex
          go (w `shiftr_w32` 4) (op `plusPtr` (-1))
{-# INLINE pokeWord32HexN #-}

iterationsUntilZero :: Integral a => (a -> a) -> a -> Int
iterationsUntilZero f = go 0
  where
    go !count 0  = count
    go !count !x = go (count+1) (f x)
{-# INLINE iterationsUntilZero #-}

-- | Length of the hex-string required to encode the given 'Word32'.
word32HexLength :: Word32 -> Int
word32HexLength = max 1 . iterationsUntilZero (`shiftr_w32` 4)
{-# INLINE word32HexLength #-}

writeWord32Hex :: Word32 -> Write
writeWord32Hex w =
    boundedWrite (2 * sizeOf w) (pokeN len $ pokeWord32HexN len w)
  where
    len = word32HexLength w
{-# INLINE writeWord32Hex #-}


{-
test = flip (toLazyByteStringWith 32 32 32) L.empty
    $ chunkedTransferEncoding
    $ mconcat $ map oneLine [0..16] ++
                [B.insertByteString "hello"] ++
                map oneLine [0,1] ++
                [B.insertByteString ""] ++
                map oneLine [0..16]

  where
    oneLine x = fromWriteSingleton writeWord32Hex x `mappend` Char8.fromChar ' '

test = print $ toLazyByteString
    $ chunkedTransferEncoding  body `mappend` chunkedTransferTerminator

body = copyByteString "maa" `mappend` copyByteString "foo" `mappend` copyByteString "bar"
-}

------------------------------------------------------------------------------
-- Chunked transfer encoding
------------------------------------------------------------------------------

-- | Transform a builder such that it uses chunked HTTP transfer encoding.
chunkedTransferEncoding :: Builder -> Builder
chunkedTransferEncoding builder =
    builder transferEncodingStep
  where
    b = runBuilder builder
    buildStep = id
    runBuildStep = id

    finalStep !(BufferRange op _) = return $ Done op ()

    transferEncodingStep k = go (b (buildStep finalStep))
      where
        go innerStep !(BufferRange op ope)
          -- FIXME: Assert that outRemaining < maxBound :: Word32
          | outRemaining < minimalBufferSize =
              return $ bufferFull minimalBufferSize op (go innerStep)
          | otherwise = do
              let !brInner@(BufferRange opInner _) = BufferRange
                     (op  `plusPtr` (chunkSizeLength + 2))     -- leave space for chunk header
                     (ope `plusPtr` (-maxAfterBufferOverhead)) -- leave space at end of data

                  -- wraps the chunk, if it is non-empty, and returns the
                  -- signal constructed with the correct end-of-data pointer
                  {-# INLINE wrapChunk #-}
                  wrapChunk :: Ptr Word8 -> (Ptr Word8 -> IO (BuildSignal a))
                            -> IO (BuildSignal a)
                  wrapChunk !opInner' mkSignal
                    | opInner' == opInner = mkSignal op
                    | otherwise           = do
                        pokeWord32HexN chunkSizeLength
                            (fromIntegral $ opInner' `minusPtr` opInner)
                            op
                        execWrite writeCRLF (opInner `plusPtr` (-2))
                        execWrite writeCRLF opInner'
                        mkSignal (opInner' `plusPtr` 2)

              -- execute inner builder with reduced boundaries
              signal <- runBuildStep innerStep brInner
              case signal of
                Done opInner' _ ->
                    wrapChunk opInner' $ \op' -> do
                      let !br' = BufferRange op' ope
                      k br'

                BufferFull minRequiredSize opInner' nextInnerStep ->
                    wrapChunk opInner' $ \op' ->
                      return $! bufferFull
                        (minRequiredSize + maxEncodingOverhead)
                        op'
                        (go nextInnerStep)

                InsertByteString opInner' bs nextInnerStep
                  | S.null bs ->                        -- flush
                      wrapChunk opInner' $ \op' ->
                        return $! insertByteString
                          op' S.empty
                          (go nextInnerStep)

                  | otherwise ->                        -- insert non-empty bytestring
                      wrapChunk opInner' $ \op' -> do
                        -- add header for inserted bytestring
                        -- FIXME: assert(S.length bs < maxBound :: Word32)
                        !op'' <- (`runPoke` op') $ getPoke $
                            writeWord32Hex (fromIntegral $ S.length bs)
                            `mappend` writeCRLF
                        -- insert bytestring and write CRLF in next buildstep
                        return $! InsertByteString
                          op'' bs
                          (runBuilderWith (fromWrite writeCRLF) $
                            buildStep $ go nextInnerStep)

          where
            -- minimal size guaranteed for actual data no need to require more
            -- than 1 byte to guarantee progress the larger sizes will be
            -- hopefully provided by the driver or requested by the wrapped
            -- builders.
            minimalChunkSize  = 1

            -- overhead computation
            maxBeforeBufferOverhead = sizeOf (undefined :: Int) + 2 -- max chunk size and CRLF after header
            maxAfterBufferOverhead  = 2 +                           -- CRLF after data
                                      sizeOf (undefined :: Int) + 2 -- max bytestring size, CRLF after header

            maxEncodingOverhead = maxBeforeBufferOverhead + maxAfterBufferOverhead

            minimalBufferSize = minimalChunkSize + maxEncodingOverhead

            -- remaining and required space computation
            outRemaining :: Int
            outRemaining    = ope `minusPtr` op
            chunkSizeLength = word32HexLength $ fromIntegral outRemaining


-- | The zero-length chunk '0\r\n\r\n' signaling the termination of the data transfer.
chunkedTransferTerminator :: Builder
chunkedTransferTerminator = copyByteString "0\r\n\r\n"
