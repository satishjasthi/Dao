-- "src/Dao/Predicate.hs"  provides 'PredicateIO', a monad for easily
-- overloading functions built-in to the Dao scripting language.
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
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}

-- | Provides a special monad for building complex predicates that can check the structure of
-- complex data types, but in a way that I find to be much simpler than "Data.Data". The 'Predicate'
-- monad lifts the IO monad into the 'Dao.Combination.Combiation' monad, and catches all pattern
-- matching exceptions, so predicates can be written in plain-old Haskell. Non-exhaustive case
-- statements and lambda expressions that only match on a narow range of types will not evaluate to
-- bottom, they will simply evaluate to @Control.Monad.mzero@. Like the
-- 'Dao.Combination.Combination' monad, the @>>=@ and @>>@ operators compute conjunctive conditions
-- (all must be true to succeede) and 'Control.Monad.msum' and 'Control.Monad.mplus' compute
-- disjunctive conditions (any condition will succeede).

module Dao.Predicate where

import           Dao.String

import           Control.Exception
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Error
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.State

import           Data.Monoid

-- | 'PValue' is a "predicate value" data type allows a monadic computation to backtrack and try
-- another branch of computation, or to fail without causing backtracking. These values are used
-- internally by 'Dao.Parser.Parser's.
data PValue err ok
  = Backtrack
    -- ^ 'Backtrack' is a value used internally to the 'Parser's 'Control.Monad.State.State' monad
    -- to signal a temporary parse failure, which indicates to the 'Parser' monad to stop parsing
    -- and try another choice. Choices are specified by 'Control.Monad.mplus', for example
    -- @'Control.Monad.mplus' a b@, where @a@ and @b@ are 'Parser's, will first try to evaluate @a@,
    -- but if @b@ evaluates to 'mzero', this will internally return the 'Backtrack' value to the
    -- 'Parser's 'Control.Monad.State.State' monad, which will cause @b@ to be evaluated. If the
    -- entire parser evaluates to a 'Backtrack' this means the 'Parser' did not fail, but it did not
    -- match the input string either, at which point you can have your 'Parser' evaluate 'PFail'
    -- using the 'PFail' or 'Control.Monad.fail' functions.
    --
    -- Note that when lifting 'PValue' into a stateful monad, 'Backtrack'ing does not return the
    -- state to it's original value before the backtrack. Any updates to the state remain after the
    -- backtracking.
  | PFail { failedItem :: err }
    -- ^ If any 'Parser' function in your 'Parser' computation evaluates 'PFail', the whole parser
    -- evaluates to 'PFail' so no characters will be parsed after that, unless the failure is caught
    -- by 'Control.Monad.Error.catchError' or 'pcatch'.
  | OK ok -- ^ A parser evaluates to 'OK' when it evaluates 'Control.Monad.return'.
  deriving (Eq, Ord, Show)
instance Functor (PValue err) where
  fmap fn (OK    a) = OK (fn a)
  fmap _  (PFail u) = PFail u
  fmap _  Backtrack = Backtrack
instance Monad (PValue err) where
  return = OK
  ma >>= mfn = case ma of
    OK     ok -> mfn    ok
    PFail err -> PFail err
    Backtrack -> Backtrack
instance MonadPlus (PValue err) where
  mzero = Backtrack
  mplus Backtrack b = b
  mplus a         _ = a
instance MonadError err (PValue err) where
  throwError           = PFail
  catchError try catch = case try of
    PFail err -> catch err
    try       -> try
instance Applicative (PValue err) where { pure  = return; (<*>) = ap;    }
instance Alternative (PValue err) where { empty = mzero;  (<|>) = mplus; }
instance Monoid ok => Monoid (PValue err ok) where
  mempty                = Backtrack
  mappend (OK a) (OK b) = OK(a<>b)
  mappend     a      _  = a

-- | If a 'PValue' is 'PFail', you can alter the polymorphic parameter with this function in the
-- manner of 'Control.Monad.fmap'.
fmapFailed :: (errBefore -> errAfter) -> PValue errBefore ok -> PValue errAfter ok
fmapFailed fn pval = case pval of
  Backtrack -> Backtrack
  OK     ok -> OK ok
  PFail err -> PFail (fn err)

fromPValue :: ok -> PValue err ok -> ok
fromPValue ok pval = case pval of { OK ok -> ok; _ -> ok; }

----------------------------------------------------------------------------------------------------

-- | A monad transformer for 'PValue', this is especially handy with a 'Control.Monad.State.State'
-- monad. For example 'Dao.Parser.Parser' is a 'Control.Monad.State.State' monad lifted into the
-- 'PTrans' monad.
newtype PTrans err m ok = PTrans { runPTrans :: m (PValue err ok) }
instance Monad m => Monad (PTrans err m) where
  return a = PTrans (return (OK a))
  PTrans ma >>= fma = PTrans $ do
    a <- ma
    case a of
      Backtrack -> return Backtrack
      PFail   u -> return (PFail u)
      OK      o -> runPTrans (fma o)
  PTrans ma >> PTrans mb = PTrans $ do
    a <- ma
    case a of
      Backtrack -> return Backtrack
      PFail   u -> return (PFail u)
      OK      _ -> mb
  fail msg = PTrans{ runPTrans = return (PFail (error msg)) }
instance Functor m => Functor (PTrans err m) where
  fmap f (PTrans ma) = PTrans (fmap (fmap f) ma)
-- | 'mzero' introduces backtracking, 'mplus' introduces a choice.
instance Monad m => MonadPlus (PTrans err m) where
  mzero = PTrans (return Backtrack)
  mplus (PTrans a) (PTrans b) = PTrans $ do
    result <- a
    case result of
      Backtrack -> b
      PFail   u -> return (PFail u)
      OK      o -> return (OK o)
-- | 'throwError' is like to 'Parser's instantiation of 'Control.Monad.fail', except it takes a
-- polymorphic value, not just a string. The @err@ type is undefeind, so it makes sense to define it
-- once you have caught it, or to override the 'Control.Monad.Error.Class.throwError' function with
-- your own instantiation of a newtype of 'PTrans'.
instance Monad m => MonadError err (PTrans err m) where
  throwError msg = PTrans{ runPTrans = return (PFail msg) }
  catchError ptrans catcher = PTrans $ do
    value <- runPTrans ptrans
    case value of
      Backtrack -> return Backtrack
      PFail   u -> runPTrans (catcher u)
      OK      a -> return (OK a)
instance (Functor m, Monad m) => Applicative (PTrans err m) where { pure = return; (<*>) = ap; }
instance (Functor m, Monad m) => Alternative (PTrans err m) where { empty = mzero; (<|>) = mplus; }
instance MonadTrans (PTrans err) where { lift m = PTrans(m >>= return . OK) }
instance MonadIO m => MonadIO (PTrans err m) where { liftIO = PTrans . liftIO . fmap OK }

pvalue :: Monad m => PValue err ok -> PTrans err m ok
pvalue = assumePValue

----------------------------------------------------------------------------------------------------

-- | Monadic computations which have lifted the 'PValue' into them can instantiate this class. It is
-- similar to 'Control.Monad.MonadPlus', but supplies 'mplusCatch' instead of 'Control.Monad.mplus',
-- which behaves very similarly. 'mplusCatch' takes two alternative monadic computations, evaluates
-- the first, but will evaluate the second only if the first does not succeed, that is, if the first
-- evaluates to either 'Control.Monad.mzero' or to 'Control.Monad.Error.Class.throwError'.  Minimal
-- complete definition is 'catchPValue' and 'assumePValue'.
class (MonadError err m, MonadPlus m) => MonadPlusError err m where
  -- | Unlifts the 'PValue' resulting from evaluating the given monadic computation, returning the
  -- 'PValue' as 'Backtrack' if the given monad evaluates to 'Control.Monad.mzero' and as
  -- 'PFail' if the given monad evaluates to 'Control.Monad.Error.Class.throwError'.
  catchPValue :: m a -> m (PValue err a)
  -- | Lift a 'PFail' value into the monad with the given @ok@ and error values.
  assumePValue :: PValue err a -> m a
  -- | Like 'Comtrol.Monad.mplus', except the second function is tried even if the first monadic
  -- function evaluates to 'Control.Monad.Error.Class.throwError'. This is different from ordinary
  -- 'Control.Monad.mplus' which always evaluates to 'throwError' if one of it's given monadic
  -- computations evaluates as such. Said another way, this function "catches" errors and ignores
  -- them, instead trying the alternative function when an error or 'Control.Monad.mzero' occurs.
instance MonadPlusError err (PValue err) where { catchPValue = OK; assumePValue = id; }
instance Monad m => MonadPlusError err (PTrans err m) where
  catchPValue (PTrans fn) = PTrans{ runPTrans = fn >>= \a -> return (OK a) }
  assumePValue pval = PTrans (return pval)

-- | Evaluates to an empty list if the given 'PValue' is 'Backtrack' or 'PFail', otherwise returns a
-- list containing the value in the 'OK' value.
okToList :: PValue err a -> [a]
okToList pval = case pval of
  OK      a -> [a]
  Backtrack -> []
  PFail   _ -> []

-- | Like 'okToList', but evaluates to 'Data.Maybe.Nothing' if the given 'PValue' is 'Backtrack' or
-- 'PFail', or 'Data.Maybe.Just' containing the value in the 'OK' value.
okToMaybe :: PValue err a -> Maybe a
okToMaybe pval = case pval of
  OK      a -> Just a
  Backtrack -> Nothing
  PFail   _ -> Nothing

-- | Constructs a 'PFail' value with 'Data.Monoid.mempty'. Useful in functions that need to evaluate
-- to an error, but cannot (or doesn't need to) set more detailed information about the error. The
-- 'PFail' value can be caught elsewhere, and more detailed information can be constructed there.
pfail :: UStr -> PValue UStr ig
pfail msg = PFail msg

-- | If given 'Data.Maybe.Nothing', evaluates to 'Backtrack', otherwise evaluates to 'OK'.
maybeToBacktrack :: Maybe a -> PValue err a
maybeToBacktrack = maybe Backtrack OK

-- | If given 'Data.Maybe.Nothing', evaluates to 'PFail' with the given error information.
-- Otherwise, evaluates to 'OK'.
maybeToPFail :: err -> Maybe a -> PValue err a
maybeToPFail err a = case a of
  Nothing -> PFail err
  Just ok -> OK    ok

-- | If the given monadic function (which instantiates 'MonadPlusError') evaluates with a
-- controlling 'PValue' of 'PFail', the given mapping function is applied to the @ok@ value stored
-- within the 'PFail', then the modified 'PFail' is placed back into the monad transformer.
mapPFail :: (MonadPlusError errBefore m, MonadPlusError errAfter m) =>
  (errBefore -> errAfter) -> m ok -> m ok
mapPFail fmap func = catchPValue func >>= \pval -> case pval of
  OK     ok -> return ok
  Backtrack -> mzero
  PFail err -> assumePValue (PFail (fmap err))

