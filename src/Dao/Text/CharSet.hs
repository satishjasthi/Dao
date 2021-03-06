-- "Dao/Text/CharSet.hs"  an interval set of characters.
-- 
-- Copyright (C) 2008-2015  Ramin Honary.
--
-- Dao is free software: you can redistribute it and/or modify it under the
-- terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version.
-- 
-- Dao is distributed in the hope that it will be useful, but WITHOUT ANY
-- WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
-- details.
-- 
-- You should have received a copy of the GNU General Public License along with
-- this program (see the file called "LICENSE"). If not, see the URL:
-- <http://www.gnu.org/licenses/agpl.html>.

-- | This is a wrapper around a 'Dao.Interval.Set' specialized for 'Prelude.Char' characters. It is
-- useful for building regular expressions and lexers for use with the functions in the
-- "Dao.Grammar" module.
module Dao.Text.CharSet where

import qualified Dao.Interval as Iv
import           Dao.Text.PPrint
import           Dao.TestNull

import           Control.Applicative
import           Control.DeepSeq

import           Data.Char
import           Data.Ix
import           Data.Monoid
import           Data.Typeable

import           Numeric

-- | A part of a regular expression constructed from intervals of characters.
newtype CharSet = CharSet { charIntervalSet :: Iv.Set Char } deriving (Eq, Ord, Typeable)

instance TestNull CharSet where
  nullValue = CharSet Iv.empty
  testNull (CharSet a) = Iv.null a

instance Monoid CharSet where { mempty = nullValue; mappend = csetUnion; }

instance NFData CharSet where { rnf (CharSet o) = deepseq o (); }

instance PPrintable CharSet where
  pPrint cs =
    let ch c = pText $ case c of
            '-'           -> "\\-"
            '~'           -> "\\~"
            '\\'          -> "\\\\"
            '['           -> "\\["
            ']'           -> "\\]"
            '('           -> "\\("
            ')'           -> "\\)"
            '\n'          -> "\\n"
            '\r'          -> "\\r"
            '\t'          -> "\\t"
            '\f'          -> "\\f"
            '\v'          -> "\\v"
            c | isPrint c -> [c]
            c             -> "\\x" ++ (toUpper <$> showHex (ord c) "")
        prin o = case o of
          (a, b) | a==b -> [ch a]
          (a, b) | a>minBound && b<maxBound -> [ch a, pChar '-', ch b]
          (a, b) | a==minBound              -> [pText "[-", ch b, ch ']']
          (a, b) | b==maxBound              -> [ch '[', ch a, pText "-]"]
          (_, _)                            -> [pChar '.']
        (notInverted, pairs) = csetDecompose cs
    in  pText (if notInverted then "[" else "[^") : (pairs >>= prin) ++ [pChar ']']

instance Show CharSet where { show = showPPrint 4 80 . pPrint; }

-- | Construct a 'CharSet' containing all character intervals given.
within :: [(Char, Char)] -> CharSet
within = CharSet . Iv.fromPairs

-- | Construct an 'CharSet' excluding all character intervals given.
without :: [(Char, Char)] -> CharSet
without = csetNot . within

-- | Construct a 'CharSet' from a list of 'Prelude.Char's.
anyOf :: [Char] -> CharSet
anyOf = CharSet . Iv.fromPoints

-- | Construct a 'CharSet' from a list of 'Prelude.Char's.
noneOf :: [Char] -> CharSet
noneOf = csetNot . anyOf

-- | This creates the 'CharSet' that matches any character at all.
anyChar :: CharSet
anyChar = CharSet Iv.whole

csetNot :: CharSet -> CharSet
csetNot (CharSet cs) = CharSet $ Iv.invert cs

-- | Perform a set-intersection on two 'CharSet's.
csetUnion :: CharSet -> CharSet -> CharSet
csetUnion (CharSet a) (CharSet b) = CharSet $ Iv.union a b

-- | Perform a set-intersection on two 'CharSet's.
csetIntersect :: CharSet -> CharSet -> CharSet
csetIntersect (CharSet a) (CharSet b) = CharSet $ Iv.intersect a b

-- | Delete the characters in the first set that are also in the second set.
csetDelete :: CharSet -> CharSet -> CharSet
csetDelete (CharSet a) (CharSet b) = CharSet $ Iv.delete a b

-- | Evaluates to 'Prelude.True' if a given 'Prelude.Char' is an element of the given 'CharSet'.
csetMember :: CharSet -> Char -> Bool
csetMember (CharSet cs) = Iv.member cs

-- | Indicates how many different characters could match this 'CharSet'.
csetSize :: CharSet -> Int
csetSize = Iv.enumSize . charIntervalSet

-- | Evaluates to 'Prelude.True' if this 'CharSet' matches every possible character.
csetAll :: CharSet -> Bool
csetAll = Iv.isWhole . charIntervalSet

-- This function is mostly used internally to create lexer tables. It takes a 'CharSet' and
-- convertes it to a 'Dao.Interval.Set' containing the smallest possible intervals. This may require
-- inverting the set, to decrease the interval sizes. If the set is inverted, the 'Prelude.Bool'
-- value returned will be 'Prelude.False' to indicate the negative. If the set was not inverted, the
-- 'Prelude.Bool' value returned will be 'Prelude.True', to indicate the positive.
csetDecompose :: CharSet -> (Bool, [(Char, Char)])
csetDecompose csA = if size csA <= size csB then (True, elems csA) else (False, elems csB) where
  csB   = csetNot csA
  size  = length . Iv.toList . charIntervalSet
  elems = fmap Iv.toBoundedPair . Iv.toList . charIntervalSet

-- | Get the lowest and highest character in the set, if any characters exist in this 'CharSet'.
csetBounds :: CharSet -> Maybe (Char, Char)
csetBounds (CharSet cs) = Iv.toBoundedPair <$> Iv.intervalSpanAll (Iv.toList cs)

-- | Get the list of all of the 'Prelude.Char's that exist in this 'CharSet'.
csetRange :: CharSet -> [Char]
csetRange (CharSet cs) = Iv.toBoundedPair <$> Iv.toList cs >>= range

-- | The 'Dao.Text.CharSet.CharSet' for base-sixteen digits.
csetBase16 :: CharSet
csetBase16 = within [('0', '9'), ('A', 'F'), ('a', 'f')]

-- | The 'Dao.Text.CharSet.CharSet' for base-eight digits.
csetBase8 :: CharSet
csetBase8 = within [('0', '7')]

-- | The 'Dao.Text.CharSet.CharSet' for base-ten digits.
csetBase10 :: CharSet
csetBase10 = within [('0', '9')]

-- | A 'Dao.Text.CharSet.CharSet' for uppercase characters.
uppercase :: CharSet
uppercase = within [('A', 'Z')]

-- | A 'Dao.Text.CharSet.CharSet' for uppercase characters including the underscore character.
uppercase_ :: CharSet
uppercase_ = within [('A', 'Z'), ('_', '_')]

-- | A 'Dao.Text.CharSet.CharSet' for lowercase characters.
lowercase :: CharSet
lowercase = within [('a', 'z')]

-- | A 'Dao.Text.CharSet.CharSet' for lowercase characters including the underscore character.
lowercase_ :: CharSet
lowercase_ = within [('a', 'z'), ('_', '_')]

-- | A 'Dao.Text.CharSet.CharSet' for alphabetical (both 'uppercase' and 'lowercase') characters.
alphabetical :: CharSet
alphabetical = uppercase <> lowercase

-- | A 'Dao.Text.CharSet.CharSet' for alphabetical (both 'uppercase' and 'lowercase') characters.
alphabetical_ :: CharSet
alphabetical_ = uppercase <> lowercase_

-- | A 'Dao.Text.CharSet.CharSet' for 'alphabetical' and 'csetBase10' characters.
alphanumerical :: CharSet
alphanumerical = alphabetical <> csetBase10

-- | A 'Dao.Text.CharSet.CharSet' for 'alphabetical' and 'csetBase10' characters including the
-- underscore character.
alphanumerical_ :: CharSet
alphanumerical_ = alphabetical_ <> csetBase10


