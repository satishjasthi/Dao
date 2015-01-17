-- "Dao/Rule.hs"  Monads for defining "intelligent" programs.
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

-- | This module provides the APIs for constructing a knowledge base of production rules, and for
-- matching expressions against the production rules. This module is really the core of the
-- artificial intelligence functionality. A knowledge base is a collection of facts and production
-- rules which can be queried. Evaluating a query matches the query against all facts and production
-- rules.
--
-- The monads defined here create a kind of Domain Specific Language that operates very similar to
-- the historic programming language PROLOG. The PROLOG programming language was infamously
-- difficult to reason about, but as a domain-specific language in Haskell, you can make use of
-- PROLOG's logic algorithm while using Haskell's clean, type-safe semantics for defining data
-- structures.
--
-- For those not familiar with PROLOG, you should at least be familiar with Haskell's type checking
-- system, which operates similarly to the PROLOG language. Polymorphic types (type variables) are
-- variables that can be matched against concrete types, and concrete types are bound to type
-- variables. The difference between Haskell's type checker and PROLOG is that if a type variable
-- matches two different concrete types in the same expression, this results in an error, whereas
-- PROLOG would backtrack and continue trying to find a set of concrete types that could match the
-- type variables unambiguously.
--
-- Another place you may have seen knowledge base algorithms is in the UNIX @make@ program, where
-- you specify a set of production rules in a file called @Makefile@. The @Makefile@ serves as the
-- knowledge base containing the production rules, while the files and directories in the same
-- directory as the @Makefile@ serve as the "facts" of the knowledge base. Executing @make@ will
-- check the "facts" (the state of the files and directories) by matching them to the production
-- rules, except the matching algorithm ignores files older than the time stamp of the "Makefile",
-- this is how @make@ knows which files have changed and need to re-built. Naturally, there is no
-- such restriction in the "Dao.Rule".
module Dao.Rule
  ( -- * The 'Query' type
    Query, QueryState(QueryState), queryScore, queryInput,
    -- * Production Rules: the 'Rule' Monad
    Rule, evalRuleLogic, queryAll, query, query1, next, part, done,
    limitByScore, bestMatch, resetScore,
    -- * The Branch Structure of a Rule
    -- $Structure_of_a_rule
    RuleStruct, tree, struct, getRuleStruct, trim, mask,
    -- * Convenient Rule Trees
    TypePattern(TypePattern), patternTypeRep, infer,
    -- * Predicting User Input
    Predictor, predictorQuery, startGuess, continueGuess, predictorCanStep, predictorStep,
    predictorGuesses,
    -- * Re-export the "Dao.Logic" module.
    module Dao.Logic
  )
  where

import           Dao.Lens
import           Dao.Logic
import           Dao.Object
import           Dao.PPrint
import           Dao.TestNull
import qualified Dao.Tree as T

import           Control.Arrow
import           Control.Applicative
import           Control.Monad
import           Control.Monad.State
import           Control.Monad.Reader.Class
import           Control.Monad.Except

import           Data.Dynamic
import           Data.Either
import           Data.List
import           Data.Monoid
import qualified Data.Map as M

----------------------------------------------------------------------------------------------------

-- | A 'Query' is the list of 'Dao.Object.Object's input by the end user to the knowledge base. Your
-- program will construct a 'Query' and use 'queryAll', 'query', or 'query1' with a 'Rule' monad to
-- perform a logical computation.
type Query = [Object]

-- | The 'Query' type synonym is simply a list of 'Dao.Object.Object's paird with an integer score.
-- When evaluating a 'Rule' monad, the 'queryInput' is tested by various 'Rule' functions to produce
-- a result, and the result is 'Control.Monad.return'ed when all the 'Rule's that can possibly match
-- have matched against the 'queryInput', and all possible results that have been successfully
-- 'Control.Monad.return'ed. A 'queryScore' is kept, which counts how many 'Dao.Object.Object' items
-- from the 'queryInput' have matched so far. This 'queryScore' can be helpful in narrowing the list
-- of potential results.
data QueryState = QueryState Int Query deriving (Eq, Ord, Show, Typeable)

instance TestNull QueryState where
  nullValue = QueryState 0 []
  testNull (QueryState i q) = i==0 && null q

queryInput :: Monad m => Lens m QueryState Query
queryInput = newLens (\ (QueryState _ q) -> q) (\q (QueryState i _) -> QueryState i q)

queryScore :: Monad m => Lens m QueryState Int
queryScore = newLens (\ (QueryState i _) -> i) (\i (QueryState _ q) -> QueryState i q)

----------------------------------------------------------------------------------------------------

-- | A 'Rule' is a monadic function that defines the behavior of a production rule in a
-- 'KnowledgeBase'. A 'KnowledgeBase' is queried with a list of 'Dao.Object.Object's being matched
-- against a sequence of this 'Rule' data type.
--
-- When query is matched agains a 'Rule', the query is placed into an internal stateful monad, and
-- as the 'Rule' is evaluated, the query is deconstructed. Evaluating to
-- 'Control.Applicative.empty' or 'Control.Monad.mzero' indicates a non-match and evaluation
-- backtracks. Evaluating 'Control.Monad.return' indicates a success, and the returned
-- 'Dao.Object.Object' is used as the result of the production.
--
-- The 'Rule' monad instantiates 'Control.Monad.Except.Class.MonadError' such that
-- 'Dao.Object.ErrorObject's can be thrown and caught. The 'Rule' monad instantiates
-- 'Dao.Logic.MonadLogic' so it is possible to pattern match with many
-- 'Control.Applicative.Alternative' branches of evaluation without having to worry about the
-- current state. 'Control.Monad.State.Class.MonadState' is instantiated giving you total control of
-- the state, along with the 'Dao.Logic.MonadLogic' functions. And
-- 'Control.Monad.Reader.Class.MonadReader' is instantiated so that the
-- 'Control.Monad.Reader.Class.local' function can be used to execute rules with a different input
-- in a different context without altering the current context.
data Rule m a
  = RuleEmpty
  | RuleReturn a
  | RuleError ErrorObject
  | RuleLift (m (Rule m a))
  | RuleLogic (T.Tree Object ()) (LogicT QueryState m (Either ErrorObject (Rule m a)))
  | RuleChoice (Rule m a) (Rule m a)
  | RuleTree  (M.Map Object (T.Tree Object (Query -> Rule m a)))
              (M.Map Object (T.Tree Object (Query -> Rule m a)))
    -- DepthFirst and BreadthFirst rule trees are kept separate.

instance Functor m => Functor (Rule m) where
  fmap f rule = case rule of
    RuleEmpty      -> RuleEmpty
    RuleReturn   o -> RuleReturn $ f o
    RuleError  err -> RuleError err
    RuleLift     o -> RuleLift $ fmap (fmap f) o
    RuleLogic  t o -> RuleLogic t $ fmap (fmap (fmap f)) o
    RuleChoice x y -> RuleChoice (fmap f x) (fmap f y)
    RuleTree   x y -> let map = fmap (fmap (fmap (fmap f))) in RuleTree (map x) (map y)

instance (Applicative m, Monad m) => Applicative (Rule m) where { pure = return; (<*>) = ap; }

instance (Applicative m, Monad m) => Alternative (Rule m) where { empty = mzero; (<|>) = mplus; }

instance (Functor m, Applicative m, Monad m) => Monad (Rule m) where
  return = RuleReturn
  rule >>= f = case rule of
    RuleEmpty      -> RuleEmpty
    RuleReturn   o -> f o
    RuleError  err -> RuleError err
    RuleLift     o -> RuleLift $ fmap (>>= f) o
    RuleLogic  t o -> RuleLogic t $ fmap (fmap (>>= f)) o
    RuleChoice x y -> RuleChoice (x >>= f) (y >>= f)
    RuleTree   x y -> let map = fmap $ fmap $ fmap (>>= f) in RuleTree (map x) (map y)
  a >> b = case a of
    RuleEmpty        -> RuleEmpty
    RuleReturn _     -> b
    RuleError  err   -> RuleError err
    RuleLift   a     -> RuleLift $ fmap (>> b) a
    RuleLogic  tA a  -> case b of
      RuleLogic tB b   -> RuleLogic (T.product tA tB) (a >> b)
      b                -> RuleLogic tA $ fmap (fmap (>> b)) a
    RuleChoice a1 a2 -> RuleChoice (a1 >> b) (a2 >> b)
    RuleTree   a1 a2 -> case b of
      RuleEmpty        -> RuleEmpty
      RuleError  err   -> RuleError err
      RuleTree   b1 b2 ->
        let wrap map = T.Tree (Nothing, map)
            unwrap (T.Tree (_, tree)) = tree
            power a b = unwrap $ T.productWith (>>) (wrap a) (wrap b)
        in  RuleTree (power a1 b1) (power a2 b2)
      b                -> let bind = fmap $ fmap $ fmap (>> b) in RuleTree (bind a1) (bind a2)
  fail = RuleError . return . obj

instance (Functor m, Applicative m, Monad m) => MonadPlus (Rule m) where
  mzero = RuleEmpty
  mplus a b = case a of
    RuleEmpty        -> b
    RuleChoice (RuleChoice a1 a2) a3 -> mplus a1 $ mplus a2 $ mplus a3 b
    RuleChoice a1 (RuleChoice a2 a3) -> RuleChoice a1 $ RuleChoice a2 $ mplus a3 b
    RuleChoice a1 a2 -> case b of
      RuleEmpty        -> a
      b                -> RuleChoice a1 $ RuleChoice a2 b
    RuleTree   a1 a2 -> case b of
      RuleEmpty        -> a
      RuleChoice b1 b2 -> RuleChoice (mplus a b1) b2
      RuleTree   b1 b2 ->
        let plus = T.unionWith (\a b q -> mplus (a q) (b q))
        in  RuleTree (M.unionWith plus a1 b1) (M.unionWith plus a2 b2)
      b                -> RuleChoice a b
    RuleLogic  tA a  -> case b of
      RuleEmpty        -> RuleLogic tA a
      RuleLogic  tB b  -> RuleLogic (T.union tA tB) $ mplus a b
      b                -> RuleChoice (RuleLogic tA a) b
    a                -> case b of
      RuleEmpty        -> a
      b                -> RuleChoice a b

instance (Functor m, Applicative m, Monad m) => MonadError ErrorObject (Rule m) where
  throwError            = RuleError
  catchError rule catch = case rule of
    RuleError o -> catch o
    _           -> rule

instance (Functor m, Applicative m, Monad m) => MonadState Query (Rule m) where
  state f = RuleLogic nullValue $ state $ \st ->
    let (o, q) = f $ st & queryInput in (Right $ return o, on st [queryInput <~ q])

instance (Functor m, Applicative m, Monad m) => MonadReader Query (Rule m) where
  ask = get;
  local f sub = RuleLogic (getRuleStruct sub) $ do
    st <- state $ \st -> (st, on st [queryInput $= f])
    evalRuleLogic sub >>= return . Left ||| state . const . flip (,) st . Right . return

instance (Functor m, Applicative m, Monad m) => MonadLogic Query (Rule m) where
  superState  f = RuleLogic nullValue $ superState $ \st ->
    fmap (\ (o, q) -> (Right $ return o, on st [queryInput <~ q])) $ f $ st & queryInput
  entangle rule = RuleLogic (getRuleStruct rule) $ do
    let lrzip (o, qx) = (\err -> ([(err, qx)], [])) ||| (\o -> ([], [(o, qx)])) $ o
    (errs, ox) <- (concat *** concat) . unzip . fmap lrzip <$> entangle (evalRuleLogic rule)
    superState $ \st -> (Right $ return $ second (& queryInput) <$> ox, st) : fmap (first Left) errs

instance (Functor m, Applicative m, Monad m) => Monoid (Rule m o) where
  mempty  = mzero
  mappend = mplus

----------------------------------------------------------------------------------------------------

-- | Evaluate a 'Rule' by flattening it's internal 'Dao.Tree.Tree' structure to a 'Dao.Logic.LogicT'
-- monad. This is probably not as useful of a function as 'queryAll' or 'query'.
evalRuleLogic
  :: forall m a . (Functor m, Applicative m, Monad m)
  => Rule m a -> LogicT QueryState m (Either ErrorObject a)
evalRuleLogic rule = case rule of
  RuleEmpty      -> mzero
  RuleReturn   o -> return $ Right o
  RuleError  err -> return $ Left err
  RuleLift     o -> lift o >>= evalRuleLogic
  RuleLogic  _ o -> o >>= return . Left ||| evalRuleLogic
  RuleChoice x y -> evalRuleLogic x <|> evalRuleLogic y
  RuleTree   x y -> runMap T.DepthFirst [] x <|> runMap T.BreadthFirst [] y where
    runMap control qx map = if M.null map then mzero else do
      q <- next
      let (equal, similar) = partition ((ExactlyEqual ==) . fst) $
            (do (o, tree) <- M.assocs map
                let result = objMatch o q
                if result==Dissimilar then [] else [(result, tree)]
            )
      tree <- superState $ \st -> flip zip (repeat st) $
        if null equal
        then snd <$> sortBy (\a b -> compare (fst b) (fst a)) similar
        else snd <$> equal
      loop control (qx++[q]) tree
    loop control qx tree@(T.Tree (rule, map)) = if T.null tree then mzero else
      ((if control==T.DepthFirst then id else flip) mplus)
        (runMap control qx map)
        (maybe mzero (evalRuleLogic . ($ qx)) rule)

-- | Run a 'Rule' against an @['Dao.Object.Object']@ query, return all successful results and all
-- exceptions that may have been thrown by 'Control.Monad.Except.throwError'.
queryAll :: (Functor m, Applicative m, Monad m) => Rule m a -> Query -> m [Either ErrorObject a]
queryAll rule = fmap (fmap fst) . runLogicT (evalRuleLogic rule) . QueryState 0

-- | Run a 'Rule' against an @['Dao.Object.Object']@ query, return all successful results.
query :: (Functor m, Applicative m, Monad m) => Rule m a -> Query -> m [a]
query r = fmap (>>= (const [] ||| return)) . queryAll r

-- | Like 'query', but only returns the first successful result, if any.
query1 :: (Functor m, Applicative m, Monad m) => Rule m a -> Query -> m (Maybe a)
query1 r = fmap (\ox -> if null ox then Nothing else Just $ head ox) . query r

-- | Take the next item from the query input, backtrack if there is no input remaining.
--
-- This function is polymorphic over a monadic type that instantiates 'Dao.Logic.MonadLogic',
-- however consider the type of this function to be
--
-- @
-- ('Data.Functor.Functor' m, 'Control.Applicative.Applicative' m, 'Control.Monad.Monad' m) => 'Rule' m 'Dao.Object.Object'
-- @
next :: (Functor m, Applicative m, Monad m, MonadLogic QueryState m) => m Object
next = superState $ \q -> if null $ q & queryInput then [] else
  [(head $ q & queryInput, on q [queryInput $= tail, queryScore $= (+ 1)])]

-- | Take as many of next items from the query input as necessary to make the reset of the 'Rule'
-- match the input query. This acts as kind of a Kleene star.
--
-- This function is polymorphic over a monadic type that instantiates 'Dao.Logic.MonadLogic',
-- however consider the type of this function to be:
--
-- @
-- ('Data.Functor.Functor' m, 'Control.Applicative.Applicative' m, 'Control.Monad.Monad' m) => 'Rule' m 'Dao.Object.Object'
-- @
part :: (Functor m, Applicative m, Monad m, MonadLogic QueryState m) => m Query
part = superState $ loop 0 [] where
  loop score lo q = case q & queryInput of
    []   -> [(lo, on q [queryScore <~ score])]
    o:ox -> let q' = on q [queryInput <~ ox, queryScore <~ score]
            in (lo, q') : loop (score+1) (lo++[o]) q'

-- | Match when there are no more arguments, backtrack if there are.
--
-- This function is polymorphic over a monadic type that instantiates 'Dao.Logic.MonadLogic',
-- however consider the type of this function to be:
--
-- @
-- ('Data.Functor.Functor' m, 'Control.Applicative.Applicative' m, 'Control.Monad.Monad' m) => 'Rule' m 'Dao.Object.Object'
-- @
done :: (Functor m, Applicative m, Monad m, MonadLogic QueryState m) => m ()
done = superState $ \q -> if null $ q & queryInput then [((), q)] else []

-- | Fully evaluate a 'Rule', and collect all possible results along with their 'queryScore's. Pass
-- these results to a filter function, and procede with 'Rule' evaluation using only the results
-- allowed by the filter function. This function uses the 'Dao.Logic.entangle' operation, so it will
-- fully evaluate the given monadic function before returning.
--
-- This function is polymorphic over a monadic type that instantiates 'Dao.Logic.MonadLogic',
-- however consider the type of this function to be:
--
-- @
-- ('Data.Functor.Functor' m, 'Control.Applicative.Applicative' m, 'Control.Monad.Monad' m) => 'Rule' m 'Dao.Object.Object'
-- @
limitByScore
  :: (Functor m, Applicative m, Monad m)
  => ([(a, QueryState)] -> [(a, QueryState)])
  -> Rule m a -> Rule m a
limitByScore filter f = do
  (err, ox) <-
    ( (concat *** concat) . unzip
    . fmap (\ (o, qs) -> (\o -> ([(Left o, qs)], [])) ||| (\o -> ([], [(o, qs)])) $ o)
    ) <$> RuleLogic (getRuleStruct f) (fmap (Right . return) $ entangle $ evalRuleLogic f)
  -- ox <- filter <$> forM ox (\ (o, qs) -> flip (,) qs <$> o)
  RuleLogic nullValue $ superState $ const $ (first (Right . return) <$> filter ox) ++ err

-- | Like 'limitByScore' but the filter function simply selects the results with the highet
-- 'queryScore'.
bestMatch :: (Functor m, Applicative m, Monad m) => Rule m a -> Rule m a
bestMatch = let score = (& queryScore) . snd in limitByScore $ concat .
  take 1 . groupBy (\a b -> score a == score b) . sortBy (\a b -> score b `compare` score a)

-- | Evaluate a monadic function with the 'queryScore' reset to zero, and when evaluation of the
-- monadic function completes, set the score back to the value it was before.
--
-- This function is polymorphic over a monadic type that instantiates 'Dao.Logic.MonadLogic',
-- however consider the type of this function to be:
--
-- @
-- ('Data.Functor.Functor' m, 'Control.Applicative.Applicative' m, 'Control.Monad.Monad' m) => 'Rule' m 'Dao.Object.Object'
-- @
resetScore :: (Functor m, Applicative m, Monad m) => Rule m a -> Rule m a
resetScore f = do
  score <- RuleLogic (getRuleStruct f) $ state $ \q ->
    (Right . return $ q & queryScore, on q [queryScore <~ 0])
  f <* RuleLogic nullValue (fmap (Right . return) $ modify $ by [queryScore <~ score])

----------------------------------------------------------------------------------------------------

-- $Structure_of_a_rule
-- A 'Rule' is constructed from 'Dao.Tree.Tree' data types and functions. Some 'Rule's form empty
-- trees, for example 'Control.Monad.return' or 'Control.Monad.State.state'. However 'Rule's
-- constructed with functions like 'tree' or 'struct' produce a 'Dao.Tree.Tree' structure internal
-- to the 'Rule' function which can be retrieved and manipulated. This is useful for
-- meta-programming 'Rule's, for example predictive input applications.

-- | This is the data type that models the branch structure of a 'Rule'. It is a 'Dao.Tree.Tree'
-- with 'Dao.Object.Object' paths and @()@ leaves. It is possible to perform modifications to some
-- 'Rule's, for example 'trim'-ing of branches, using a 'RuleStruct'.
type RuleStruct = T.Tree Object ()

-- | Take a list of lists of a type of 'Dao.Object.ObjectData' and construct a 'Rule' tree that will
-- match any 'Query' similar to this list of 'Dao.Object.ObjectData' values (using
-- 'Dao.Object.objMatch'). Every list of 'Dao.Object.ObjectData' will become a branch associated
-- with the given 'Rule' monadic function (constructed using the 'Dao.Tree.fromList' function). This
-- 'Rule' function must take a 'Query' as input. When a portion of a 'Query' matches the given
-- 'Dao.Object.ObjectData', the portion of the 'Query' that matched will be passed to this 'Rule'
-- function when it is evaluated.
tree
  :: (Functor m, Applicative m, Monad m, ObjectData a)
  => T.RunTree -> [[a]] -> (Query -> Rule m b) -> Rule m b
tree control branches f = struct control (T.fromList $ zip (fmap obj <$> branches) $ repeat ()) f

-- | Construct a 'Rule' tree from a 'Dao.Tree.Tree' data type and a 'Rule' function. The 'Rule' will
-- be copied to every single 'Dao.Tree.Leaf' in the given 'Dao.Tree.Tree'.
struct
  :: (Functor m, Applicative m, Monad m)
  => T.RunTree -> RuleStruct -> (Query -> Rule m a) -> Rule m a
struct control tree rule =
  let df = control==T.DepthFirst
      (T.Tree (leaf, map)) = fmap (\ () -> rule) tree 
  in  maybe id ((if df then flip else id) mplus . ($ [])) leaf $
        ((if df then id else flip) RuleTree) map nullValue

-- | Remove all of the 'Rule's and return only the 'Dao.Tree.Tree' structure. This function cannot
-- retrieve the entire 'Dao.Tree.Tree', it can only see the 'Dao.Tree.Tree' created by the 'tree'
-- function, or some combination of rules created by the 'tree' function (for example two 'tree's
-- 'Control.Monad.mplus'sed together). 'Rule's created with functions like 'Control.Monad.return',
-- @('Control.Monad.>>=')@, @('Control.Applicative.<*>')@, 'Control.Monad.State.state',
-- 'Control.Monad.Trans.lift', and others all introduce opaque function data types into the leaves
-- which cannot be 'Data.Traversal.traverse'd.
getRuleStruct :: Rule m o -> RuleStruct
getRuleStruct rule = case rule of
  RuleEmpty      -> T.empty
  RuleTree   x y ->
    let blank o = fmap (fmap (const ())) o
    in  T.Tree (Nothing, M.union (blank x) (blank y))
  RuleChoice x y -> T.union (getRuleStruct x) (getRuleStruct y)
  _              -> T.Tree (Just (), M.empty)

-- | With a 'RuleStruct' delete any of the matching branches from the 'Rule' tree. Branch matching
-- uses the @('Prelude.==')@ predicate, not 'Dao.Object.objMatch'. This is the dual of 'mask' in
-- that @'trim' struct t 'Data.Monoid.<>' 'mask' struct t == t@ is always true.
-- This function works by calling 'Dao.Tree.difference' on the 'Rule' and the 'Dao.Tree.Tree'
-- constructed by the 'Dao.Tree.blankTree' of the given list of 'Dao.Object.ObjectData' branches.
trim :: (Functor m, Applicative m, Monad m) => RuleStruct -> Rule m a -> Rule m a
trim tree@(T.Tree (leaf, map)) rule = case rule of
  RuleEmpty      -> RuleEmpty
  RuleTree   x y -> RuleTree (del x) (del y)
  RuleChoice x y -> RuleChoice (trim tree x) (trim tree y)
  rule           -> maybe rule (\ () -> mzero) leaf
  where
    treeDiff a b = let c = T.difference a b in guard (not $ T.null c) >> return c
    del          = flip (M.differenceWith treeDiff) map

-- | With 'RuleStruct' and delete any of the branches from the 'Rule' tree that do *not* match the
-- 'RuleStruct' This is the dual of 'trim' in that
-- @'trim' struct t 'Data.Monoid.<>' 'mask' struct t == t@ is always true. Branch matching uses the
-- @('Prelude.==')@ predicate, not 'Dao.Object.objMatch'. This function works by calling
-- 'Dao.Tree.intersection' on the 'Rule' and the 'Dao.Tree.Tree' constructed by the
-- 'Dao.Tree.blankTree' of the given list of 'Dao.Object.ObjectData' branches.
mask :: (Functor m, Applicative m, Monad m) => RuleStruct -> Rule m a -> Rule m a
mask tree@(T.Tree (leaf, map)) rule = case rule of
  RuleEmpty      -> RuleEmpty
  RuleTree   x y -> RuleTree (del x) (del y)
  RuleChoice x y -> RuleChoice (mask tree x) (mask tree y)
  rule           -> maybe mzero (\ () -> rule) leaf
  where
    del = flip (M.intersectionWith T.intersection) map

----------------------------------------------------------------------------------------------------

-- | This data type is an 'Dao.Object.Object' containing a 'Data.Typeable.TypeRep'. When
-- constructing a 'RuleTree', this pattern will match any object that matches the type it contains.
-- Use 'objTypeOf'
newtype TypePattern = TypePattern { patternTypeRep :: TypeRep } deriving (Eq, Ord, Typeable)

instance HasTypeRep TypePattern where { objTypeOf (TypePattern o) = o; }

instance Show TypePattern where { show (TypePattern o) = show o; }

instance PPrintable TypePattern where { pPrint = return . pShow; }

instance SimpleData TypePattern where
  simple (TypePattern o) = simple o
  fromSimple = fmap TypePattern . fromSimple

instance ObjectPattern TypePattern where
  objMatch (TypePattern p) o = if p==objTypeOf o then Similar 0.0 else Dissimilar

instance ObjectData TypePattern where
  obj p = obj $ printable p $ matchable p $ simplifyable p $ toForeign p
  fromObj = defaultFromObj

-- | Use 'next' to take the next item from the current 'Query', evaluate the 'Data.Typeable.TypeRep'
-- of the 'next' 'Dao.Object.Object' using 'objTypeOf', compare this to the to the
-- 'Data.Typeable.TypeRep' of @t@ inferred by 'Data.Typeable.typeOf'. Compare these two types using
-- @('Prelude.==')@, and if 'Prelude.True' evaluate a function on it.  This function makes a new
-- 'RuleTree' where the pattern in the branch is a 'TypePattern'. For example, if you pass a
-- function to 'infer' which is of the type @('Prelude.String' -> 'Rule' m a)@, 'infer' will create
-- a 'RuleTree' that matches if the 'Dao.Object.Object' returned by 'next' can be cast to a value of
-- 'Prelude.String'.
infer
  :: forall m t a . (Functor m, Applicative m, Monad m, Typeable t, ObjectData t)
  => (t -> Rule m a) -> Rule m a
infer f = tree T.BreadthFirst [[typ f err]] $ msum . fmap (fromObj >=> f) where
  typ :: (t -> Rule m a) -> t -> TypePattern
  typ _ ~t = TypePattern $ typeOf t
  err :: t
  err = error "in Dao.Rule.infer: typeOf evaluated undefined"

----------------------------------------------------------------------------------------------------

-- | This data type provides free predictive input functionality to the 'Dao.Rule.Rule' monad. This
-- is a data type that wraps a 'Dao.Rule.Rule' which can be queried by the 'startGuess' function.
-- Then use the 'predictorGuesses' 'Dao.Lens.Lens' to retrieve a list of possible completitions. You
-- can insert or remove elements from a 'Query' stored in the 'Predictor' to re-evaluate without
-- having to start again from the beginning every time.
--
-- This functionality can be useful in command line interfaces where the end user presses the "tab"
-- key on the keyboard, the key event can be bound to a callback that tokenizes the input and feeds
-- it into your 'Rule' knowledge base via the 'continueQuery' function, pausing at the end of the
-- input 'Query' to retrieve predictions for what the end user may enter next.
data Predictor m a
  = Predictor QueryState (Rule m a) [(QueryState, Rule m a)] [Either ErrorObject a]
  deriving Typeable

instance TestNull (Predictor m a) where
  nullValue = Predictor nullValue RuleEmpty [] []
  testNull (Predictor qs RuleEmpty [] []) = testNull qs
  testNull _                              = False

-- This is the input 'Query'. It is best not to modify this directly. Use 'startGuess' and
-- 'changeGuess' instead.
_predictorQueryState :: Monad l => Lens l (Predictor m a) QueryState
_predictorQueryState =
  newLens (\ (Predictor q _ _ _) -> q) (\q (Predictor _ r s t) -> Predictor q r s t)

-- This is the current 'Rule' that will be evaluated using the '_predictorQueryState'.
_predictorRule  :: Monad l => Lens l (Predictor m a) (Rule m a)
_predictorRule  =
  newLens (\ (Predictor _ r _ _) -> r) (\r (Predictor q _ s t) -> Predictor q r s t)

-- This is the stack which contains all of the 'Rule' branches not taken. You can pop the stack and
-- try alternate branches of evaluation.
_predictorStack :: Monad l => Lens l (Predictor m a) [(QueryState, Rule m a)]
_predictorStack =
  newLens (\ (Predictor _ _ s _) -> s) (\s (Predictor q r _ t) -> Predictor q r s t)

-- This is the 'Predictor' that will be evaluated next.
_predictorReturns :: Monad l => Lens l (Predictor m a) [Either ErrorObject a]
_predictorReturns =
  newLens (\ (Predictor _ _ _ t) -> t) (\t (Predictor q r s _) -> Predictor q r s t)

-- | This is the list of guesses for what the next input might be.
predictorGuesses :: Predictor m a -> [Query]
predictorGuesses = fmap fst . T.assocs T.BreadthFirst . getRuleStruct . (& _predictorRule)

-- | This is the 'Query' that has been input by the user so far. This 'Dao.Lens.Lens' may be useful
-- in tab-completion, where every time the end user presses the "tab" key, the entire line of input
-- up to the tab-press is re-evaluated. This function takes steps to avoid as much re-evaluation of
-- the 'Rule' as possible by comparing the current 'predictorQuery' to the 'Query' assigned to it
-- with the @('Dao.Lens.<~')@ operator. But if the end user has completely deleted the input and
-- started with something new, it is unavoidable that the 'Predictor' simply must be fully reset.
predictorQuery :: Monad l => Lens l (Predictor m a) Query
predictorQuery = newLens fetch update where
  fetch (Predictor q _ s _) =
    concat $ reverse $ ((q & queryInput) :) $ fmap ((& queryInput) . fst) s
  update ox (Predictor q r s t) =
    let loop qs r s' s ox = let done = Predictor (on q [queryInput <~ ox]) r s' t in case s of
          []          -> done
          (qs', r'):s -> case stripPrefix (qs & queryInput) ox of
            Nothing -> done
            Just ox -> loop qs' r' ((qs, r):s') s ox
    in  case reverse s of
          []        -> Predictor (on q [queryInput <~ ox]) r [] []
          (qs, r):s -> loop qs r [] s ox

----------------------------------------------------------------------------------------------------

-- | This function is similar to the 'queryAll' function, except evaluation occurs in steps that can
-- be controlled by 'predictorStep', 'predictorBack', and 'changeGuess'.
startGuess :: (Functor m, Applicative m, Monad m) => Rule m a -> Query -> Predictor m a
startGuess r q = Predictor (QueryState 0 q) r [] []

-- | Append more of a 'Query' to the current 'Predictor's 'QueryState'.
continueGuess :: (Functor m, Applicative m, Monad m) => Query -> Predictor m a -> Predictor m a
continueGuess q p = on p [_predictorQueryState >>> queryInput $= (++ q)]

-- | A predicate indicating whether it is possible for the 'Predictor' to be stepped by
-- 'predictorStep'.
predictorCanStep :: Predictor m a -> Bool
predictorCanStep p = case p & _predictorRule of
  RuleEmpty    -> False
  RuleReturn{} -> False
  RuleError{}  -> False
  _            -> not $ null $ p & _predictorQueryState & queryInput

-- | This function takes a single item from the '_predictorQueryState' and uses it to evaluate a single
-- step of the '_predictorRule' consuming as much of the input 'Query' in 'predictorQuery'. Once this
-- evaluation has completed, check the '_predictorGuesses' for possible completions. It is then
-- possible to append these completions to the 'predictorQuery' and evaluate 'predictorStep' again.
predictorStep :: (Functor m, Applicative m, Monad m) => Predictor m a -> m (Predictor m a)
predictorStep p = case p & _predictorRule of
  RuleLift     o -> o >>= \rule -> predictorStep $ on p [_predictorRule <~ rule]
  RuleLogic  _ o -> do
    (errs, rules) <- logic o
    return $ update errs $ on p $ [_predictorRule <~ msum rules]
  RuleTree   a b -> evalTree [] $ union (mkT a) (mkT b)
  RuleChoice a b -> do
    let uw = unwrap [] nullValue
    (errsA, tA) <- uw a
    (errsB, tB) <- uw b
    evalTree (errsA++errsB) (union tA tB)
  _              -> return p
  where
    mkT t = T.Tree (Nothing, t)
    union = T.unionWith (\a b q -> mplus (a q) (b q))
    logic o = first (fmap Left) . partitionEithers <$> evalLogicT o (p & _predictorQueryState) 
    evalTree errs t = do
      let q = p & _predictorQueryState & queryInput
      return $ update errs $ on p $
        [ _predictorRule <~ maybe RuleEmpty ($ q) $ T.lookup q $ t
        , _predictorQueryState >>> queryScore $= (+ (length q))
        ]
    leaf errs t o = return (errs, union t $ T.Tree (Just $ const o, nullValue))
    unwrap errs t a = case a of
      RuleEmpty      -> return (errs, t)
      RuleReturn   a -> leaf errs t (return a)
      RuleError    a -> leaf errs t (RuleError a)
      RuleLift     a -> a >>= unwrap errs t
      RuleLogic  _ a -> do
        (errs', rules) <- logic a
        leaf (errs++errs') t (msum rules)
      RuleChoice a b -> unwrap errs t a >>= \ (errs, t) -> unwrap errs t b
      RuleTree   a b -> return (errs, union (mkT a) (mkT b))
    update errs p = on p $ case p & _predictorRule of
      RuleEmpty      -> [_predictorReturns <~ errs          ]
      RuleReturn   o -> [_predictorReturns <~ Right o : errs]
      RuleError    o -> [_predictorReturns <~ Left  o : errs]
      RuleLift     _ -> []
      rule           ->
        [ _predictorStack   $= ((p & _predictorQueryState, p & _predictorRule) :)
        , _predictorRule    <~ rule
        , _predictorReturns <~ errs
        ]

