------------------------------------------------------------------------------
-- |
-- Module:      Blaze.ByteString.Builder.Html.Utf8
-- Copyright:   (c) 2013 Leon P Smith
-- License:     BSD3
-- Maintainer:  Leon P Smith <leon@melding-monads.com>
-- Stability:   experimental
--
------------------------------------------------------------------------------

module Blaze.ByteString.Builder.Html.Utf8
    (
      module Blaze.ByteString.Builder.Char.Utf8

      -- * Writing HTML escaped and UTF-8 encoded characters to a buffer
    , writeHtmlEscapedChar

      -- * Creating Builders from HTML escaped and UTF-8 encoded characters
    , fromHtmlEscapedChar
    , fromHtmlEscapedString
    , fromHtmlEscapedShow
    , fromHtmlEscapedText
    , fromHtmlEscapedLazyText
    ) where

import Data.ByteString.Char8 ()  -- for the 'IsString' instance of bytesrings

import qualified Data.Text      as TS
import qualified Data.Text.Lazy as TL

import Blaze.ByteString.Builder.Compat.Write ( Write, writePrimBounded )
import           Data.ByteString.Builder ( Builder )
import qualified Data.ByteString.Builder       as B
import qualified Data.ByteString.Builder.Extra as B
import           Data.ByteString.Builder.Prim ((>*<), (>$<), condB)
import qualified Data.ByteString.Builder.Prim  as P

import Blaze.ByteString.Builder.Char.Utf8

writeHtmlEscapedChar :: Char -> Write
writeHtmlEscapedChar = writePrimBounded charUtf8HtmlEscaped

fromHtmlEscapedChar :: Char -> Builder
fromHtmlEscapedChar = P.primBounded charUtf8HtmlEscaped

{-# INLINE charUtf8HtmlEscaped #-}
charUtf8HtmlEscaped :: P.BoundedPrim Char
charUtf8HtmlEscaped =
    condB (>  '>' ) (condB (== '\DEL') P.emptyB P.charUtf8) $
    condB (== '<' ) (fixed4 ('&',('l',('t',';')))) $        -- &lt;
    condB (== '>' ) (fixed4 ('&',('g',('t',';')))) $        -- &gt;
    condB (== '&' ) (fixed5 ('&',('a',('m',('p',';'))))) $  -- &amp;
    condB (== '"' ) (fixed5 ('&',('#',('3',('4',';'))))) $  -- &#34;
    condB (== '\'') (fixed5 ('&',('#',('3',('9',';'))))) $  -- &#39;
    condB (\c -> c >= ' ' || c == '\t' || c == '\n' || c == '\r')
          (P.liftFixedToBounded P.char7) $
    P.emptyB
  where
    {-# INLINE fixed4 #-}
    fixed4 x = P.liftFixedToBounded $ const x >$<
      P.char7 >*< P.char7 >*< P.char7 >*< P.char7

    {-# INLINE fixed5 #-}
    fixed5 x = P.liftFixedToBounded $ const x >$<
      P.char7 >*< P.char7 >*< P.char7 >*< P.char7 >*< P.char7

-- | /O(n)/. Serialize a HTML escaped Unicode 'String' using the UTF-8
-- encoding.
--
fromHtmlEscapedString :: String -> Builder
fromHtmlEscapedString = P.primMapListBounded charUtf8HtmlEscaped

-- | /O(n)/. Serialize a value by 'Show'ing it and then, HTML escaping and
-- UTF-8 encoding the resulting 'String'.
--
fromHtmlEscapedShow :: Show a => a -> Builder
fromHtmlEscapedShow = fromHtmlEscapedString . show

-- | /O(n)/. Serialize a HTML escaped strict Unicode 'TS.Text' value using the
-- UTF-8 encoding.
--
fromHtmlEscapedText :: TS.Text -> Builder
fromHtmlEscapedText = fromHtmlEscapedString . TS.unpack

-- | /O(n)/. Serialize a HTML escaped Unicode 'TL.Text' using the UTF-8 encoding.
--
fromHtmlEscapedLazyText :: TL.Text -> Builder
fromHtmlEscapedLazyText = fromHtmlEscapedString . TL.unpack
