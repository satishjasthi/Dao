-- "src/Dao/NewParser.hs"  a parser for defining general context-free
-- grammars that are parsed in two phases: the lexical and the
-- syntactic analysis phases.
-- 
-- Copyright (C) 2008-2013  Ramin Honary.
-- This file is part of the Dao System.
--
-- The Dao System is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
-- 
-- The Dao System is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program (see the file called "LICENSE"). If not, see
-- <http://www.gnu.org/licenses/agpl.html>.


{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Dao.NewParser where

import           Dao.String
import           Dao.Predicate

import           Control.Applicative
import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Error

import           Data.Monoid
import           Data.Typeable
import           Data.Maybe
import           Data.Word
import           Data.Char  hiding (Space)
import           Data.List
import           Data.Array.IArray
import qualified Data.Map    as M
import qualified Data.IntMap as IM

import           System.IO

import Debug.Trace

type LineNum   = Word
type ColumnNum = Word
type TabWidth  = Word

----------------------------------------------------------------------------------------------------

-- | Used mostly by 'Dao.Parser' and 'Dao.Object.Parser' but is also used to report location of
-- errors and are stored in the abstract syntax tree, 'ObjectExpr', 'ScriptExpr'.
data Location
  = LocationUnknown
  | Location -- ^ the 'Location' but without the starting/ending character count
    { startingLine   :: LineNum
    , startingColumn :: ColumnNum
    , endingLine     :: LineNum
    , endingColumn   :: ColumnNum
    }
  deriving (Eq, Typeable)

atPoint :: LineNum -> ColumnNum -> Location
atPoint a b =
  Location
  { startingLine   = a
  , endingLine     = a
  , startingColumn = b
  , endingColumn   = b
  }

instance Ord Location where
  compare a b = case (a,b) of
    (LocationUnknown, LocationUnknown) -> EQ
    (_              , LocationUnknown) -> LT
    (LocationUnknown, _              ) -> GT
    (a              , b              ) ->
      compare (abs(ela-sla), abs(eca-sca), sla, sca) (abs(elb-slb), abs(ecb-scb), slb, scb)
    where
      sla = startingLine   a
      ela = endingLine     a
      slb = startingLine   b
      elb = endingLine     b
      sca = startingColumn a
      eca = endingColumn   a
      scb = startingColumn b
      ecb = endingColumn   b
  -- ^ Greater-than is determined by a heuristic value of how large and uncertain the position of
  -- the error is. If the exact location is known, it has the lowest uncertainty and is therefore
  -- less than a location that might occur across two lines. The 'LocationUnknown' value is the most
  -- uncertain and is greater than everything except itself. Using this comparison function, you can
  -- sort lists of locations from least to greatest and hopefully get the most helpful, most
  -- specific location at the top of the list.

-- | The the coordinates from a 'Location':
-- @(('startingLine', 'startingColumn'), ('endingLine', 'endingColumn'))@
locationCoords :: Location -> Maybe ((LineNum, ColumnNum), (LineNum, ColumnNum))
locationCoords loc = case loc of
  LocationUnknown -> Nothing
  _ -> Just ((startingLine loc, startingColumn loc), (endingLine loc, endingColumn loc))

class HasLocation a where
  getLocation :: a -> Location
  setLocation :: a -> Location -> a

instance Show Location where
  show t = case t of
    LocationUnknown -> ""
    _ -> show (startingLine t) ++ ':' : show (startingColumn t)

instance Monoid Location where
  mempty =
    Location
    { startingLine   = 0
    , startingColumn = 0
    , endingLine     = 0
    , endingColumn   = 0
    }
  mappend loc a = case loc of
    LocationUnknown -> a
    _ -> case a of
      LocationUnknown -> loc
      _ ->
        loc
        { startingLine   = min (startingLine   loc) (startingLine   a)
        , startingColumn = min (startingColumn loc) (startingColumn a)
        , endingLine     = max (endingLine     loc) (endingLine     a)
        , endingColumn   = max (endingColumn   loc) (endingColumn   a)
        }

data GenToken tok
  = GenEmptyToken { tokType :: tok }
  | GenCharToken { tokType :: tok, tokChar :: !Char }
  | GenToken { tokType :: tok, tokUStr :: UStr }
instance Show tok => Show (GenToken tok) where
  show tok = show (tokType tok) ++ " " ++ show (tokToUStr tok)

class HasLineNumber   a where { lineNumber   :: a -> LineNum }
class HasColumnNumber a where { columnNumber :: a -> ColumnNum }

tokToUStr :: GenToken tok -> UStr
tokToUStr tok = case tok of
  GenEmptyToken _   -> nil
  GenCharToken  _ c -> ustr [c]
  GenToken      _ u -> u

tokToStr :: GenToken tok -> String
tokToStr tok = case tok of
  GenEmptyToken _   -> ""
  GenCharToken  _ c -> [c]
  GenToken      _ u -> uchars u

data GenTokenAt tok =
  GenTokenAt
  { tokenAtLineNumber   :: LineNum
  , tokenAtColumnNumber :: ColumnNum
  , getToken            :: GenToken tok
  }
instance HasLineNumber   (GenTokenAt tok) where { lineNumber   = tokenAtLineNumber   }
instance HasColumnNumber (GenTokenAt tok) where { columnNumber = tokenAtColumnNumber }

data GenLine tok
  = GenLine
    { lineLineNumber :: LineNum
    , lineTokens     :: [(ColumnNum, GenToken tok)]
      -- ^ a list of tokens, each with an associated column number.
    }

instance HasLineNumber (GenLine tok) where { lineNumber = lineLineNumber }

instance Show tok => Show (GenLine tok) where
  show line = show (lineLineNumber line) ++ ": " ++ show (lineTokens line)

----------------------------------------------------------------------------------------------------

-- | This is the state used by every 'GenLexer'.
data GenLexerState tok
  = GenLexerState
    { lexTabWidth      :: TabWidth
    , lexCurrentLine   :: LineNum
    , lexCurrentColumn :: ColumnNum
    , lexTokenCounter  :: Word
      -- ^ some algorithms would like to know if you lexed any tokens at all, and will fail if you
      -- did not. There needs to be some way of knowing how many tokens your 'GenLexer' created.
    , tokenStream      :: [GenTokenAt tok]
    , lexBuffer        :: String
      -- ^ stores the characters consumed by 'GenLexer's. This buffer is never cleared until
      -- 'makeToken' is evaluated. Retrieve this string using:
      -- > 'Control.Monad.State.gets' 'lexBuffer'
    , lexInput         :: String
      -- ^ contains the remainder of the input string to be analyzed. Retrieve this string using:
      -- > 'Control.Monad.State.gets' 'lexInput'
    }

-- | Create a new lexer state using the given input 'Prelude.String'. This is only realy useful if
-- you must evaluate 'runLexerState'.
newLexerState :: (Show tok, Eq tok, Enum tok) => String -> GenLexerState tok
newLexerState input =
  GenLexerState
  { lexTabWidth      = 4
  , lexTokenCounter  = 0
  , lexCurrentLine   = 1
  , lexCurrentColumn = 1
  , tokenStream      = []
  , lexBuffer        = ""
  , lexInput         = input
  }

-- | The 'GenLexer' is very similar in many ways to regular expressions, however 'GenLexer's always
-- begin evaluating at the beginning of the input string. The 'lexicalAnalysis' phase of parsing
-- must generate 'GenToken's from the input string. 'GenLexer's provide you the means to do with
-- primitive functions like 'lexString', 'lexChar', and 'lexUntil', and combinators like 'defaultTo'
-- and 'lexUntilTermChar'. These primitive functions collect characters into a buffer, and you can
-- then empty the buffer and use the buffered characters to create a 'GenToken' using the
-- 'makeToken' function.
-- 
-- 'GenLexer' instantiates 'Control.Monad.State.MonadState', 'Control.Monad.Error.MonadError',
-- 'Control.Monad.MonadPlus', and of course 'Control.Monad.Monad' and 'Data.Functor.Functor'. The
-- 'Control.Monad.fail' function is overloaded such that it does not evaluate to an exception, such
-- that it can halt 'lexecialAnalysis' and also provide useful information about the failure.
-- 'Control.Monad.Error.throwError' can also be used, and 'Control.Monad.Error.catchError' will
-- catch errors thrown by 'Control.Monad.Error.throwError' and 'Control.Monad.fail'.
-- 'Control.Monad.mzero' causes backtracking. Be careful when recovering from backtracking using
-- 'Control.Monad.mplus' because the 'lexBuffer' is not cleared. It is usually better to backtrack
-- using 'lexBacktrack' (or don't backtrack at all, because it is inefficient). However you don't
-- need to worry too much; if a 'GenLexer' backtracks while being evaluated in 'lexicalAnalysis' the
-- 'lexInput' will not be affected at all and the 'lexBuffer' is ingored entirely.
newtype GenLexer tok a = GenLexer{
    runLexer :: PTrans (GenParseError (GenLexerState tok) tok) (State (GenLexerState tok)) a
  }
instance (Show tok, Eq tok, Enum tok) =>
  Functor (GenLexer tok) where { fmap fn (GenLexer lex) = GenLexer (fmap fn lex) }
instance (Show tok, Eq tok, Enum tok) =>
  Monad (GenLexer tok) where
    (GenLexer fn) >>= mfn          = GenLexer (fn >>= runLexer . mfn)
    return                         = GenLexer . return
    fail msg                       = do
      st <- get
      throwError $
        (parserErr (lexCurrentLine st) (lexCurrentColumn st)){parseErrMsg = Just (ustr msg)}
instance (Show tok, Eq tok, Enum tok) =>
  MonadPlus (GenLexer tok) where
    mplus (GenLexer a) (GenLexer b) = GenLexer (mplus a b)
    mzero                           = GenLexer mzero
instance (Show tok, Eq tok, Enum tok) =>
  Applicative (GenLexer tok) where { pure = return; (<*>) = ap; }
instance (Show tok, Eq tok, Enum tok) =>
  Alternative (GenLexer tok) where { empty = mzero; (<|>) = mplus; }
instance (Show tok, Eq tok, Enum tok) =>
  MonadState (GenLexerState tok) (GenLexer tok) where
    get = GenLexer (lift get)
    put = GenLexer . lift . put
instance (Show tok, Eq tok, Enum tok) =>
  MonadError (GenParseError (GenLexerState tok) tok) (GenLexer tok) where
    throwError                        = GenLexer . throwError
    catchError (GenLexer try) catcher = GenLexer (catchError try (runLexer . catcher))
instance (Show tok, Eq tok, Enum tok) =>
  MonadPlusError (GenParseError (GenLexerState tok) tok) (GenLexer tok) where
    catchPValue (GenLexer try) = GenLexer (catchPValue try)
    assumePValue               = GenLexer . assumePValue
instance (Show tok, Eq tok, Enum tok, Monoid a) =>
  Monoid (GenLexer tok a) where { mempty = return mempty; mappend a b = liftM2 mappend a b; }

-- | Append the first string parameter to the 'lexBuffer', and set the 'lexInput' to the value of
-- the second string parameter. Most lexers simply takes the input, breaks it, then places the two
-- halves back into the 'LexerState', which is what this function does. *Be careful* you don't pass
-- the wrong string as the second parameter. Or better yet, don't use this function.
lexSetState :: (Show tok, Eq tok, Enum tok) => String -> String -> GenLexer tok ()
lexSetState got remainder = modify $ \st ->
  st{lexBuffer = lexBuffer st ++ got, lexInput = remainder}

-- | Unlike simply evaluating 'Control.Monad.mzero', 'lexBacktrack' will push the contents of the
-- 'lexBuffer' back onto the 'lexInput'. This is inefficient, so if you rely on this too often you
-- should probably re-think the design of your lexer.
lexBacktrack :: (Show tok, Eq tok, Enum tok) => GenLexer tok ig
lexBacktrack = modify (\st -> st{lexBuffer = "", lexInput = lexBuffer st ++ lexInput st}) >> mzero

-- | Single character look-ahead, never consumes any tokens, never backtracks unless we are at the
-- end of input.
lexLook1 :: (Show tok, Eq tok, Enum tok) => GenLexer tok Char
lexLook1 = gets lexInput >>= \input -> case input of { "" -> mzero ; c:_ -> return c }

-- | Arbitrary look-ahead, creates a and returns copy of the portion of the input string that
-- matches the predicate. This function never backtracks, and it might be quite inefficient because
-- it must force strict evaluation of all characters that match the predicate.
lexCopyWhile :: (Show tok, Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok String
lexCopyWhile predicate = fmap (takeWhile predicate) (gets lexInput)

-- | A fundamental 'Lexer', uses 'Data.List.break' to break-off characters from the input string
-- until the given predicate evaluates to 'Prelude.True'. Backtracks if no characters are lexed.
-- See also: 'charSet' and 'unionCharP'.
lexWhile :: (Show tok, Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexWhile predicate = do
  (got, remainder) <- fmap (span predicate) (gets lexInput)
  if null got then mzero else lexSetState got remainder

-- | Like 'lexUnit' but inverts the predicate, lexing until the predicate does not match. This
-- function is defined as:
-- > \predicate -> 'lexUntil' ('Prelude.not' . predicate)
-- See also: 'charSet' and 'unionCharP'.
lexUntil :: (Show tok, Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexUntil predicate = lexWhile (not . predicate)

-- lexer: update line/column with string
lexUpdLineColWithStr :: (Show tok, Eq tok, Enum tok) => String -> GenLexer tok ()
lexUpdLineColWithStr input = do
  st <- get
  let tablen = lexTabWidth st
      countNLs lns cols input = case break (=='\n') input of
        (""    , ""        ) -> (lns, cols)
        (_     , '\n':after) -> countNLs (lns+1) 0 after
        (before, after     ) -> (lns, cols + foldl (+) 0 (map charPrintWidth (before++after)))
      charPrintWidth c = case c of
        c | c=='\t'   -> tablen
        c | isPrint c -> 1
        c             -> 0
      (newLine, newCol) = countNLs (lexCurrentLine st) (lexCurrentColumn st) input
  put (st{lexCurrentLine=newLine, lexCurrentColumn=newCol})

-- | Create a 'GenToken' using the contents of the 'lexBuffer', then clear the 'lexBuffer'. This
-- function backtracks if the 'lexBuffer' is empty. If you pass "Prelude.False' as the first
-- parameter the tokens in the 'lexBuffer' are not stored with the token, the token will only
-- contain the type.
makeGetToken  :: (Show tok, Eq tok, Enum tok) => Bool -> tok -> GenLexer tok (GenToken tok)
makeGetToken storeChars typ = do
  st <- get
  let str = lexBuffer st
  token <- case str of
    []               -> mzero
    [c] | storeChars -> return $ GenCharToken{tokType=typ, tokChar=c}
    cx  | storeChars -> return $ GenToken{tokType=typ, tokUStr=ustr str}
    _                -> return $ GenEmptyToken{tokType=typ}
  put $
    st{ lexBuffer   = ""
      , tokenStream = tokenStream st ++
          [ GenTokenAt
            { tokenAtLineNumber   = lexCurrentLine   st
            , tokenAtColumnNumber = lexCurrentColumn st
            , getToken            = token
            } ]
      , lexTokenCounter = lexTokenCounter st + 1
      }
  lexUpdLineColWithStr str
  return token

-- | Create a token in the stream without returning it (you usually don't need the token anyway). If
-- you do need the token, use 'makeGetToken'.
makeToken :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
makeToken = void . makeGetToken True

-- | Create a token in the stream without returning it (you usually don't need the token anyway). If
-- you do need the token, use 'makeGetToken'. The token created will not store any characters, only
-- the type of the token. This can save a lot of memory, but it requires you have very descriptive
-- token types.
makeEmptyToken :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
makeEmptyToken = void . makeGetToken False

-- | Clear the 'lexBuffer' without creating a token.
clearBuffer :: (Show tok, Eq tok, Enum tok) => GenLexer tok ()
clearBuffer = get >>= \st -> lexUpdLineColWithStr (lexBuffer st) >> put (st{lexBuffer=""})

-- | A fundamental lexer using 'Data.List.stripPrefix' to check whether the given string is at the
-- very beginning of the input.
lexString :: (Show tok, Eq tok, Enum tok) => String -> GenLexer tok ()
lexString str =
  gets lexInput >>= assumePValue . maybeToBacktrack . stripPrefix str >>= lexSetState str

-- | A fundamental lexer succeeding if the next 'Prelude.Char' in the 'lexInput' matches the
-- given predicate. See also: 'charSet' and 'unionCharP'.
lexCharP ::  (Show tok, Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexCharP predicate = gets lexInput >>= \input -> case input of
  c:input | predicate c -> lexSetState [c] input
  _                     -> mzero

-- | Succeeds if the next 'Prelude.Char' on the 'lexInput' matches the given 'Prelude.Char'
lexChar :: (Show tok, Eq tok, Enum tok) => Char -> GenLexer tok ()
lexChar c = lexCharP (==c)

-- | *Not a 'GenLexer'* but useful when passed as the first parameter to 'lexCharP', 'lexWhile' or
-- 'lexUntil'. This function creates a predicate over 'Prelude.Chars's that evaluates to
-- 'Prelude.True' if the 'Prelude.Char' is equal to any of the 'Prelude.Char's in the given
-- 'Prelude.String'. This is similar to the behavior of character sets in POSIX regular expressions:
-- the Regex @[abcd]@ matches the same characters as the predicate @('charSet' "abcd")@
charSet :: String -> Char -> Bool
charSet charset c = or $ map (c==) $ nub charset

-- | *'Not a 'GenLexer'* but useful when passed as the first parameter to 'lexCharP', 'lexWhile' or
-- 'lexUntil'.This function creates a simple set-union of predicates to create a new predicate on
-- 'Prelude.Char's. The predicate evalautes to 'Prelude.True' if the 'Prelude.Char' applied to any
-- of the predicates evaluate to 'Prelude.True'. This is similar to unions of character ranges in
-- POSIX regular expressions: the Regex @[[:xdigit:]xyzXYZ]@ matches the same characters as the
-- predicate:
-- > ('unionCharP' [isHexDigit, charSet "xyzXYZ"])
unionCharP :: [Char -> Bool] -> Char -> Bool
unionCharP px c = or (map ($c) px)

-- | Unions the 'Data.Char.isSymbol' and 'Data.Char.isPunctuation' predicates.
isSymPunct :: Char -> Bool
isSymPunct c = isSymbol c || isPunctuation c

-- | This is a character predicate I find very useful and I believe it should be included in the
-- standard Haskell "Data.Char" module, it is succeeds for alpha-numeric or underscore character.
isAlphaNum_ :: Char -> Bool
isAlphaNum_ c = isAlphaNum c || c=='_'

-- | This is a character predicate I find very useful and I believe it should be included in the
-- standard Haskell "Data.Char" module, it is succeeds for alpha-numeric or underscore character.
isAlpha_ :: Char -> Bool
isAlpha_ c = isAlpha c || c=='_'

lexOptional :: (Show tok, Eq tok, Enum tok) => GenLexer tok () -> GenLexer tok ()
lexOptional lexer = mplus lexer (return ())

-- | Backtracks if there are still characters in the input.
lexEOF :: (Show tok, Eq tok, Enum tok) => GenLexer tok ()
lexEOF = fmap (=="") (gets lexInput) >>= guard

-- | Create a 'GenLexer' that will continue scanning until it sees an unescaped terminating
-- sequence. You must provide three lexers: the scanning lexer, the escape sequence 'GenLexer' and
-- the terminating sequence 'GenLexer'. Evaluates to 'Prelude.True' if the termChar was found,
-- returns 'Prelude.False' if this tokenizer went to the end of the input without seenig an
-- un-escaped terminating character.
lexUntilTerm
  :: (Show tok, Eq tok, Enum tok)
  => GenLexer tok () -> GenLexer tok () -> GenLexer tok () -> GenLexer tok Bool
lexUntilTerm scanLexer escLexer termLexer = loop where
  skipOne = lexCharP (const True)
  loop = do
    (shouldContinue, wasTerminated) <- msum $
      [ lexEOF    >> return (False, False)
      , termLexer >> return (False, True )
      , escLexer  >>
          mplus (lexEOF                              >> return (False, False))
                (msum [termLexer, escLexer, skipOne] >> return (True , False))
      , scanLexer >> return (True , False)
      , skipOne   >> return (True , False)
      ]
    if shouldContinue then loop else return wasTerminated

-- | A special case of 'lexUntilTerm', lexes until it finds an un-escaped terminating
-- 'Prelude.Char'. You must only provide the escape 'Prelude.Char' and the terminating
-- 'Prelude.Char'.
lexUntilTermChar :: (Show tok, Eq tok, Enum tok) => Char -> Char -> GenLexer tok Bool
lexUntilTermChar escChar termChar =
  lexUntilTerm (lexUntil (\c -> c==escChar || c==termChar)) (lexChar escChar) (lexChar termChar)

-- | A special case of 'lexUntilTerm', lexes until finds an un-escaped terminating 'Prelude.String'.
-- You must provide only the escpae 'Prelude.String' and the terminating 'Prelude.String'. You can
-- pass a null string for either escape or terminating strings (passing null for both evaluates to
-- an always-backtracking lexer). The most escape and terminating strings are analyzed and the most
-- efficient method of lexing is decided, so this lexer is guaranteed to be as efficient as
-- possible.
lexUntilTermStr :: (Show tok, Eq tok, Enum tok) => String -> String -> GenLexer tok Bool
lexUntilTermStr escStr termStr = case (escStr, termStr) of
  (""    , ""     ) -> mzero
  (""    , termStr) -> hasOnlyTerm termStr
  (escStr, ""     ) -> hasOnlyTerm escStr
  _                 -> do
    let e = head escStr
        t = head termStr
        predicate = if e==t then (==t) else (\c -> c==e || c==t)
    lexUntilTerm (lexUntil predicate) (lexString escStr) (lexString termStr)
  where
    hasOnlyTerm str = do
      let (scan, term) = case str of
            [a]          -> (lexUntil (==a), lexChar a)
            [a,b] | a/=b -> (lexUntil (==a), lexWhile (==a) >> lexChar b)
            a:ax         ->
              (lexUntil (==a), let loop = mplus (lexString str) (lexChar a >> loop) in loop)
      lexUntilTerm scan term term

-- | Takes three parameters. (1) A label for this set of 'GenLexer's used in error reporting.
-- (2) A halting predicate which backtracks if there is more tokenizing to be done, and succeeds
-- when this tokenizer is done. (3) A list of 'GenLexer's that will each be tried in turn. This
-- function loops, first trying the halting predicate, and then trying the 'GenLexer' list, and
-- looping continues until the halting predicate succeeds or fails if the 'GenLexer' list
-- backtracks. If the 'GenLexer' list backtracks, the error message is
-- > "unknown characters scanned by $LABEL tokenizer"
-- where @$LABEL@ is the string passed as parameter 1.
runLexerLoop
  :: (Show tok, Eq tok, Enum tok)
  => String -> GenLexer tok () -> [GenLexer tok ()] -> GenLexer tok ()
runLexerLoop msg predicate lexers = loop 0 where
  loop i = do
    s <- gets lexInput
    shouldContinue <- msum $
      [ predicate >> return False
      , msum lexers >> return True
      , fail ("unknown characters scanned by "++msg++" tokenizer")
      ]
    seq shouldContinue $! if shouldContinue then loop (i+1) else return ()

----------------------------------------------------------------------------------------------------
-- Functions that facilitate lexical analysis.

-- | The fundamental lexer: takes a predicate over characters, if one or more characters
-- matches, a token is constructed and it is paired with the remaining string and wrapped into a
-- 'Data.Maybe.Just' value. Otherwise 'Data.Maybe.Nothing' is returned. The 'Data.Maybe.Maybe' type
-- is used so you can combine fundamental tokenizers using 'Control.Monad.mplus'.
lexSimple :: (Show tok, Eq tok, Enum tok) => tok -> (Char -> Bool) -> GenLexer tok ()
lexSimple tok predicate = lexWhile predicate >> makeToken tok

-- | A fundamental lexer using 'Data.Char.isSpace' and evaluating to a 'Space' token.
lexSpace :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexSpace tok = lexSimple tok isSpace

-- | A fundamental lexer using 'Data.Char.isAlpha' and evaluating to a 'Alphabetic' token.
lexAlpha :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexAlpha tok = lexSimple tok isAlpha

-- | A fundamental lexer using 'Data.Char.isDigit' and evaluating to a 'Digits' token.
lexDigits :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexDigits tok = lexSimple tok isDigit

-- | A fundamental lexer using 'Data.Char.isHexDigit' and evaluating to a 'HexDigit' token.
lexHexDigits :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexHexDigits tok = lexSimple tok isHexDigit

-- | Constructs an operator 'GenLexer' from a string of operators separated by spaces. For example,
-- pass @"+ += - -= * *= ** / /= % %= = == ! !="@ to create 'Lexer' that will properly parse all of
-- those operators. The order of the operators is *NOT* important, repeat symbols are tried only
-- once, the characters @+=@ are guaranteed to be parsed as a single operator @["+="]@ and not as
-- @["+", "="]@. *No token is created,* you must create your token using 'makeToken' or
-- 'makeEmptyToken' immediately after evaluating this tokenizer.
lexOperator :: (Show tok, Eq tok, Enum tok) => String -> GenLexer tok ()
lexOperator ops =
  msum (map (\op -> lexString op) $ reverse $ nub $ sortBy len $ words ops)
  where
    len a b = case compare (length a) (length b) of
      EQ -> compare a b
      GT -> GT
      LT -> LT

lexToEndline :: (Show tok, Eq tok, Enum tok) => GenLexer tok ()
lexToEndline = lexUntil (=='\n')

lexInlineComment :: (Show tok, Eq tok, Enum tok) => tok -> String -> String -> GenLexer tok ()
lexInlineComment tok startStr endStr = do
  lexString startStr
  completed <- lexUntilTermStr "" endStr
  if completed
    then  makeToken tok
    else  fail "comment runs past end of input"

lexInlineC_Comment :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexInlineC_Comment tok = lexInlineComment tok "/*" "*/"

lexEndlineC_Comment :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineC_Comment tok = lexString "//" >> lexUntil (=='\n') >> makeToken tok

lexInlineHaskellComment :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexInlineHaskellComment tok = lexInlineComment tok "{-" "-}"

lexEndlineHaskellComment :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineHaskellComment tok = lexString "--" >> lexToEndline >> makeToken tok

-- | A lot of programming languages provide only end-line comments beginning with a (@#@) character.
lexEndlineCommentHash :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineCommentHash tok = lexChar '#' >> lexToEndline >> makeToken tok

lexStringLiteral :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexStringLiteral tok = do
  lexChar '"'
  completed <- lexUntilTermChar '\\' '"'
  if completed
    then  makeToken tok
    else  fail "string literal expression runs past end of input"

lexCharLiteral :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexCharLiteral tok = lexChar '\'' >> lexUntilTermChar '\\' '\'' >> makeToken tok

-- | This actually tokenizes a general label: alpha-numeric and underscore characters starting with
-- an alphabetic or underscore character. This is useful for several programming languages.
-- Evaluates to a 'Keyword' token type, it is up to the 'SimParser's in the syntacticAnalysis phase
-- to sort out which 'Keyword's are actually keywords and which are labels for things like variable
-- names.
lexKeyword :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexKeyword tok = do
  lexWhile (\c -> isAlpha c || c=='_')
  lexOptional (lexWhile (\c -> isAlphaNum c || c=='_'))
  makeToken tok

-- | Create a 'GenLexer' that lexes the various forms of numbers. If the number contains no special
-- modification, i.e. no hexadecimal digits, no decimal points, and no exponents, a 'Digits' token
-- is returned. Anything more exotic than simple base-10 digits and a 'Number' token is returned. If
-- the 'Number' is expressed in base-10 and also has an exponent, like @6.022e23@ where @e23@ is the
-- exponent or @1.0e-10@ where @e-10@ is the exponent, then 'NumberExp' is returned.
-- 
-- Hexadecimal and binary number expressions are also tokenized, the characters @'x'@, @'X'@, @'b'@,
-- and @'B'@ are all prefixes to a string of hexadecimal digits (tokenized with
-- 'Data.Char.isHexDigit'). So the following expression are all parsed as 'Number' tokens:
-- > 0xO123456789ABCDEfabcdef, 0XO123456789ABCDEfabcdef, 0bO123456789, 0BO123456789
-- these could all be valid hexadecimal or binary numbers. Of course @0bO123456789@ is
-- not a valid binary number, but this lexer does not care about the actual value, it is expected
-- that the 'SimParser' report it as an error during the 'syntacticAnalysis' phase. Floating-point
-- decimal numbers are also lexed appropriately, and this includes floating-point numbers expressed
-- in hexadecimal. Again, if your language must disallow hexadecimal floating-point numbers, throw
-- an error in the 'syntacticAnalysis' phase.
lexNumber :: (Show tok, Eq tok, Enum tok) => tok -> tok -> tok -> tok -> GenLexer tok ()
lexNumber digits hexDigits number numberExp = do
  let altBase typ xb@(u:l:_) pred = do
        lexCharP (charSet xb)
        mplus (lexWhile pred) (fail ("no digits after "++typ++" 0"++l:" token"))
  (getDot, isHex) <- msum $
    [ do  lexChar '0' -- lex a leading zero
          msum $
            [ altBase "hexadecimal" "Xx" isHexDigit >> return (True , True )
            , altBase "binary"      "Bb" isDigit    >> return (True , False)
            , lexWhile isDigit                      >> return (True , False)
            , return (True , False)
              -- ^ a zero not followed by an 'x', 'b', or any other digits is also valid
            ]
    , lexChar '.' >> lexWhile isDigit >> return (False, False) -- lex a leading decimal point
    , lexWhile isDigit                >> return (True , False) -- lex an ordinary number
    , lexBacktrack
    ]
  (gotDot, gotExp) <- flip mplus (return (False, False)) $ do
    gotDot <-
      if getDot -- we do not have the dot?
        then  flip mplus (return False) $ do
                lexChar '.'
                mplus (lexWhile (if isHex then isHexDigit else isDigit))
                      (fail "no digits after decimal point")
                return True
        else  return True -- we already had the dot
    if isHex
      then  return (gotDot, False) -- don't look for an exponent
      else  flip mplus (return (gotDot, False)) $ do
              lexCharP (charSet "Ee")
              lexOptional (lexCharP (charSet "-+"))
              mplus (lexWhile isDigit)
                    (fail "no digits after exponent mark in decimal-point number")
              return (gotDot, True )
  makeToken $
    if gotDot || gotExp
      then  if gotExp then numberExp else number
      else  if isHex  then hexDigits else digits

-- | Creates a 'Label' token for haskell data type names, type names, class names, or constructors,
-- i.e. one or more labels (alpha-numeric and underscore characters) separated by dots (with no
-- spaces between the dots) where every first label is a capital alphabetic character, and the final
-- label may start with a lower-case letter or underscore, or the final label may also be
-- punctuation surrounded by parens. Examples are: @Aaa.Bbb@, @D.Ee_ee.ccc123@, @Aaa.Bbb.Ccc.___d1@,
-- @A.B.C.(-->)@.
lexHaskellLabel :: (Show tok, Eq tok, Enum tok) => tok -> GenLexer tok ()
lexHaskellLabel tok = loop 0 where
  label    = do
    lexCharP (\c -> isUpper c && isAlpha c)
    lexOptional (lexWhile isAlphaNum_)
  loop   i = mplus (label >> mplus (tryDot i) done) (if i>0 then final else mzero)
  tryDot i = lexChar '.' >> loop (i+1)
  final    = mplus (lexCharP isAlpha_ >> lexOptional (lexWhile isAlphaNum_)) oper >> done
  oper     = do lexChar '('
                mplus (lexWhile (\c -> c/=')' && isSymPunct c) >> lexChar ')')
                      (fail "bad operator token after final dot of label")
  done     = makeToken tok

-- | Takes a 'tokenStream' resulting from the evaulation of 'lexicalAnalysis' and breaks it into
-- 'GenLine's. This makes things a bit more efficient because it is not necessary to store a line
-- number with every single token. It is necessary for initializing a 'SimParser'.
tokenStreamToLines :: (Show tok, Eq tok, Enum tok) => [GenTokenAt tok] -> [GenLine tok]
tokenStreamToLines toks = loop toks where
  makeLine num toks =
    GenLine
    { lineLineNumber = num
    , lineTokens     = map (\t -> (tokenAtColumnNumber t, getToken t)) toks
    }
  loop toks = case toks of
    []     -> []
    t:toks ->
      let num           = tokenAtLineNumber t
          (line, toks') = span ((==num) . tokenAtLineNumber) (t:toks)
      in  makeLine num line : loop toks'

-- | The 'GenLexer's analogue of 'Control.Monad.State.runState', runs the lexer using an existing
-- 'LexerState'.
lexicalAnalysis
  :: (Show tok, Eq tok, Enum tok)
  => GenLexer tok a
  -> GenLexerState tok
  -> (PValue (GenParseError (GenLexerState tok) tok) a, GenLexerState tok)
lexicalAnalysis lexer st = runState (runPTrans (runLexer lexer)) st

testLexicalAnalysis_withFilePath
  :: (Show tok, Eq tok, Enum tok)
  => GenLexer tok () -> FilePath -> TabWidth -> String -> IO ()
testLexicalAnalysis_withFilePath tokenizer filepath tablen input = putStrLn report where
  (result, st) = lexicalAnalysis tokenizer ((newLexerState input){lexTabWidth=tablen})
  lines  = tokenStreamToLines (tokenStream st)
  more   = take 21 (lexInput st)
  remain = "\nremaining: "++(if length more > 20 then show (take 20 more)++"..." else show more)
  loc    = show (lexCurrentLine st) ++ ":" ++ show (lexCurrentColumn st)
  report = (++remain) $ intercalate "\n" (map showLine lines) ++ '\n' : case result of
    OK      _ -> "Success!"
    Backtrack -> reportFilepath ++ ": lexical analysis evalauted to \"Backtrack\""
    PFail err -> reportFilepath ++ show err
  showLine line = concat $
    [ "----------\nline "
    , show (lineNumber line), "\n"
    , intercalate ", " $ map showTok (lineTokens line)
    ]
  showTok (col, tok) = concat [show col, " ", show (tokType tok), " ", show (tokToUStr tok)]
  reportFilepath = (if null filepath then "" else filepath)++":"++loc

-- | Run the 'lexicalAnalysis' with the 'GenLexer' on the given 'Prelude.String' and print out
-- every token created.
testLexicalAnalysis
  :: (Show tok, Eq tok, Enum tok)
  => GenLexer tok () -> TabWidth -> String -> IO ()
testLexicalAnalysis a b c = testLexicalAnalysis_withFilePath a "" b c

-- | Run the 'lexicalAnalysis' with the 'GenLexer' on the contents of the file at the the given
-- 'System.IO.FilePath' 'Prelude.String' and print out every token created.
testLexicalAnalysisOnFile
  :: (Show tok, Eq tok, Enum tok)
  => GenLexer tok () -> TabWidth -> FilePath -> IO ()
testLexicalAnalysisOnFile a b c = readFile c >>= testLexicalAnalysis_withFilePath a c b

----------------------------------------------------------------------------------------------------
-- The parser data type

-- | This data structure is used by both the 'GenLexer' and 'SimParser' monads.
data GenParseError st tok
  = GenParseError
    { parseErrLoc     :: Maybe Location
    , parseErrMsg     :: Maybe UStr
    , parseErrTok     :: Maybe (GenToken tok)
    , parseStateAtErr :: Maybe st
    }

-- | Both 'GenParser' and 'SimParser' instantiate 'Control.Monad.Error.MonadError', however
-- there is a functional dependency between the error type and the monad. So there must be a wrapper
-- around the 'GenParseError' so 'SimParser' can instantiate while allowing the user-facing
-- 'GenParseError' to be manipulated directly in the 'GenParser' moand.
newtype SimParseError st tok = SimParseError { simGenParserErr :: GenParseError st tok }

instance Show tok =>
  Show (GenParseError st tok) where
    show err =
      let msg = concat $ map (fromMaybe "") $
            [ fmap (("(on token "++) . (++")") . show) (parseErrTok err)
            , fmap ((": "++) . uchars) (parseErrMsg err)
            ]
      in  if null msg then "Unknown parser error" else msg

instance Show tok => Show (SimParseError st tok) where { show = show . simGenParserErr }

-- | An initial blank parser error.
parserErr :: (Show tok, Eq tok, Enum tok) => LineNum -> ColumnNum -> GenParseError st tok
parserErr lineNum colNum =
  GenParseError
  { parseErrLoc = Just $
      Location
      { startingLine   = lineNum
      , startingColumn = colNum
      , endingLine     = lineNum
      , endingColumn   = colNum
      }
  , parseErrMsg = Nothing
  , parseErrTok = Nothing
  , parseStateAtErr = Nothing
  }

-- | 'parse' will evaluate the 'GenLexer' over the input string first. If the 'GenLexer' fails, it
-- will evaluate to a 'Dao.Prelude.PFail' value containing a 'GenParseError' value of type:
-- > ('Prelude.Eq' tok, 'Prelude.Enum' tok) => 'GenParseError' ('GenLexerState' tok)
-- However the 'SimParser's evaluate to 'GenParseError's containing type:
-- > ('Prelude.Eq' tok, 'Prelude.Enum' tok) => 'GenParseError' ('GenParserState' st tok)
-- This function provides an easy way to convert between the two 'GenParseError' types, however since
-- the state value @st@ is polymorphic, you will need to insert your parser state into the error
-- value after evaluating this function. For example:
-- > case tokenizerResult of
-- >    'Dao.Predicate.PFail' lexErr -> 'Dao.Predicate.PFail' (('lexErrToParseErr' lexErr){'parseStateAtErr' = Nothing})
-- >    ....
lexErrToParseErr
  :: (Show tok, Eq tok, Enum tok)
  => GenParseError (GenLexerState tok) tok
  -> GenParseError (GenParserState st tok) tok
lexErrToParseErr lexErr =
  lexErr
  { parseStateAtErr = Nothing
  , parseErrLoc = st >>= \st -> return (atPoint (lexCurrentLine st) (lexCurrentColumn st))
  }
  where { st = parseStateAtErr lexErr }

-- | The 'GenParserState' contains a stream of all tokens created by the 'lexicalAnalysis' phase.
-- This is the state associated with a 'SimParser' in the instantiation of 'Control.Mimport
-- Debug.Traceonad.State.MonadState', so 'Control.Monad.State.get' returns a value of this data
-- type.
data GenParserState st tok
  = GenParserState
    { userState   :: st
    , getLines    :: [GenLine tok]
    , recentTokens :: [(LineNum, ColumnNum, GenToken tok)]
      -- ^ single look-ahead is common, but the next token exists within the 'Prelude.snd' value
      -- within a pair within a list within the 'lineTokens' field of a 'GenLine' data structure.
      -- Rather than traverse that same path every time 'simNextToken' or 'withToken' is called, the
      -- next token is cached here.
    }

newParserState :: (Show tok, Eq tok, Enum tok) => st -> [GenLine tok] -> GenParserState st tok
newParserState st lines = GenParserState{userState = st, getLines = lines, recentTokens = []}

modifyUserState :: (Show tok, Eq tok, Enum tok) => (st -> st) -> SimParser st tok ()
modifyUserState fn = modify (\st -> st{userState = fn (userState st)})

-- | The task of the 'SimParser' monad is to look at every token in order and construct syntax trees
-- in the 'syntacticAnalysis' phase.
--
-- This function instantiates all the useful monad transformers, including 'Data.Functor.Functor',
-- 'Control.Monad.Monad', 'Control.MonadPlus', 'Control.Monad.State.MonadState',
-- 'Control.Monad.Error.MonadError' and 'Dao.Predicate.MonadPlusError'. Backtracking can be done
-- with 'Control.Monad.mzero' and "caught" with 'Control.Monad.mplus'. 'Control.Monad.fail' and
-- 'Control.Monad.Error.throwError' evaluate to a control value containing a 'GenParseError' value
-- which can be caught by 'Control.Monad.Error.catchError', and which automatically contain
-- information about the location of the failure and the current token in the stream that caused the
-- failure.
newtype SimParser st tok a
  = SimParser { parserToPTrans :: PTrans (SimParseError st tok) (State (GenParserState st tok)) a}
instance (Show tok, Eq tok, Enum tok) =>
  Functor   (SimParser st tok) where { fmap f (SimParser a) = SimParser (fmap f a) }
instance (Show tok, Eq tok, Enum tok) =>
  Monad     (SimParser st tok) where
    (SimParser ma) >>= mfa = SimParser (ma >>= parserToPTrans . mfa)
    return a               = SimParser (return a)
    fail msg = do
      ab  <- optional subGetCursor
      tok <- optional (simNextToken False)
      st  <- gets userState
      throwError $ SimParseError $
        GenParseError
        { parseErrLoc = fmap (uncurry atPoint) ab
        , parseErrMsg = Just (ustr msg)
        , parseErrTok = tok
        , parseStateAtErr = Just st
        }
instance (Show tok, Eq tok, Enum tok) =>
  MonadPlus (SimParser st tok) where
    mzero                             = SimParser mzero
    mplus (SimParser a) (SimParser b) = SimParser (mplus a b)
instance (Show tok, Eq tok, Enum tok) =>
  Applicative (SimParser st tok) where { pure = return ; (<*>) = ap; }
instance (Show tok, Eq tok, Enum tok) =>
  Alternative (SimParser st tok) where { empty = mzero; (<|>) = mplus; }
instance (Show tok, Eq tok, Enum tok) =>
  MonadState (GenParserState st tok) (SimParser st tok) where
    get = SimParser (PTrans (fmap OK get))
    put = SimParser . PTrans . fmap OK . put
instance (Show tok, Eq tok, Enum tok) =>
  MonadError (SimParseError st tok) (SimParser st tok) where
    throwError (SimParseError err)         = do
      st <- gets userState
      assumePValue (PFail (SimParseError $ err{parseStateAtErr=Just st}))
    catchError (SimParser ptrans) catcher = SimParser $ do
      pval <- catchPValue ptrans
      case pval of
        OK      a -> return a
        Backtrack -> mzero
        PFail err -> parserToPTrans (catcher err)
instance (Show tok, Eq tok, Enum tok) =>
  MonadPlusError (SimParseError st tok) (SimParser st tok) where
    catchPValue (SimParser ptrans) = SimParser (catchPValue ptrans)
    assumePValue                   = SimParser . assumePValue
instance (Show tok, Eq tok, Enum tok, Monoid a) =>
  Monoid (SimParser st tok a) where { mempty = return mempty; mappend a b = liftM2 mappend a b; }

-- | Only succeeds if all tokens have been consumed, otherwise backtracks.
parseEOF :: (Show tok, Eq tok, Enum tok) => GenParser st tok ()
parseEOF = GenParser $ mplus (simNextTokenPos False >> return False) (return True) >>= guard

-- | Return the next token in the state along with it's line and column position. If the boolean
-- parameter is true, the current token will also be removed from the state.
simNextTokenPos :: (Show tok, Eq tok, Enum tok) => Bool -> SimParser st tok (LineNum, ColumnNum, GenToken tok)
simNextTokenPos doRemove = do
  st <- get
  case recentTokens st of
    [] -> case getLines st of
      []         -> mzero
      line:lines -> case lineTokens line of
        []                 -> put (st{getLines=lines}) >> simNextTokenPos doRemove
        (colNum, tok):toks -> do
          let postok = (lineNumber line, colNum, tok)
              upd st = st{ getLines = line{ lineTokens = toks } : lines }
          if doRemove -- the 'recentTokens' buffer is cleared here regardless.
            then  put (upd st)
            else  put ((upd st){ recentTokens = [postok] })
          return postok
    tok:tokx | doRemove -> put (st{recentTokens=tokx}) >> return tok
    tok:tokx            -> return tok
      -- ^ if we remove a token, the 'recentTokens' cache must be cleared because we don't know what
      -- the next token will be. I use 'mzero' to clear the cache, it has nothing to do with the
      -- parser backtracking.

-- push an arbitrary token into the state. It is used to implement backtracking by the 'withToken'
-- function, so use 'withToken' instead.
pushToken :: (Show tok, Eq tok, Enum tok) => (LineNum, ColumnNum, GenToken tok) -> SimParser st tok ()
pushToken postok = modify (\st -> st{recentTokens = postok : recentTokens st})

-- | Like 'simNextTokenPos' but only returns the 'GenToken', not it's line and column position.
simNextToken :: (Show tok, Eq tok, Enum tok) => Bool -> SimParser st tok (GenToken tok)
simNextToken doRemove = simNextTokenPos doRemove >>= \ (_, _, tok) -> return tok

-- Return the current line and column of the current token without modifying the state in any way.
subGetCursor :: (Show tok, Eq tok, Enum tok) => SimParser st tok (LineNum, ColumnNum)
subGetCursor = simNextTokenPos False >>= \ (a,b, _) -> return (a,b)

----------------------------------------------------------------------------------------------------
-- $GenParser
-- GenParser is a data type (e.g. it is a 'Data.Monoid.Monoid') and also a control structure (e.g.
-- it is a 'Control.Monad.Monad' and a 'Control.Applicative.Alternative'). As a control structure,
-- it allows you to construct parser functions that generate objects from token streams. As a data
-- structure (internally) a sparse matrix parsing table is constructed to do this.
-- 
-- When you make use of 'Control.Monad.Monad', 'Control.Monad.MonadPlus',
-- 'Control.Applicative.Applicative', 'Control.Applicative.Alternative', and other classes to
-- construct your 'GenParser', behind the scenes the combinators are actually defining a sparse
-- matrix with a default parser action of 'Control.Monad.mzero' which are filled-in with values
-- supplied to the the 'token' function. If your 'GenParser' refers to an enumerated data type which
-- instantiates this class, you will also be able to fill-in the parser table with pointers to other
-- columns in the table.
--
-- You are presumably using GHC, so you can use the @{-#INLINE ... #-}@ pragma to improve efficency.
-- To create a row in the parser table, you would use the function 'token' or 'tokens' and combine
-- them with from 'Control.Monad.mplus', 'Control.Monad.msum', and ('Control.Applicative.<|>').
-- Behind the scenes, this module will construct an 'Data.Array.Array' so that it may very quickly
-- lookup the next parser. By making these functions top-level functions and using
-- @{-#INLINE ... #-}@ pragma, GHC will try harder to make sure these arrays are only allocated
-- once. Although inlining tends to occur without @{-#INLINE ... #-}@, it is not a guarantee.

data GenParser st tok a
  = GenParserArray { parserTableArray :: Array tok (GenParser st tok a) }
    -- ^ a parser table constructed from 'GenParserArrayItem's. This is the most efficient method to
    -- parse, so it is best to try and construct your parser from 'GenParserArrayItem's rather than
    -- simply using monadic notation to stick together a bunch of parsing functions.
  | GenParserMap { parserMap :: M.Map UStr (GenParser st tok a) }
  | GenParser { simParser :: SimParser st tok a }
    -- ^ a plain parser function, used for lifting 'SimParser' into the 'GenParser' monad,
    -- specificaly for the 'Control.Monad.return' function.
instance (Show tok, Ix tok, Enum tok) => Monad (GenParser st tok) where
  return a = GenParser { simParser = return a }
  fail     = GenParser . fail
  parser >>= bindTo =
    GenParser{
      simParser = evalGenToSimParser parser >>= \a -> evalGenToSimParser (bindTo a)
    }
instance (Show tok, Ix tok, Enum tok) => Functor (GenParser st tok) where
  fmap f parser = case parser of
    GenParserArray     arr        ->
      GenParserArray { parserTableArray = amap (\origFunc -> fmap f origFunc) arr }
    GenParser      parser ->
      GenParser{ simParser = fmap f parser}
instance (Show tok, Ix tok, Enum tok) =>
  MonadPlus (GenParser st tok) where
    mzero     = GenParser{ simParser = mzero }
    mplus a b = case a of
      GenParserArray     arrA    -> case b of
        GenParserArray     arrB    -> merge (assocs arrA ++ assocs arrB)
        GenParser               fb -> trace ("parser mplus after "++show (indices arrA)) $ GenParser{ simParser = mplus (evalParseArray arrA) fb }
      GenParser               fa -> GenParser $ mplus fa $ case b of
        GenParserArray     arrB    -> trace ("parser mplus before "++show (indices arrB)) $ evalParseArray arrB
        GenParser               fb -> trace ("mplus two simple parsers ") $ fb
      where
        minmax a = foldl (\ (n, x) a -> (min n a, max x a)) (a, a) . map fst
        merge ax = trace "merged two parser arrays" $ case ax of
          []                 -> mzero
          ax@((tok, func):_) -> trace ("created array for: "++show (map fst ax)) $ GenParserArray{
              parserTableArray = accumArray mplus mzero (minmax tok ax) ax
            }
instance (Show tok, Ix tok, Enum tok) =>
  Applicative (GenParser st tok) where { pure = return; (<*>) = ap; }
instance (Show tok, Ix tok, Enum tok) =>
  Alternative (GenParser st tok) where { empty = mzero; (<|>) = mplus; }
instance (Show tok, Ix tok, Enum tok, Monoid a) =>
  Monoid (GenParser st tok a) where { mempty = return mempty; mappend a b = liftM2 mappend a b; }
instance (Show tok, Ix tok, Enum tok) =>
  MonadState st (GenParser st tok) where
    get = GenParser (gets userState)
    put st = GenParser $ modify $ \parserState -> parserState{userState=st}
instance (Show tok, Ix tok, Enum tok) =>
  MonadError (GenParseError st tok) (GenParser st tok) where
    throwError = GenParser . throwError . SimParseError
    catchError trial catcher = GenParser $
      catchError (evalGenToSimParser trial) $ \ (SimParseError err) ->
        evalGenToSimParser (catcher err)
instance (Show tok, Ix tok, Enum tok) =>
  MonadPlusError (GenParseError st tok) (GenParser st tok) where
    catchPValue ptrans = GenParser $
      fmap (fmapFailed simGenParserErr) (catchPValue (evalGenToSimParser ptrans))
    assumePValue       = GenParser . assumePValue . fmapFailed SimParseError

liftParser :: (Show tok, Ix tok, Enum tok) => SimParser st tok a -> GenParser st tok a
liftParser = GenParser

-- | Evaluate a 'GenParser' to a 'SimParser'.
evalGenToSimParser :: (Show tok, Ix tok, Enum tok) => GenParser st tok a -> SimParser st tok a
evalGenToSimParser table = case table of
  GenParser              parser -> trace "ordinary parser" $ parser
  parserTable                   -> trace "parser array"    $ evalParseArray (parserTableArray parserTable)

-- | Run a single 'GenParserArrayItem' as a stand-alone parser.
evalParseTableElem :: (Show tok, Ix tok, Enum tok) => tok -> GenParser st tok a -> SimParser st tok a
evalParseTableElem tok parser =
  simNextTokenPos False >>= \ (line, col, tok) -> mplus (evalGenToSimParser parser) mzero

shift :: (Show tok, Ix tok, Enum tok) => GenParser st tok (GenToken tok)
shift = GenParser (simNextToken True >>= \a -> simNextToken False >>= \b -> trace ("shifted token: "++show a++"\n"++"next token: "++show b) (return a))

currentTokPos :: (Show tok, Ix tok, Enum tok) => GenParser st tok (LineNum, ColumnNum, GenToken tok)
currentTokPos = GenParser (simNextTokenPos False)

currentTok :: (Show tok, Ix tok, Enum tok) => GenParser st tok (GenToken tok)
currentTok = GenParser (simNextToken False)

-- Efficiently evaluates a array from a 'GenParserArray'. One token is shifted from the stream, and
-- the 'tokType' is used to select and evaluate the 'SimParser' in the 'GenParser'. The 'tokToStr'
-- value of the token is passed to the selected 'SimParser'. If the 'tokType' does not exist in the
-- table, or if the selected parser backtracks, this parser backtracks and the selecting token is
-- shifted back onto the stream.
evalParseArray :: (Show tok, Ix tok, Enum tok) => Array tok (GenParser st tok a) -> SimParser st tok a
evalParseArray arr = do
  tok <- simNextToken False
  if trace ("check array: "++show (indices arr)) $ inRange (bounds arr) (tokType tok)
    then  evalGenToSimParser (arr ! tokType tok)
    else  mzero

-- | Return the current line and column of the current token without modifying the state in any way.
getCursor :: (Show tok, Ix tok, Enum tok) => GenParser st tok (LineNum, ColumnNum)
getCursor = GenParser subGetCursor

-- | Evaluates to @()@ if we are at the end of the input text, otherwise backtracks.
getEOF :: (Show tok, Ix tok, Enum tok) => GenParser st tok ()
getEOF = GenParser $ get >>= \st -> case getLines st of
  []   -> return ()
  [st] -> if null (lineTokens st) then return () else mzero
  _    -> mzero

-- | Given two parameters: 1. an error message and 2. a 'Parser', will succeed normally if
-- evaluating the given 'Parser' succeeds. But if the given 'Parser' backtracks, this this function
-- will evaluate to a 'Parser' failure with the given error message. If the given 'Parser' fails,
-- it's error message is used instead of the error message given to this function. The string
-- "expecting " is automatically prepended to the given error message so it is a good idea for your
-- error message to simple state what you were expecting, like "a string" or "an integer". I
-- typically write 'expect' statements like so:
-- > fracWithExp = do
-- >     fractionalPart <- parseFractional
-- >     'tokenP' 'Alphabetic' (\tok -> tok=="E" || tok=="e")
-- >     'expect' "an integer expression after the 'e'" $ do
-- >         exponentPart <- parseSignedInteger
-- >         return (makeFracWithExp fractionalPart exponentPart :: 'Prelude.Double')
expect :: (Show tok, Ix tok, Enum tok) => String -> GenParser st tok a -> GenParser st tok a
expect errMsg parser = do
  (a, b) <- getCursor
  let expectMsg = "expecting "++errMsg
  mplus parser (throwError ((parserErr a b){parseErrMsg = Just (ustr expectMsg)}))

-- | If the given 'Parser' backtracks then evaluate to @return ()@, otherwise ignore the result of
-- the 'Parser' and evaluate to @return ()@.
ignore :: (Show tok, Ix tok, Enum tok) => GenParser st tok ig -> GenParser st tok ()
ignore = flip mplus (return ()) . void

-- | Return the default value provided in the case that the given 'SimParser' fails, otherwise
-- return the value returned by the 'SimParser'.
defaultTo :: (Show tok, Ix tok, Enum tok) => a -> GenParser st tok a -> GenParser st tok a
defaultTo defaultValue parser = mplus parser (return defaultValue)

-- | A 'marker' immediately stores the cursor onto the stack. It then evaluates the given 'Parser'.
-- If the given 'Parser' fails, the position of the failure (stored in a 'Dao.Token.Location') is
-- updated such that the starting point of the failure points to the cursor stored on the stack by
-- this 'marker'. When used correctly, this function makes error reporting a bit more helpful.
marker :: (Show tok, Ix tok, Enum tok) => GenParser st tok a -> GenParser st tok a
marker parser = do
  ab <- mplus (fmap Just getCursor) (return Nothing)
  flip mapPFail parser $ \parsErr ->
    parsErr
    { parseErrLoc =
        let p = parseErrLoc parsErr
        in  mplus (p >>= \loc -> ab >>= \ (a, b) -> return (mappend loc (atPoint a b))) p
    }

-- | The 'SimParser's analogue of 'Control.Monad.State.runState', runs the parser using an existing
-- 'GenParserState'.
runParserState
  :: (Show tok, Eq tok, Enum tok)
  => SimParser st tok a
  -> GenParserState st tok
  -> (PValue (SimParseError st tok) a, GenParserState st tok)
runParserState (SimParser parser) = runState (runPTrans parser)

-- | This is the second phase of parsing, takes a stream of tokens created by the 'lexicalAnalysis'
-- phase (the @['GenLine' tok]@ parameter) and constructs a syntax tree data structure using the
-- 'SimParser' monad provided.
syntacticAnalysis
  :: (Show tok, Eq tok, Enum tok)
  => SimParser st tok synTree
  -> st
  -> [GenLine tok]
  -> (PValue (SimParseError st tok) synTree, GenParserState st tok)
syntacticAnalysis parser st lines = runParserState parser $ newParserState st lines

----------------------------------------------------------------------------------------------------

-- | Generalized State Transformer Parser differs from 'GenParser' in that ever monadic bind
-- operation shifts a token from the stream. This makes it easier to write parsers with simple
-- 'Control.Monad.Monad'ic or 'Control.Applicative.Applicative' functions.
data GSTP st tok a
  = GSTPBacktrack
  | GSTPConst  { constValue  :: a }
  | GSTPFail   { failMessage :: String }
  | GSTPUpdate { updateInner :: GenParser st tok a }
  | GSTPTable
    { checkTokenAndString :: M.Map tok  (M.Map UStr (GSTP st tok a))
    , checkToken          :: M.Map tok  (GSTP st tok a)
    , checkString         :: M.Map UStr (GSTP st tok a)
    }
instance (Show tok, Ix tok, Enum tok) =>
  Monad (GSTP st tok) where
    return     = GSTPConst
    fail       = GSTPFail
    p >>= bind = case p of
      GSTPBacktrack            -> GSTPBacktrack
      GSTPConst a              -> bind a
      GSTPFail msg             -> GSTPFail msg
      GSTPUpdate p -> GSTPUpdate{
          updateInner = do
            a <- p >>= evalGSTPtoGenParser . bind
            shift >> return a
        }
      GSTPTable tokstr tok str ->
        GSTPTable
        { checkTokenAndString = fmap (fmap (>>=bind)) tokstr
        , checkToken          = fmap (>>=bind) tok
        , checkString         = fmap (>>=bind) str
        }
instance (Ix tok, Enum tok, Show tok) =>
  Functor (GSTP st tok) where
    fmap f p = case p of
      GSTPBacktrack -> GSTPBacktrack
      GSTPConst  a -> GSTPConst (f a)
      GSTPFail msg -> GSTPFail  msg
      GSTPUpdate p -> GSTPUpdate (fmap f p)
      GSTPTable tokstr tok str ->
        GSTPTable
        { checkTokenAndString = fmap (fmap (fmap f)) tokstr
        , checkToken          = fmap (fmap f) tok
        , checkString         = fmap (fmap f) str
        }
instance (Ix tok, Enum tok, Show tok) =>
  MonadPlus (GSTP st tok) where
    mzero     = GSTPBacktrack
    mplus a b = case a of
      GSTPBacktrack -> b
      GSTPConst   a -> GSTPConst a
      GSTPFail  msg -> GSTPFail msg
      GSTPUpdate  a -> case b of
        GSTPBacktrack -> GSTPUpdate a
        GSTPFail  msg -> GSTPUpdate a
        GSTPConst   b -> GSTPUpdate (mplus a (return b))
        GSTPUpdate  b -> GSTPUpdate (mplus a b)
        b             -> GSTPUpdate (mplus a (evalGSTPtoGenParser b))
      GSTPTable tokstrA tokA strA -> case b of
        GSTPBacktrack -> GSTPTable tokstrA tokA strA
        GSTPConst   b ->
          GSTPTable
          { checkTokenAndString = fmap (fmap (flip mplus (GSTPConst b))) tokstrA
          , checkToken          = fmap (flip mplus (GSTPConst b)) tokA
          , checkString         = fmap (flip mplus (GSTPConst b)) strA
          }
        GSTPFail  msg -> GSTPTable tokstrA tokA strA
        GSTPUpdate  b ->
          GSTPTable
          { checkTokenAndString = fmap (fmap (mplus (GSTPUpdate b))) tokstrA
          , checkToken          = fmap (mplus (GSTPUpdate b)) tokA
          , checkString         = fmap (mplus (GSTPUpdate b)) strA
          }
        GSTPTable tokstrB tokB strB ->
          GSTPTable
          { checkTokenAndString = M.unionWith (M.unionWith mplus) tokstrA tokstrB
          , checkToken          = M.unionWith              mplus  tokA    tokB
          , checkString         = M.unionWith              mplus strA    strB
          }
instance (Ix tok, Enum tok, Show tok) => Applicative (GSTP st tok) where { pure = return; (<*>) = ap; }
instance (Ix tok, Enum tok, Show tok) => Alternative (GSTP st tok) where { empty = mzero; (<|>) = mplus; }

evalGSTPtoGenParser :: (Ix tok, Enum tok, Show tok) => GSTP st tok a -> GenParser st tok a
evalGSTPtoGenParser p = case p of
  GSTPBacktrack -> mzero
  GSTPConst   a -> return a
  GSTPFail  msg -> fail msg
  GSTPUpdate fn -> fn
  GSTPTable tokstr tok str -> msum $ concat $
    [ mkMapArray tokstr
    , mkArray tok
    , mkmap str
    ]
  where
    findBounds tok = foldl (\ (min0, max0) (tok, _) -> (min min0 tok, max max0 tok)) (tok, tok)
    mkMapArray :: (Ix tok, Enum tok, Show tok) => M.Map tok (M.Map UStr (GSTP st tok a)) -> [GenParser st tok a]
    mkMapArray m = do
      let ax = M.assocs m
      case ax of
        []          -> mzero
        [(tok, m)]  -> return $ do
          t <- fmap tokType currentTok
          guard (t==tok)
          GenParserMap{parserMap = M.map evalGSTPtoGenParser m}
        (tok, _):ax' -> do
          let minmax = findBounds tok ax'
              bx     = concatMap (\ (tok, par) -> map ((,)tok) (mkmap par)) ax
          return (GenParserArray{parserTableArray = accumArray (\_ a -> a) mzero minmax bx})
    mkArray :: (Ix tok, Enum tok, Show tok) => M.Map tok (GSTP st tok a) -> [GenParser st tok a]
    mkArray m = do
      let ax = M.assocs m
      case ax of
        []            -> mzero
        [(tok, gstp)] -> return $ do
          t <- fmap tokType currentTok
          guard (t==tok)
          evalGSTPtoGenParser gstp
        (tok, _):ax'  -> do
          let minmax = findBounds tok ax'
              bx = map (\ (tok, par) -> (tok, evalGSTPtoGenParser par)) ax
          return (GenParserArray{parserTableArray = accumArray (\_ a -> a) mzero minmax bx})
    mkmap :: (Ix tok, Enum tok, Show tok) => M.Map UStr (GSTP st tok a) -> [GenParser st tok a]
    mkmap m = case M.assocs m of
      []            -> mzero
      [(str, gstp)] -> return $ do
        t <- fmap tokToUStr currentTok
        guard (t==str)
        evalGSTPtoGenParser gstp
      _             -> return (GenParserMap{parserMap = M.map evalGSTPtoGenParser m})

----------------------------------------------------------------------------------------------------

-- | A *General Context-Free Grammar* is a data structure that allows you to easily define a
-- two-phase parser (a parser with a 'lexicalAnalysis' phase, and a 'syntacticAnalysis' phase). The
-- fields supplied to this data type are define the grammar, and the 'parse' function can be used to
-- parse an input string using the context-free grammar defined in this data structure. *Note* that
-- the parser might have two phases, but because Haskell is a lazy language and 'parse' is a pure
-- function, both phases happen at the same time, so the resulting parser does not need to parse the
-- entire input in the first phase before beginning the second phase.
data GenCFGrammar st tok synTree
  = GenCFGrammar
    { columnWidthOfTab :: TabWidth
      -- ^ specify how many columns a @'\t'@ character takes up. This number is important to get
      -- accurate line:column information in error messages.
    , mainLexer        :: GenLexer tok ()
      -- ^ *the order of these tokenizers is important,* these are the tokenizers passed to the
      -- 'lexicalAnalysis' phase to generate the stream of tokens for the 'syntacticAnalysis' phase.
    , mainParser       :: SimParser st tok synTree
      -- ^ this is the parser entry-point which is used to evaluate the 'syntacticAnalysis' phase.
    }

-- | This is *the function that parses* an input string according to a given 'GenCFGrammar'.
parse
  :: (Show tok, Eq tok, Enum tok)
  => GenCFGrammar st tok synTree
  -> st -> String -> PValue (GenParseError st tok) synTree
parse cfg st input = case lexicalResult of
  OK      _ -> case parserResult of
    OK                   a    -> OK a
    Backtrack                 -> Backtrack
    PFail (SimParseError err) -> PFail $ err{parseStateAtErr=Just (userState parserState)}
  Backtrack -> Backtrack
  PFail err -> PFail $ (lexErrToParseErr err){parseStateAtErr = Nothing}
  where
    initState = (newLexerState input){lexTabWidth = columnWidthOfTab cfg}
    (lexicalResult, lexicalState) = lexicalAnalysis (mainLexer cfg) initState
    (parserResult , parserState ) =
      syntacticAnalysis (mainParser cfg) st (tokenStreamToLines (tokenStream lexicalState))

