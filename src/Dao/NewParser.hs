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
import           Data.Array

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
newLexerState :: (Eq tok, Enum tok) => String -> GenLexerState tok
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
newtype GenLexer tok a
  = GenLexer
    { runLexer :: PTrans (GenParserErr (GenLexerState tok) tok) (State (GenLexerState tok)) a
    }
instance (Eq tok, Enum tok) => Functor (GenLexer tok) where
  fmap fn (GenLexer lex) = GenLexer (fmap fn lex)
instance (Eq tok, Enum tok) => Monad (GenLexer tok) where
  (GenLexer fn) >>= mfn          = GenLexer (fn >>= runLexer . mfn)
  return                         = GenLexer . return
  fail msg                       = do
    st <- get
    throwError $
      (parserErr (lexCurrentLine st) (lexCurrentColumn st)){parserErrMsg = Just (ustr msg)}
instance (Eq tok, Enum tok) => MonadPlus (GenLexer tok) where
  mplus (GenLexer a) (GenLexer b) = GenLexer (mplus a b)
  mzero                           = GenLexer mzero
instance (Eq tok, Enum tok) => Applicative (GenLexer tok) where
  pure = return
  f <*> fa = f >>= \f -> fa >>= \a -> return (f a)
instance (Eq tok, Enum tok) => Alternative (GenLexer tok) where
  empty = mzero
  a <|> b = mplus a b
  many (GenLexer lex) = GenLexer (many lex)
  some (GenLexer lex) = GenLexer (some lex)
instance (Eq tok, Enum tok) => MonadState (GenLexerState tok) (GenLexer tok) where
  get = GenLexer (lift get)
  put = GenLexer . lift . put
instance (Eq tok, Enum tok) =>
  MonadError (GenParserErr (GenLexerState tok) tok) (GenLexer tok) where
    throwError                        = GenLexer . throwError
    catchError (GenLexer try) catcher = GenLexer (catchError try (runLexer . catcher))
instance (Eq tok, Enum tok) =>
  ErrorMonadPlus (GenParserErr (GenLexerState tok) tok) (GenLexer tok) where
    catchPValue (GenLexer try) = GenLexer (catchPValue try)
    assumePValue               = GenLexer . assumePValue

-- | Append the first string parameter to the 'lexBuffer', and set the 'lexInput' to the value of
-- the second string parameter. Most lexers simply takes the input, breaks it, then places the two
-- halves back into the 'LexerState', which is what this function does. *Be careful* you don't pass
-- the wrong string as the second parameter. Or better yet, don't use this function.
lexSetState :: (Eq tok, Enum tok) => String -> String -> GenLexer tok ()
lexSetState got remainder = modify $ \st ->
  st{lexBuffer = lexBuffer st ++ got, lexInput = remainder}

-- | Unlike simply evaluating 'Control.Monad.mzero', 'lexBacktrack' will push the contents of the
-- 'lexBuffer' back onto the 'lexInput'. This is inefficient, so if you rely on this too often you
-- should probably re-think the design of your lexer.
lexBacktrack :: (Eq tok, Enum tok) => GenLexer tok ig
lexBacktrack = modify (\st -> st{lexBuffer = "", lexInput = lexBuffer st ++ lexInput st}) >> mzero

-- | Single character look-ahead, never consumes any tokens, never backtracks unless we are at the
-- end of input.
lexLook1 :: (Eq tok, Enum tok) => GenLexer tok Char
lexLook1 = gets lexInput >>= \input -> case input of { "" -> mzero ; c:_ -> return c }

-- | Arbitrary look-ahead, creates a and returns copy of the portion of the input string that
-- matches the predicate. This function never backtracks, and it might be quite inefficient because
-- it must force strict evaluation of all characters that match the predicate.
lexCopyWhile :: (Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok String
lexCopyWhile predicate = fmap (takeWhile predicate) (gets lexInput)

-- | A fundamental 'Lexer', uses 'Data.List.break' to break-off characters from the input string
-- until the given predicate evaluates to 'Prelude.True'. Backtracks if no characters are lexed.
-- See also: 'charSet' and 'unionCharP'.
lexWhile :: (Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexWhile predicate = do
  (got, remainder) <- fmap (span predicate) (gets lexInput)
  if null got then mzero else lexSetState got remainder

-- | Like 'lexUnit' but inverts the predicate, lexing until the predicate does not match. This
-- function is defined as:
-- > \predicate -> 'lexUntil' ('Prelude.not' . predicate)
-- See also: 'charSet' and 'unionCharP'.
lexUntil :: (Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexUntil predicate = lexWhile (not . predicate)

-- lexer: update line/column with string
lexUpdLineColWithStr :: (Eq tok, Enum tok) => String -> GenLexer tok ()
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
makeGetToken  :: (Eq tok, Enum tok) => Bool -> tok -> GenLexer tok (GenToken tok)
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
makeToken :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
makeToken = void . makeGetToken True

-- | Create a token in the stream without returning it (you usually don't need the token anyway). If
-- you do need the token, use 'makeGetToken'. The token created will not store any characters, only
-- the type of the token. This can save a lot of memory, but it requires you have very descriptive
-- token types.
makeEmptyToken :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
makeEmptyToken = void . makeGetToken False

-- | Clear the 'lexBuffer' without creating a token.
clearBuffer :: (Eq tok, Enum tok) => GenLexer tok ()
clearBuffer = get >>= \st -> lexUpdLineColWithStr (lexBuffer st) >> put (st{lexBuffer=""})

-- | A fundamental lexer using 'Data.List.stripPrefix' to check whether the given string is at the
-- very beginning of the input.
lexString :: (Eq tok, Enum tok) => String -> GenLexer tok ()
lexString str =
  gets lexInput >>= assumePValue . maybeToBacktrack . stripPrefix str >>= lexSetState str

-- | A fundamental lexer succeeding if the next 'Prelude.Char' in the 'lexInput' matches the
-- given predicate. See also: 'charSet' and 'unionCharP'.
lexCharP ::  (Eq tok, Enum tok) => (Char -> Bool) -> GenLexer tok ()
lexCharP predicate = gets lexInput >>= \input -> case input of
  c:input | predicate c -> lexSetState [c] input
  _                     -> mzero

-- | Succeeds if the next 'Prelude.Char' on the 'lexInput' matches the given 'Prelude.Char'
lexChar :: (Eq tok, Enum tok) => Char -> GenLexer tok ()
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

lexOptional :: (Eq tok, Enum tok) => GenLexer tok () -> GenLexer tok ()
lexOptional lexer = mplus lexer (return ())

-- | Backtracks if there are still characters in the input.
lexEOF :: (Eq tok, Enum tok) => GenLexer tok ()
lexEOF = fmap (=="") (gets lexInput) >>= guard

-- | Create a 'GenLexer' that will continue scanning until it sees an unescaped terminating
-- sequence. You must provide three lexers: the scanning lexer, the escape sequence 'GenLexer' and
-- the terminating sequence 'GenLexer'. Evaluates to 'Prelude.True' if the termChar was found,
-- returns 'Prelude.False' if this tokenizer went to the end of the input without seenig an
-- un-escaped terminating character.
lexUntilTerm
  :: (Eq tok, Enum tok)
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
lexUntilTermChar :: (Eq tok, Enum tok) => Char -> Char -> GenLexer tok Bool
lexUntilTermChar escChar termChar =
  lexUntilTerm (lexUntil (\c -> c==escChar || c==termChar)) (lexChar escChar) (lexChar termChar)

-- | A special case of 'lexUntilTerm', lexes until finds an un-escaped terminating 'Prelude.String'.
-- You must provide only the escpae 'Prelude.String' and the terminating 'Prelude.String'. You can
-- pass a null string for either escape or terminating strings (passing null for both evaluates to
-- an always-backtracking lexer). The most escape and terminating strings are analyzed and the most
-- efficient method of lexing is decided, so this lexer is guaranteed to be as efficient as
-- possible.
lexUntilTermStr :: (Eq tok, Enum tok) => String -> String -> GenLexer tok Bool
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
  :: (Eq tok, Enum tok)
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
lexSimple :: (Eq tok, Enum tok) => tok -> (Char -> Bool) -> GenLexer tok ()
lexSimple tok predicate = lexWhile predicate >> makeToken tok

-- | A fundamental lexer using 'Data.Char.isSpace' and evaluating to a 'Space' token.
lexSpace :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexSpace tok = lexSimple tok isSpace

-- | A fundamental lexer using 'Data.Char.isAlpha' and evaluating to a 'Alphabetic' token.
lexAlpha :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexAlpha tok = lexSimple tok isAlpha

-- | A fundamental lexer using 'Data.Char.isDigit' and evaluating to a 'Digits' token.
lexDigits :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexDigits tok = lexSimple tok isDigit

-- | A fundamental lexer using 'Data.Char.isHexDigit' and evaluating to a 'HexDigit' token.
lexHexDigits :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexHexDigits tok = lexSimple tok isHexDigit

-- | Constructs an operator 'GenLexer' from a string of operators separated by spaces. For example,
-- pass @"+ += - -= * *= ** / /= % %= = == ! !="@ to create 'Lexer' that will properly parse all of
-- those operators. The order of the operators is *NOT* important, repeat symbols are tried only
-- once, the characters @+=@ are guaranteed to be parsed as a single operator @["+="]@ and not as
-- @["+", "="]@. *No token is created,* you must create your token using 'makeToken' or
-- 'makeEmptyToken' immediately after evaluating this tokenizer.
lexOperator :: (Eq tok, Enum tok) => String -> GenLexer tok ()
lexOperator ops =
  msum (map (\op -> lexString op) $ reverse $ nub $ sortBy len $ words ops)
  where
    len a b = case compare (length a) (length b) of
      EQ -> compare a b
      GT -> GT
      LT -> LT

lexToEndline :: (Eq tok, Enum tok) => GenLexer tok ()
lexToEndline = lexUntil (=='\n')

lexInlineComment :: (Eq tok, Enum tok) => tok -> String -> String -> GenLexer tok ()
lexInlineComment tok startStr endStr = do
  lexString startStr
  completed <- lexUntilTermStr "" endStr
  if completed
    then  makeToken tok
    else  fail "comment runs past end of input"

lexInlineC_Comment :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexInlineC_Comment tok = lexInlineComment tok "/*" "*/"

lexEndlineC_Comment :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineC_Comment tok = lexString "//" >> lexUntil (=='\n') >> makeToken tok

lexInlineHaskellComment :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexInlineHaskellComment tok = lexInlineComment tok "{-" "-}"

lexEndlineHaskellComment :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineHaskellComment tok = lexString "--" >> lexToEndline >> makeToken tok

-- | A lot of programming languages provide only end-line comments beginning with a (@#@) character.
lexEndlineCommentHash :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexEndlineCommentHash tok = lexChar '#' >> lexToEndline >> makeToken tok

lexStringLiteral :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexStringLiteral tok = do
  lexChar '"'
  completed <- lexUntilTermChar '\\' '"'
  if completed
    then  makeToken tok
    else  fail "string literal expression runs past end of input"

lexCharLiteral :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
lexCharLiteral tok = lexChar '\'' >> lexUntilTermChar '\\' '\'' >> makeToken tok

-- | This actually tokenizes a general label: alpha-numeric and underscore characters starting with
-- an alphabetic or underscore character. This is useful for several programming languages.
-- Evaluates to a 'Keyword' token type, it is up to the 'GenParser's in the syntacticAnalysis phase
-- to sort out which 'Keyword's are actually keywords and which are labels for things like variable
-- names.
lexKeyword :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
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
-- that the 'GenParser' report it as an error during the 'syntacticAnalysis' phase. Floating-point
-- decimal numbers are also lexed appropriately, and this includes floating-point numbers expressed
-- in hexadecimal. Again, if your language must disallow hexadecimal floating-point numbers, throw
-- an error in the 'syntacticAnalysis' phase.
lexNumber :: (Eq tok, Enum tok) => tok -> tok -> tok -> tok -> GenLexer tok ()
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
lexHaskellLabel :: (Eq tok, Enum tok) => tok -> GenLexer tok ()
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
-- number with every single token. It is necessary for initializing a 'GenParser'.
tokenStreamToLines :: (Eq tok, Enum tok) => [GenTokenAt tok] -> [GenLine tok]
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
  :: (Eq tok, Enum tok)
  => GenLexer tok a
  -> GenLexerState tok
  -> (PValue (GenParserErr (GenLexerState tok) tok) a, GenLexerState tok)
lexicalAnalysis lexer st = runState (runPTrans (runLexer lexer)) st

testLexicalAnalysis_withFilePath
  :: (Eq tok, Enum tok, Show tok)
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
  :: (Eq tok, Enum tok, Show tok)
  => GenLexer tok () -> TabWidth -> String -> IO ()
testLexicalAnalysis a b c = testLexicalAnalysis_withFilePath a "" b c

-- | Run the 'lexicalAnalysis' with the 'GenLexer' on the contents of the file at the the given
-- 'System.IO.FilePath' 'Prelude.String' and print out every token created.
testLexicalAnalysisOnFile
  :: (Eq tok, Enum tok, Show tok)
  => GenLexer tok () -> TabWidth -> FilePath -> IO ()
testLexicalAnalysisOnFile a b c = readFile c >>= testLexicalAnalysis_withFilePath a c b

----------------------------------------------------------------------------------------------------
-- The parser data type

-- | This data structure is used by both the 'GenLexer' and 'GenParser' monads.
data GenParserErr st tok
  = GenParserErr
    { parserErrLoc     :: Maybe Location
    , parserErrMsg     :: Maybe UStr
    , parserErrTok     :: Maybe (GenToken tok)
    , parserStateAtErr :: Maybe st
    }

instance Show tok => Show (GenParserErr st tok) where
  show err =
    let msg = concat $ map (fromMaybe "") $
          [ fmap (("(on token "++) . (++")") . show) (parserErrTok err)
          , fmap ((": "++) . uchars) (parserErrMsg err)
          ]
    in  if null msg then "Unknown parser error" else msg

-- | An initial blank parser error.
parserErr :: (Eq tok, Enum tok) => LineNum -> ColumnNum -> GenParserErr st tok
parserErr lineNum colNum =
  GenParserErr
  { parserErrLoc = Just $
      Location
      { startingLine   = lineNum
      , startingColumn = colNum
      , endingLine     = lineNum
      , endingColumn   = colNum
      }
  , parserErrMsg = Nothing
  , parserErrTok = Nothing
  , parserStateAtErr = Nothing
  }

-- | 'parse' will evaluate the 'GenLexer' over the input string first. If the 'GenLexer' fails, it
-- will evaluate to a 'Dao.Prelude.PFail' value containing a 'GenParserErr' value of type:
-- > ('Prelude.Eq' tok, 'Prelude.Enum' tok) => 'GenParserErr' ('GenLexerState' tok)
-- However the 'GenParser's evaluate to 'GenParserErr's containing type:
-- > ('Prelude.Eq' tok, 'Prelude.Enum' tok) => 'GenParserErr' ('GenParserState' st tok)
-- This function provides an easy way to convert between the two 'GenParserErr' types, however since
-- the state value @st@ is polymorphic, you will need to insert your parser state into the error
-- value after evaluating this function. For example:
-- > case tokenizerResult of
-- >    'Dao.Predicate.PFail' lexErr -> 'Dao.Predicate.PFail' (('lexErrToParseErr' lexErr){'parserStateAtErr' = Nothing})
-- >    ....
lexErrToParseErr
  :: (Eq tok, Enum tok)
  => GenParserErr (GenLexerState tok) tok
  -> GenParserErr (GenParserState st tok) tok
lexErrToParseErr lexErr =
  lexErr
  { parserStateAtErr = Nothing
  , parserErrLoc = st >>= \st -> return (atPoint (lexCurrentLine st) (lexCurrentColumn st))
  }
  where { st = parserStateAtErr lexErr }

-- | The 'GenParserState' contains a stream of all tokens created by the 'lexicalAnalysis' phase.
-- This is the state associated with a 'GenParser' in the instantiation of 'Control.Mimport
-- Debug.Traceonad.State.MonadState', so 'Control.Monad.State.get' returns a value of this data
-- type.
data GenParserState st tok
  = GenParserState
    { userState   :: st
    , getLines    :: [GenLine tok]
    , recentTokens :: [(LineNum, ColumnNum, GenToken tok)]
      -- ^ single look-ahead is common, but the next token exists within the 'Prelude.snd' value
      -- within a pair within a list within the 'lineTokens' field of a 'GenLine' data structure.
      -- Rather than traverse that same path every time 'nextToken' or 'withToken' is called, the
      -- next token is cached here.
    }

newParserState :: (Eq tok, Enum tok) => st -> [GenLine tok] -> GenParserState st tok
newParserState st lines = GenParserState{userState = st, getLines = lines, recentTokens = []}

modifyUserState :: (Eq tok, Enum tok) => (st -> st) -> GenParser st tok ()
modifyUserState fn = modify (\st -> st{userState = fn (userState st)})

-- | The task of the 'GenParser' monad is to look at every token in order and construct syntax trees
-- in the 'syntacticAnalysis' phase.
--
-- This function instantiates all the useful monad transformers, including 'Data.Functor.Functor',
-- 'Control.Monad.Monad', 'Control.MonadPlus', 'Control.Monad.State.MonadState',
-- 'Control.Monad.Error.MonadError' and 'Dao.Predicate.ErrorMonadPlus'. Backtracking can be done
-- with 'Control.Monad.mzero' and "caught" with 'Control.Monad.mplus'. 'Control.Monad.fail' and
-- 'Control.Monad.Error.throwError' evaluate to a control value containing a 'GenParserErr' value
-- which can be caught by 'Control.Monad.Error.catchError', and which automatically contain
-- information about the location of the failure and the current token in the stream that caused the
-- failure.
newtype GenParser st tok a
  = GenParser { parserToPTrans :: PTrans (GenParserErr st tok) (State (GenParserState st tok)) a}
instance (Eq tok, Enum tok) => Functor   (GenParser st tok) where
  fmap f (GenParser a) = GenParser (fmap f a)
instance (Eq tok, Enum tok) => Monad     (GenParser st tok) where
  (GenParser ma) >>= mfa = GenParser (ma >>= parserToPTrans . mfa)
  return a               = GenParser (return a)
  fail msg = do
    ab  <- optional getCursor
    tok <- optional (nextToken False)
    st  <- gets userState
    throwError $
      GenParserErr
      { parserErrLoc = fmap (uncurry atPoint) ab
      , parserErrMsg = Just (ustr msg)
      , parserErrTok = tok
      , parserStateAtErr = Just st
      }
instance (Eq tok, Enum tok) => MonadPlus (GenParser st tok) where
  mzero                             = GenParser mzero
  mplus (GenParser a) (GenParser b) = GenParser (mplus a b)
instance (Eq tok, Enum tok) => Applicative (GenParser st tok) where
  pure = return
  f <*> fa = f >>= \f -> fa >>= \a -> return (f a)
instance (Eq tok, Enum tok) => Alternative (GenParser st tok) where
  empty = mzero
  a <|> b = mplus a b
  many (GenParser par) = GenParser (many par)
  some (GenParser par) = GenParser (some par)
instance (Eq tok, Enum tok) => MonadState (GenParserState st tok) (GenParser st tok) where
  get = GenParser (PTrans (fmap OK get))
  put = GenParser . PTrans . fmap OK . put
instance (Eq tok, Enum tok) => MonadError (GenParserErr st tok) (GenParser st tok) where
  throwError err                        = do
    st <- gets userState
    assumePValue (PFail (err{parserStateAtErr=Just st}))
  catchError (GenParser ptrans) catcher = GenParser $ do
    pval <- catchPValue ptrans
    case pval of
      OK      a -> return a
      Backtrack -> mzero
      PFail err -> parserToPTrans (catcher err)
instance (Eq tok, Enum tok) => ErrorMonadPlus (GenParserErr st tok) (GenParser st tok) where
  catchPValue (GenParser ptrans) = GenParser (catchPValue ptrans)
  assumePValue                   = GenParser . assumePValue

-- | Only succeeds if all tokens have been consumed, otherwise backtracks.
parseEOF :: (Eq tok, Show tok, Enum tok) => GenParser st tok ()
parseEOF = mplus (nextTokenPos False >> return False) (return True) >>= guard

-- | Return the next token in the state along with it's line and column position. If the boolean
-- parameter is true, the current token will also be removed from the state.
nextTokenPos :: (Eq tok, Enum tok) => Bool -> GenParser st tok (LineNum, ColumnNum, GenToken tok)
nextTokenPos doRemove = do
  st <- get
  case recentTokens st of
    [] -> case getLines st of
      []         -> mzero
      line:lines -> case lineTokens line of
        []                 -> put (st{getLines=lines}) >> nextTokenPos doRemove
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
pushToken :: (Eq tok, Enum tok) => (LineNum, ColumnNum, GenToken tok) -> GenParser st tok ()
pushToken postok = modify (\st -> st{recentTokens = postok : recentTokens st})

-- | Like 'nextTokenPos' but only returns the 'GenToken', not it's line and column position.
nextToken :: (Eq tok, Enum tok) => Bool -> GenParser st tok (GenToken tok)
nextToken doRemove = nextTokenPos doRemove >>= \ (_, _, tok) -> return tok

-- | Return the next token in the state if it is of the type specified, removing it from the state.
tokenP :: (Eq tok, Enum tok) => (tok -> UStr -> Bool) -> GenParser st tok UStr
tokenP predicate = do
  tok <- nextToken False
  let tokUStr = tokToUStr tok
  if predicate (tokType tok) tokUStr then nextToken True >> return tokUStr else mzero

-- | Return the next token in the state if it is of the type specified and also if the string value
-- evaluated by the given predicate returns true, otherwise backtrack.
token :: (Eq tok, Enum tok) => (tok -> Bool) -> (String -> Bool) -> GenParser st tok UStr
token requestedType stringPredicate =
  tokenP (\typ str -> requestedType typ && stringPredicate (uchars str))

tokenType :: (Eq tok, Enum tok) => tok -> GenParser st tok UStr
tokenType requestedType = token (==requestedType) (const True)

-- | Return the next token in the state if the string value of the token is exactly equal to the
-- given string, and if the token type is any one of the given token types.
tokenTypes :: (Eq tok, Enum tok) => [tok] -> GenParser st tok UStr
tokenTypes requestedTypes = token (\b -> or (map (==b) requestedTypes)) (const True)

-- | Single token look-ahead: takes the next token, removing it from the state, and uses it to
-- evaluate the given 'Parser'. If the backtracks, the token is replaced into the state. Failures
-- are not caught, make sure the 'Parser' you pass to this function makes use of
-- 'Control.Monad.Error.catchError' to catch failures if that is what you need it to do. This
-- function does not keep a copy of the state, it removes a token from the stream, then places it
-- back if backtracking occurs. This is supposed to be more efficient.
withTokenP :: (Eq tok, Enum tok) => (tok -> UStr -> GenParser st tok a) -> GenParser st tok a
withTokenP parser = do
  (line, col, tok) <- nextTokenPos True
  mplus (parser (tokType tok) (tokToUStr tok)) (pushToken (line, col, tok) >> mzero)

withToken
  :: (Eq tok, Enum tok)
  => (tok -> Bool) -> (UStr -> GenParser st tok a) -> GenParser st tok a
withToken tokenPredicate parser =
  withTokenP $ \tok u -> if tokenPredicate tok then parser u else mzero

-- | Created with 'ptab', this type is used to initalize a parser table.
newtype GenParseTableElem st tok a
  = GenParseTableElem { parseTableElemToPair :: (tok, UStr -> GenParser st tok a) }

instance (Ix tok, Enum tok) => Functor (GenParseTableElem st tok) where
  fmap fn (GenParseTableElem (a, b)) =
    GenParseTableElem{ parseTableElemToPair = (a, \u -> fmap fn (b u)) }

newtype GenParseTable st tok a
  = GenParseTable { parserTableArray :: Array tok (UStr -> GenParser st tok a) }

-- | Modify the return type of the 'GenParser' within a 'GenParseTableElem'. This is handy for
-- re-using lists of 'GenParseTableElem's in 'GenParseTable's that should parse the same tokens but
-- evaluate a different type of object. For example, if you have a list of 'GenParseTableElem's that
-- evaluate a type 'Prelude.Int':
-- > myIntParseTabElems :: ['GenParseTableElem' st tok 'Prelude.Int']
-- and you would like to use these exact same parsers but in a table that returns 'Prelude.Float'.
-- types, then you would use this function like so:
-- > myFloatParseTabElems :: ['GenParseTableElem' st tok 'Prelude.Float']
-- > myFloatParseTabElems =
-- >     map ('bindPTabElem' ('Prelude.return' 'Prelude.(.)' 'Prelude.fromIntegral')) myIntParseTabElems
-- The name "bind" is used because it is similar to the monadic "bind" operator
-- 'Control.Monad.(>>=)', however this function is not an infix operator so it is more convenient to
-- have the parameters are flipped from the order of the parameters used in monadic bind.
bindPTabElem
  :: (Ix tok, Enum tok)
  => (a -> GenParser st tok b)
  -> GenParseTableElem st tok a
  -> GenParseTableElem st tok b
bindPTabElem bindFunc tabElem =
  GenParseTableElem
  { parseTableElemToPair =
      let (tok, func) = parseTableElemToPair tabElem
      in  (tok, (\str -> func str >>= bindFunc))
  }

-- | Run a single 'GenParseTableElem' as a stand-alone parser.
runParseTableElem :: (Ix tok, Enum tok) => GenParseTableElem st tok a -> GenParser st tok a
runParseTableElem elem = let (tok, parser) = parseTableElemToPair elem in withToken (==tok) parser

-- | Since 'GenToken's all have a type value that instantiates 'Prelude.Enum', it can be efficient
-- to create an array with each parser stored at an index related to the token type. To create such
-- an array, use this function and 'ptab', then evaluate the parser with
-- 'evalParseTable'. Specify the range of tokens to use (it is most efficient if the range consists
-- of consecutive 'Prelude.Enum' elements), and then the list of parsers, where each parser is
-- constructed with 'ptab'.
newParseTable
  :: (Ix tok, Enum tok)
  => [GenParseTableElem st tok a]
  -> GenParseTable st tok a
newParseTable elems =
  let minmax (mintok, maxtok) tok = (min tok mintok, max tok maxtok)
      (mintok, maxtok) = foldl minmax (toEnum 0, toEnum 0) $ map (fst . parseTableElemToPair) elems
  in  GenParseTable $ array (mintok, maxtok) $ concat
        [ zip [mintok..maxtok] (repeat (\_ -> mzero))
        , reverse $ map parseTableElemToPair elems
        ]

-- | Use this function to construct 'ParseTableElem's used to initialize a parser array constructed
-- with the 'newParseTable' function. An example function could be a parser that creates
-- identifiers:
-- > data IDEN | NUM deriving ('Prelude.Eq', 'Prelude.Ord', 'Prelude.Enum', 'Data.Ix.Ix, 'Prelude.Show')
-- > data Identifier String | Number Int
-- > 'newParserArray' IDEN NUM $
-- >     [ 'ptab' IDEN $ \str -> return (Identifier str)
-- >     , 'ptab' NUM  $ \str -> return (Number ('Prelude.read' str))
-- >     ]
ptab :: (Ix tok, Enum tok) => tok -> (UStr -> GenParser st tok a) -> GenParseTableElem st tok a
ptab tok parser = GenParseTableElem (tok, parser)

-- | Efficiently evaluates a 'GenParseTable'. One token is shifted from the stream, and the
-- 'tokType' is used to select and evaluate the 'GenParser' in the 'GenParseTable'. The 'tokToStr'
-- value of the token is passed to the selected 'GenParser'. If the 'tokType' does not exist in the
-- table, or if the selected parser backtracks, this parser backtracks and the selecting token is
-- shifted back onto the stream.
evalParseTable :: (Ix tok, Enum tok) => GenParseTable st tok a -> GenParser st tok a
evalParseTable table = do
  let arr = parserTableArray table
  tokPos@(_, _, tok) <- nextTokenPos True
  if inRange (bounds arr) (tokType tok) then (arr ! tokType tok) (tokToUStr tok) else mzero

-- | Return the current line and column of the current token without modifying the state in any way.
getCursor :: (Eq tok, Enum tok) => GenParser st tok (LineNum, ColumnNum)
getCursor = nextTokenPos False >>= \ (a,b, _) -> return (a,b)

-- | Evaluates to @()@ if we are at the end of the input text, otherwise backtracks.
getEOF :: (Eq tok, Enum tok) => GenParser st tok ()
getEOF = get >>= \st -> case getLines st of
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
expect :: (Eq tok, Enum tok) => String -> GenParser st tok a -> GenParser st tok a
expect errMsg parser = do
  (a, b) <- getCursor
  let expectMsg = "expecting "++errMsg
  mplus parser (throwError ((parserErr a b){parserErrMsg = Just (ustr expectMsg)}))

-- | If the given 'Parser' backtracks then evaluate to @return ()@, otherwise ignore the result of
-- the 'Parser' and evaluate to @return ()@.
ignore :: (Eq tok, Enum tok) => GenParser st tok ig -> GenParser st tok ()
ignore = flip mplus (return ()) . void

-- | Return the default value provided in the case that the given 'GenParser' fails, otherwise
-- return the value returned by the 'GenParser'.
defaultTo :: (Eq tok, Enum tok) => a -> GenParser st tok a -> GenParser st tok a
defaultTo defaultValue parser = mplus parser (return defaultValue)

-- | A 'marker' immediately stores the cursor onto the stack. It then evaluates the given 'Parser'.
-- If the given 'Parser' fails, the position of the failure (stored in a 'Dao.Token.Location') is
-- updated such that the starting point of the failure points to the cursor stored on the stack by
-- this 'marker'. When used correctly, this function makes error reporting a bit more helpful.
marker :: (Eq tok, Enum tok) => GenParser st tok a -> GenParser st tok a
marker parser = do
  ab <- mplus (fmap Just getCursor) (return Nothing)
  flip mapPFail parser $ \parsErr ->
    parsErr
    { parserErrLoc =
        let p = parserErrLoc parsErr
        in  mplus (p >>= \loc -> ab >>= \ (a, b) -> return (mappend loc (atPoint a b))) p
    }

-- | The 'GenParser's analogue of 'Control.Monad.State.runState', runs the parser using an existing
-- 'GenParserState'.
runParserState
  :: (Eq tok, Enum tok)
  => GenParser st tok a
  -> GenParserState st tok
  -> (PValue (GenParserErr st tok) a, GenParserState st tok)
runParserState (GenParser parser) = runState (runPTrans parser)

-- | This is the second phase of parsing, takes a stream of tokens created by the 'lexicalAnalysis'
-- phase (the @['GenLine' tok]@ parameter) and constructs a syntax tree data structure using the
-- 'GenParser' monad provided.
syntacticAnalysis
  :: (Eq tok, Enum tok)
  => GenParser st tok synTree
  -> st
  -> [GenLine tok]
  -> (PValue (GenParserErr st tok) synTree, GenParserState st tok)
syntacticAnalysis parser st lines = runParserState parser $ newParserState st lines

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
    , mainParser       :: GenParser st tok synTree
      -- ^ this is the parser entry-point which is used to evaluate the 'syntacticAnalysis' phase.
    }

-- | This is *the function that parses* an input string according to a given 'GenCFGrammar'.
parse
  :: (Eq tok, Enum tok)
  => GenCFGrammar st tok synTree
  -> st -> String -> PValue (GenParserErr st tok) synTree
parse cfg st input = case lexicalResult of
  OK      _ -> case parserResult of
    OK      a -> OK a
    Backtrack -> Backtrack
    PFail err -> PFail $ err{parserStateAtErr=Just (userState parserState)}
  Backtrack -> Backtrack
  PFail err -> PFail ((lexErrToParseErr err){parserStateAtErr = Nothing})
  where
    initState = (newLexerState input){lexTabWidth = columnWidthOfTab cfg}
    (lexicalResult, lexicalState) = lexicalAnalysis (mainLexer cfg) initState
    (parserResult , parserState ) =
      syntacticAnalysis (mainParser cfg) st (tokenStreamToLines (tokenStream lexicalState))

