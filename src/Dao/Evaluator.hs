-- "src/Dao/Evaluator.hs"  provides functions for executing the Dao
-- scripting language, i.e. functions evaluating the parsed abstract
-- syntax tree.
-- 
-- Copyright (C) 2008-2012  Ramin Honary.
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


-- {-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}

module Dao.Evaluator where

import           Dao.Debug.OFF
import           Dao.Token
import           Dao.Types
import qualified Dao.Tree as T
import           Dao.Pattern
import           Dao.Resource
import           Dao.Predicate
import           Dao.Combination

import           Dao.Object.Monad
import           Dao.Object.Math
import           Dao.Object.Show
import           Dao.Object.Binary
import           Dao.Object.Pattern

import           Control.Exception
import           Control.Monad.Trans
import           Control.Monad.Reader
import           Control.Monad.State -- for constructing 'Program's from 'SourceCode's.

import           Data.Monoid
import           Data.Maybe
import           Data.Either
import           Data.Array.IArray
import           Data.Int
import           Data.Word
import           Data.Bits
import           Data.List
import           Data.Time.Clock
import           Data.Ratio
import           Data.Complex
import           Data.IORef
import qualified Data.Set    as S
import qualified Data.Map    as M
import qualified Data.IntMap as I
import qualified Data.ByteString.Lazy.UTF8 as U

--debug: for use with "trace"
--import Debug.Trace

----------------------------------------------------------------------------------------------------

initExecUnit :: Runtime -> TreeResource -> Run ExecUnit
initExecUnit runtime initGlobalData = do
  unctErrs <- dNewMVar xloc "ExecUnit.uncaughtErrors" []
  recurInp <- dNewMVar xloc "ExecUnit.recursiveInput" []
  qheap    <- newTreeResource  "ExecUnit.queryTimeHeap" T.Void
  xstack   <- dNewMVar xloc "ExecUnit.execStack" emptyStack
  toplev   <- dNewMVar xloc "ExecUnit.toplevelFuncs" M.empty
  files    <- dNewMVar xloc "ExecUnit.execOpenFiles" M.empty
  cache    <- dNewMVar xloc "ExecUnit.referenceCache" M.empty
  return $
    ExecUnit
    { parentRuntime      = runtime
    , currentExecJob     = Nothing
    , currentDocument    = Nothing
    , currentProgram     = Nothing
    , currentTask        = error "ExecUnit.currentTask is undefined"
    , currentBranch      = []
    , importsTable       = []
    , execAccessRules    = RestrictFiles (Pattern{getPatUnits = [Wildcard], getPatternLength = 1})
    , builtinFuncs       = initBuiltinFuncs
    , toplevelFuncs      = toplev
    , execHeap           = initGlobalData
    , queryTimeHeap      = qheap
    , referenceCache     = cache
    , execStack          = xstack
    , execOpenFiles      = files
    , recursiveInput     = recurInp
    , uncaughtErrors     = unctErrs
    }

setupExecutable :: Bugged r => Com [Com ScriptExpr] -> ReaderT r IO Executable
setupExecutable scrp = do
  staticRsrc <- lift (newIORef M.empty)
  return $
    Executable
    { staticVars = staticRsrc
    , executable = map unComment (unComment scrp)
    }

runExecutable :: T_tree -> Executable -> ExecScript Object
runExecutable initStack exe =
  localCE (\xunit -> return (xunit{currentTask = (currentTask xunit){taskAction = exe}})) $
    execFuncPushStack initStack (executable exe >> return ONull)

-- | Given a list of arguments, matches these arguments toe the given subroutine's
-- 'Dao.Object.ObjPat'. If it matches, the 'Dao.Types.getScriptExpr' of the 'Dao.Types.Executable'
-- is evaluated with 'runExecutable'. If the pattern does not match, 'Nothing' is returned to the
-- 'Dao.Types.ExecScript' monad, which allows multiple 'Dao.Types.Subroutine's to be tried before
-- evaluating to an error in the calling context.
runSubroutine :: [Object] -> Subroutine -> ExecScript (Maybe Object)
runSubroutine args sub =
  case evalMatcher (matchObjectList (argsPattern sub) args >> gets matcherTree) of
    OK       tree -> fmap Just (runExecutable tree (getScriptExpr sub))
    Backtrack     -> return Nothing
    PFail ref msg -> ceError (OPair (OString msg, ORef ref))

-- | Execute a 'Dao.Types.Script' with paramters passed as a list of 
-- @'Dao.Types.Com' 'Dao.Object.ObjectExpr'@. This essentially treats the application of
-- paramaters to a script as a static abstract syntax tree, and converts this tree to an
-- @'ExecScript' 'Dao.Types.Object'@ function.
execScriptCall :: [Com ObjectExpr] -> FuncExpr -> ExecScript Object
execScriptCall args scrp = bindArgsExpr (unComment (scriptArgv scrp)) args $
  catchCEReturn (execScriptBlock (unComment (scriptCode scrp)) >> ceReturn ONull)

-- | Execute a 'Dao.Types.Rule' object as though it were a script that could be called. The
-- parameters passed will be stored into the 'currentMatch' slot durring execution, but all
-- parameters passed must be of type 'Dao.Types.OString', or an error is thrown.
execRuleCall :: [Com ObjectExpr] -> RuleExpr -> ExecScript Object
execRuleCall ax rule = do
  let typeErr o =
        typeError o "when calling a Rule object as though it were a function, all parameters" $
          show ListType++", where each list contains only objects of type "++show StringType
  ax <- forM ax $ \a -> evalObject (unComment a) >>= \a -> case a of
    OList ax -> forM ax $ \a -> case a of
      OString a -> return a
      _ -> typeErr a
    _ -> typeErr a
  flip local (execFuncPushStack T.Void (execScriptBlock (unComment (ruleAction rule)) >> ceReturn ONull)) $
    \xunit -> xunit{currentTask = (currentTask xunit){taskMatch = matchFromList [] (iLength ax) ax}}

-- | Very simply executes every given script item. Does not use catchCEReturn, does not use
-- 'nestedExecStack'. CAUTION: you cannot assign to local variables unless you call this method
-- within the 'nestedExecStack' or 'execFuncPushStack' functions. Failure to do so will cause a stack
-- underflow exception.
execScriptBlock :: [Com ScriptExpr] -> ExecScript ()
execScriptBlock block = mapM_ execScriptExpr block

-- | A guard script is some Dao script that is executed before or after some event, for example, the
-- code found in the @BEGIN@ and @END@ blocks.
execGuardBlock :: [Com ScriptExpr] -> ExecScript ()
execGuardBlock block = void (execFuncPushStack T.Void (execScriptBlock block >> return ONull))

-- $BasicCombinators
-- These are the most basic combinators for converting working with the 'ExecUnit' of an
-- 'ExecScript' monad.

----------------------------------------------------------------------------------------------------
-- $StackOperations
-- Operating on the local stack.

stack_underflow = error "INTERNAL ERROR: stack underflow"

-- | Push a new empty local-variable context onto the stack. Does NOT 'catchCEReturn', so it can be
-- used to push a new context for every level of nested if/else/for/try/catch statement, or to
-- evaluate a macro, but not a function call. Use 'execFuncPushStack' to perform a function call within
-- a function call.
nestedExecStack :: T_tree -> ExecScript a -> ExecScript a
nestedExecStack init exe = do
  stack <- fmap execStack ask
  execRun (dModifyMVar_ xloc stack (return . stackPush init))
  ce <- catchContErr exe
  execRun (dModifyMVar_ xloc stack (return . stackPop))
  returnContErr ce

-- | Keep the current 'execStack', but replace it with a new empty stack before executing the given
-- function. Use 'catchCEReturn' to prevent return calls from halting execution beyond this
-- function. This is what you should use to perform a Dao function call within a Dao function call.
execFuncPushStack :: T_tree -> ExecScript Object -> ExecScript Object
execFuncPushStack dict exe = do
  stackMVar <- execRun (dNewMVar xloc "execFuncPushStack/ExecUnit.execStack" (Stack [dict]))
  ce <- catchContErr (local (\xunit -> xunit{execStack = stackMVar}) exe)
  case ce of
    CEReturn obj -> return obj
    _            -> returnContErr ce

----------------------------------------------------------------------------------------------------

-- | Used to evaluate an expression like @$1@, retrieves the matched pattern associated with an
-- integer. Specifically, it returns a list of 'Dao.ObjectObject's where each object is an
-- 'Dao.Types.OString' contained at the integer index of the 'Dao.Pattern.matchGaps' of a
-- 'Dao.Pattern.Pattern'.
evalIntRef :: Word -> ExecScript Object
evalIntRef i = do
  task <- fmap currentTask ask
  let oi = OInt (fromIntegral i)
  case task of
    GuardTask _ _ -> do
      objectError oi ("not in pattern match context, cannot evaluate $"++show i)
    RuleTask pat ma act exec -> case matchGaps ma of
      Nothing -> do
        objectError oi ("currently matching pattern has no variables, cannot evaluate $"++show i)
      Just ma | i==0 -> return $ OArray $
        listArray (let (a, b) = bounds ma in (fromIntegral a, fromIntegral b)) $
          map (OList . map OString) (elems ma)
      Just ma | inRange (bounds ma) i -> return (OList (map OString (ma!i)))
      Just ma -> do
        objectError oi $ concat $
          [ "pattern match variable $"
          , show i ++ " is out of range "
          , show (bounds ma)
          , " in the current pattern match context"
          ]

-- | Lookup an object in the 'execHeap' for this 'ExecUnit'.
execHeapLookup :: [Name] -> ExecScript (Maybe Object)
execHeapLookup name = ask >>= \xunit -> inEvalDoReadResource (execHeap xunit) name

-- | Lookup an object in the 'execHeap' for this 'ExecUnit'.
execHeapUpdate :: [Name] -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
execHeapUpdate name runUpdate = ask >>= \xunit ->
  inEvalDoUpdateResource (execHeap xunit) name runUpdate

execHeapDefine :: [Name] -> Object -> ExecScript (Maybe Object)
execHeapDefine name obj = execHeapUpdate name (return . const (Just obj))

execHeapDelete :: [Name] -> Object -> ExecScript (Maybe Object)
execHeapDelete name obj = execHeapUpdate name (return . const Nothing)

-- | Lookup a reference value in the durrent document, if the current document has been set with a
-- "with" statement.
curDocVarLookup :: [Name] -> ExecScript (Maybe Object)
curDocVarLookup name = do
  xunit <- ask
  case currentDocument xunit of
    Nothing                  -> return Nothing
    Just file@(IdeaFile _ _) -> inEvalDoReadResource (fileData file) (currentBranch xunit ++ name)
    _ -> error ("current document is not an idea file, cannot lookup reference "++showRef name)

-- | Update a reference value in the durrent document, if the current document has been set with a
-- "with" statement.
curDocVarUpdate :: [Name] -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
curDocVarUpdate name runUpdate = do
  xunit <- ask
  case currentDocument xunit of
    Nothing                  -> return Nothing
    Just file@(IdeaFile _ _) ->
      inEvalDoUpdateResource (fileData file) (currentBranch xunit ++ name) runUpdate
    _ -> error ("current document is not an idea file, cannot update reference "++showRef name)

curDocVarDefine :: [Name] -> Object -> ExecScript (Maybe Object)
curDocVarDefine ref obj = curDocVarUpdate ref (return . const (Just obj))

curDocVarDelete :: [Name] -> Object -> ExecScript (Maybe Object)
curDocVarDelete ref obj = curDocVarUpdate ref (return . const Nothing)

-- | Lookup a value in the 'execStack'.
localVarLookup :: Name -> ExecScript (Maybe Object)
localVarLookup sym =
  fmap execStack ask >>= execRun . dReadMVar xloc >>= return . msum . map (T.lookup [sym]) . mapList

-- | Apply an altering function to the map at the top of the local variable stack.
localVarUpdate :: Name -> (Maybe Object -> Maybe Object) -> ExecScript (Maybe Object)
localVarUpdate name alt = ask >>= \xunit -> execRun $
  dModifyMVar xloc (execStack xunit) $ \ax -> case mapList ax of
    []   -> stack_underflow
    a:ax ->
      let obj = alt (T.lookup [name] a)
      in  return (Stack (T.update [name] (const obj) a : ax), obj)

-- | Force the local variable to be defined in the top level 'execStack' context, do not over-write
-- a variable that has already been defined in lower in the context stack.
localVarDefine :: Name -> Object -> ExecScript (Maybe Object)
localVarDefine name obj = localVarUpdate name (const (Just obj))

-- | To define a global variable, first the 'currentDocument' is checked. If it is set, the variable
-- is assigned to the document at the reference location prepending 'currentBranch' reference.
-- Otherwise, the variable is assigned to the 'execHeap'.
localVarModify :: [Name] -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
localVarModify name alt = do
  xunit <- ask
  let prefixName = currentBranch xunit ++ name
  case currentDocument xunit of
    Nothing                     -> inEvalDoUpdateResource (execHeap xunit) name alt
    Just file | isIdeaFile file -> error "TODO" -- execRun $ dModifyMVar_ xloc (fileData file) $ \doc -> return $
      -- doc{docRootObject = T.update prefixName alt (docRootObject doc), docModified = 1 + docModified doc}
    Just file                   -> ceError $ OList $ map OString $
      [ustr "current document is not a database", filePath file]

localVarDelete :: Name -> ExecScript (Maybe Object)
localVarDelete nm = localVarUpdate nm (const Nothing)

staticVarLookup :: Name -> ExecScript (Maybe Object)
staticVarLookup nm =
  fmap (staticVars . taskAction . currentTask) ask >>= lift . lift . readIORef >>= return . M.lookup nm

staticVarUpdate :: Name -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
staticVarUpdate nm upd = fmap (staticVars . taskAction . currentTask) ask >>= \ref ->
  lift (lift (readIORef ref)) >>= return . (M.lookup nm) >>= upd >>= \val ->
    lift (lift (modifyIORef ref (M.update (const val) nm))) >> return val

staticVarDefine :: Name -> Object -> ExecScript (Maybe Object)
staticVarDefine nm obj = localVarUpdate nm (const (Just obj))

staticVarDelete :: Name -> ExecScript (Maybe Object)
staticVarDelete nm = localVarUpdate nm (const Nothing)

-- | Lookup an object, first looking in the current document, then in the 'execHeap'.
globalVarLookup :: [Name] -> ExecScript (Maybe Object)
globalVarLookup ref = ask >>= \xunit ->
  (if isJust (currentDocument xunit) then curDocVarLookup else execHeapLookup) ref

globalVarUpdate :: [Name] -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
globalVarUpdate ref runUpdate = ask >>= \xunit ->
  (if isJust (currentDocument xunit) then curDocVarUpdate else execHeapUpdate) ref runUpdate

-- | To define a global variable, first the 'currentDocument' is checked. If it is set, the variable
-- is assigned to the document at the reference location prepending 'currentBranch' reference.
-- Otherwise, the variable is assigned to the 'execHeap'.
globalVarDefine :: [Name] -> Object -> ExecScript (Maybe Object)
globalVarDefine name obj = globalVarUpdate name (return . const (Just obj))

-- | To delete a global variable, the same process of searching for the address of the object is
-- followed for 'globalVarDefine', except of course the variable is deleted.
globalVarDelete :: [Name] -> ExecScript (Maybe Object)
globalVarDelete name = globalVarUpdate name (return . const Nothing)

qTimeVarLookup :: [Name] -> ExecScript (Maybe Object)
qTimeVarLookup ref = ask >>= \xunit -> inEvalDoReadResource (queryTimeHeap xunit) ref

qTimeVarUpdate :: [Name] -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
qTimeVarUpdate ref runUpdate = ask >>= \xunit ->
  inEvalDoUpdateResource (queryTimeHeap xunit) ref runUpdate

qTimeVarDefine :: [Name] -> Object -> ExecScript (Maybe Object)
qTimeVarDefine name obj = qTimeVarUpdate name (return . const (Just obj))

qTimeVarDelete :: [Name] -> ExecScript (Maybe Object)
qTimeVarDelete name = qTimeVarUpdate name (return . const Nothing)

clearAllQTimeVars :: ExecUnit -> Run ()
clearAllQTimeVars xunit = modifyUnlocked_ (queryTimeHeap xunit) (return . const T.Void)

----------------------------------------------------------------------------------------------------

-- $Built_in_functions
-- Built-in functions, retrieved from an array 'infixOps' or 'prefixOps' by a 'Dao.Object.ArithOp'
-- value, or from 'updateOps' by a 'Dao.Object.UpdateOp' value. Built-in functions check object
-- parameters passed to them with the 'BuiltinOp' monad, which is a fully lazy monad based on
-- 'Dao.Predicate.PValue'.

type BuiltinOp = PValue Location Object

evalBooleans :: (Bool -> Bool -> Bool) -> Object -> Object -> BuiltinOp
evalBooleans fn a b = return (if fn (objToBool a) (objToBool b) then OTrue else ONull)

eval_OR :: Object -> Object -> BuiltinOp
eval_OR = evalBooleans (||)

eval_AND :: Object -> Object -> BuiltinOp
eval_AND = evalBooleans (&&)

asReference :: Object -> PValue Location Reference
asReference o = case o of
  ORef o -> return o
  _      -> mzero

asInteger :: Object -> PValue Location Integer
asInteger o = case o of
  OWord o -> return (toInteger o)
  OInt  o -> return (toInteger o)
  OLong o -> return o
  _       -> mzero

asRational :: Object -> PValue Location Rational
asRational o = case o of
  OFloat     o     -> return (toRational o)
  ODiffTime  o     -> return (toRational o)
  OComplex  (o:+0) -> return (toRational o)
  ORatio     o     -> return o
  _                -> mzero

asStringNoConvert :: Object -> PValue Location UStr
asStringNoConvert o = case o of
  OString o -> return o
  _         -> mzero

asListNoConvert :: Object -> PValue Location [Object]
asListNoConvert o = case o of
  OList o -> return o
  _       -> mzero

asList :: Object -> PValue Location [Object]
asList o = case o of
  OList   o -> return o
  OArray  o -> return (elems o)
  OSet    o -> return (S.elems o)
  ODict   o -> return (map (\ (i, o) -> OPair (OString i, o)) (M.assocs o))
  OIntMap o -> return (map (\ (i, o) -> OPair (OInt (fromIntegral i), o)) (I.assocs o))
  OTree   o -> return (map (\ (i, o) -> OPair (OList (map OString i), o)) (T.assocs o))
  _         -> mzero

-- | Combines two lists of objects, then removes one "layer of lists", that is, if the combined
-- lists are of the form:
-- @list {a, b, ... , list {c, d, ... , list {e, f, ...}, ...} }@ 
-- the resulting list will be @list {a, b, ... , c, d, ... , list {e, f, ... }, ...}@
objListAppend :: [Object] -> [Object] -> Object
objListAppend ax bx = OList $ flip concatMap (ax++bx) $ \a -> case a of
  OList ax -> ax
  a        -> [a]

asHaskellInt :: Object -> PValue Location Int
asHaskellInt o = asInteger o >>= \o ->
  if (toInteger (minBound::Int)) <= o && o <= (toInteger (maxBound::Int))
    then return (fromIntegral o)
    else mzero

evalInt :: (Integer -> Integer -> Integer) -> Object -> Object -> BuiltinOp
evalInt ifunc a b = do
  ia <- asInteger a
  ib <- asInteger b
  let x = ia+ib
  return $ case (max (fromEnum (objType a)) (fromEnum (objType b))) of
    t | t == fromEnum WordType -> OWord (fromIntegral x)
    t | t == fromEnum IntType  -> OInt  (fromIntegral x)
    t | t == fromEnum LongType -> OLong (fromIntegral x)
    _ -> error "asInteger returned a value for an object of an unexpected type"

evalNum
  :: (Integer -> Integer -> Integer)
  -> (Rational -> Rational -> Rational)
  -> Object -> Object -> BuiltinOp
evalNum ifunc rfunc a b = msum
  [ evalInt ifunc a b
  , do  ia <- asRational a
        ib <- asRational b
        let x = ia+ib
        return $ case (max (fromEnum (objType a)) (fromEnum (objType b))) of
          t | t == fromEnum FloatType    -> OFloat    (fromRational x)
          t | t == fromEnum DiffTimeType -> ODiffTime (fromRational x)
          t | t == fromEnum RatioType    -> ORatio    (fromRational x)
          t | t == fromEnum ComplexType  -> OComplex  (fromRational x)
          _ -> error "asRational returned a value for an object of an unexpected type"
  ]

setToMapFrom :: (Object -> PValue Location i) -> ([(i, [Object])] -> m [Object]) -> S.Set Object -> m [Object]
setToMapFrom convert construct o = construct (zip (concatMap (okToList . convert) (S.elems o)) (repeat []))

evalSets
  ::  ([Object] -> Object)
  -> (([Object] -> [Object] -> [Object]) -> M.Map Name [Object] -> M.Map Name [Object] -> M.Map Name [Object])
  -> (([Object] -> [Object] -> [Object]) -> I.IntMap   [Object] -> I.IntMap   [Object] -> I.IntMap   [Object])
  -> (T_set -> T_set  -> T_set)
  -> Object -> Object -> BuiltinOp
evalSets combine dict intmap set a b = msum $
  [ do  a <- case a of
                ODict a -> return (fmap (:[]) a)
                _       -> mzero
        b <- case b of
                OSet  b -> return $ setToMapFrom asStringNoConvert M.fromList b
                ODict b -> return (fmap (:[]) b)
                _       -> mzero
        return (ODict (fmap combine (dict (++) a b)))
  , do  a <- case a of
                OIntMap a -> return (fmap (:[]) a)
                _         -> mzero
        b <- case b of
                OSet    b -> return $ setToMapFrom asHaskellInt I.fromList b
                OIntMap b -> return (fmap (:[]) b)
                _         -> mzero
        return (OIntMap (fmap combine (intmap (++) a b)))
  , do  let toSet s = case s of 
                        OSet s -> return s
                        _      -> mzero
        a <- toSet a
        b <- toSet b
        return (OSet (set a b))
  ]

eval_ADD :: Object -> Object -> BuiltinOp
eval_ADD a b = msum
  [ evalNum (+) (+) a b
  , timeAdd a b, timeAdd b a
  , do  a <- asStringNoConvert a
        b <- asStringNoConvert b
        return (OString (ustr (uchars a ++ uchars b)))
  , listAdd a b, listAdd b a
  ]
  where
    timeAdd a b = case (a, b) of
      (OTime a, ODiffTime b) -> return (OTime (addUTCTime b a))
      (OTime a, ORatio    b) -> return (OTime (addUTCTime (fromRational (toRational b)) a))
      (OTime a, OFloat    b) -> return (OTime (addUTCTime (fromRational (toRational b)) a))
      _                      -> mzero
    listAdd a b = do
      ax <- asListNoConvert a
      bx <- case b of
        OList  bx -> return bx
        OSet   b  -> return (S.elems b)
        OArray b  -> return (elems b)
        _         -> mzero
      return (objListAppend ax bx)

eval_SUB :: Object -> Object -> BuiltinOp
eval_SUB a b = msum $
  [ evalNum (-) (-) a b
  , evalSets (\a -> head a) (\ _ a b -> M.difference a b) (\ _ a b -> I.difference a b) S.difference a b
  , case (a, b) of
      (OTime a, OTime     b) -> return (ODiffTime (diffUTCTime a b))
      (OTime a, ODiffTime b) -> return (OTime (addUTCTime (negate b) a))
      (OTime a, ORatio    b) -> return (OTime (addUTCTime (fromRational (toRational (negate b))) a))
      (OTime a, OFloat    b) -> return (OTime (addUTCTime (fromRational (toRational (negate b))) a))
      _                  -> mzero
  , do  ax <- asListNoConvert a
        case b of
          OList bx -> return $
            let lenA = length ax
                lenB = length bx
                loop lenA zx ax = case ax of
                  ax'@(a:ax) | lenA>=lenB ->
                    if isPrefixOf bx ax' then  zx++a:ax else  loop (lenA-1) (zx++[a]) ax
                  _                       -> [a]
            in  if lenA <= lenB
                  then  if isInfixOf bx ax then OList [] else a
                  else  OList (loop lenA [] ax)
          OSet  b -> return (OList (filter (flip S.notMember b) ax))
          _       -> mzero
  ]

-- Distributed property of operators is defined. Pass a function to be mapped across containers.
evalDist :: (Object -> Object -> BuiltinOp) -> Object -> Object -> BuiltinOp
evalDist fn a b = multContainer a b where
  mapDist        = concatMap (okToList . fn a)
  mapDistSnd alt = concatMap $ okToList . \ (i, b) ->
    mplus (fn a b >>= \b -> return (i, b)) (if alt then return (i, ONull) else mzero)
  multContainer a b = case a of
    OList   bx -> return $ OList   (mapDist bx)
    OSet    b  -> return $ OSet    (S.fromList (mapDist (S.elems b)))
    OArray  b  -> return $ OArray  $ array (bounds b) $ mapDistSnd True $ assocs b
    ODict   b  -> return $ ODict   $ M.fromList $ mapDistSnd False $ M.assocs b
    OIntMap b  -> return $ OIntMap $ I.fromList $ mapDistSnd False $ I.assocs b
    _          -> mzero

evalDistNum
  :: (Integer  -> Integer  -> Integer )
  -> (Rational -> Rational -> Rational) 
  -> Object -> Object -> BuiltinOp
evalDistNum intFn rnlFn a b = msum $
  [ evalNum intFn rnlFn a b
  , if isNumeric a
      then  evalDist (evalDistNum intFn rnlFn) a b
      else  if isNumeric b then evalDist (flip (evalDistNum intFn rnlFn)) b a else mzero
  ]

eval_MULT :: Object -> Object -> BuiltinOp
eval_MULT a b = evalDistNum (*) (*) a b

eval_DIV :: Object -> Object -> BuiltinOp
eval_DIV a b = evalDistNum div (/) a b

eval_MOD :: Object -> Object -> BuiltinOp
eval_MOD a b = evalDistNum mod (\a b -> let r = a/b in (abs r - abs (floor r % 1)) * signum r) a b

evalBitsOrSets
  :: ([Object]  -> Object)
  -> (([Object] -> [Object] -> [Object]) -> M.Map Name [Object] -> M.Map Name [Object] -> M.Map Name [Object])
  -> (([Object] -> [Object] -> [Object]) -> I.IntMap   [Object] -> I.IntMap   [Object] -> I.IntMap   [Object])
  -> (T_set -> T_set  -> T_set)
  -> (Integer -> Integer -> Integer)
  -> Object -> Object -> BuiltinOp
evalBitsOrSets combine dict intmap set num a b =
  mplus (evalSets combine dict intmap set a b) (evalInt num a b)

eval_ORB :: Object -> Object -> BuiltinOp
eval_ORB  a b = evalBitsOrSets OList M.unionWith        I.unionWith        S.union        (.|.) a b

eval_ANDB :: Object -> Object -> BuiltinOp
eval_ANDB a b = evalBitsOrSets OList M.intersectionWith I.intersectionWith S.intersection (.&.) a b

eval_XORB :: Object -> Object -> BuiltinOp
eval_XORB a b = evalBitsOrSets (\a -> head a) mfn ifn sfn xor a b where
  sfn = fn S.union S.intersection S.difference head
  mfn = fn M.union M.intersection M.difference
  ifn = fn I.union I.intersection I.difference
  fn u n del _ a b = (a `u` b) `del` (a `n` b)

evalShift :: (Int -> Int) -> Object -> Object -> BuiltinOp
evalShift fn a b = asHaskellInt b >>= \b -> case a of
  OInt  a -> return (OInt  (shift a (fn b)))
  OWord a -> return (OWord (shift a (fn b)))
  OLong a -> return (OLong (shift a (fn b)))
  _       -> mzero

evalSubscript :: Object -> Object -> BuiltinOp
evalSubscript a b = case a of
  OArray  a -> fmap fromIntegral (asInteger b) >>= \b ->
    if inRange (bounds a) b then return (a!b) else pfail (ustr "array index out of bounds")
  OList   a -> asHaskellInt b >>= \b ->
    let err = pfail (ustr "list index out of bounds")
        ax  = drop b a
    in  if b<0 then err else if null ax then err else return (OList ax)
  OIntMap a -> asHaskellInt b >>= \b -> case I.lookup b a of
    Nothing -> pfail (ustr "no item at index requested of intmap")
    Just  b -> return b
  ODict   a -> msum $
    [ do  asStringNoConvert b >>= \b -> case M.lookup b a of
            Nothing -> pfail (ustr (show b++" is not defined in dict"))
            Just  b -> return b
    , do  asReference b >>= \b -> case b of
            LocalRef  b -> case M.lookup b a of
              Nothing -> pfail (ustr (show b++" is not defined in dict"))
              Just  b -> return b
            GlobalRef bx -> loop [] a bx where
              err = pfail (ustr (show b++" is not defined in dict"))
              loop zx a bx = case bx of
                []   -> return (ODict a)
                b:bx -> case M.lookup b a of
                  Nothing -> err
                  Just  a -> case a of
                    ODict a -> loop (zx++[b]) a bx
                    _       ->
                      if null bx
                        then return a
                        else pfail (ustr (show (GlobalRef zx)++" does not point to dict object"))
    ]
  OTree   a -> msum $ 
    [ asStringNoConvert b >>= \b -> done (T.lookup [b] a)
    , asReference b >>= \b -> case b of
        LocalRef  b  -> done (T.lookup [b] a)
        GlobalRef bx -> done (T.lookup bx  a)
    ] where
        done a = case a of
          Nothing -> pfail (ustr (show b++" is not defined in struct"))
          Just  a -> return a

eval_SHR :: Object -> Object -> BuiltinOp
eval_SHR = evalShift negate

eval_SHL :: Object -> Object -> BuiltinOp
eval_SHL = evalShift id

eval_DOT :: Object -> Object -> BuiltinOp
eval_DOT a b = asReference a >>= \a -> asReference b >>= \b -> case appendReferences a b of
  Nothing -> pfail (ustr (show b++" cannot be appended to "++show a))
  Just  a -> return (ORef a)

eval_NEG :: Object -> BuiltinOp
eval_NEG o = case o of
  OWord     o -> return $
    let n = negate (toInteger o)
    in  if n < toInteger (minBound::T_int)
           then  OLong n
           else  OInt (fromIntegral n)
  OInt      o -> return $ OInt      (negate o)
  OLong     o -> return $ OLong     (negate o)
  ODiffTime o -> return $ ODiffTime (negate o)
  OFloat    o -> return $ OFloat    (negate o)
  ORatio    o -> return $ ORatio    (negate o)
  OComplex  o -> return $ OComplex  (negate o)
  _           -> mzero

eval_INVB :: Object -> BuiltinOp
eval_INVB o = case o of
  OWord o -> return $ OWord (complement o)
  OInt  o -> return $ OInt  (complement o)
  OLong o -> return $ OLong (complement o)
  _       -> mzero

eval_REF :: Object -> BuiltinOp
eval_REF r = case r of
  ORef    r -> return (ORef (MetaRef r))
  OString s -> return (ORef (LocalRef s))
  _         -> mzero

eval_DEREF :: Object -> BuiltinOp
eval_DEREF r = case r of
  ORef (MetaRef r) -> return (ORef r)
  ORef r           -> return (ORef r)
  _                -> mzero

eval_NOT :: Object -> BuiltinOp
eval_NOT = return . boolToObj . testNull

-- | Traverse the entire object, returning a list of all 'Dao.Object.OString' elements.
extractStringElems :: Object -> [UStr]
extractStringElems o = case o of
  OString  o   -> [o]
  OList    o   -> concatMap extractStringElems o
  OSet     o   -> concatMap extractStringElems (S.elems o)
  OArray   o   -> concatMap extractStringElems (elems o)
  ODict    o   -> concatMap extractStringElems (M.elems o)
  OIntMap  o   -> concatMap extractStringElems (I.elems o)
  OTree    o   -> concatMap extractStringElems (T.elems o)
  OPair (a, b) -> concatMap extractStringElems [a, b]
  _            -> []

prefixOps :: Array ArithOp (Object -> BuiltinOp)
prefixOps = let o = (,) in array (REF, SUB) $
  [ o REF   eval_REF
  , o DEREF eval_DEREF
  , o INVB  eval_INVB
  , o NOT   eval_NOT
  , o NEG   eval_NEG
  ]

infixOps :: Array ArithOp (Object -> Object -> BuiltinOp)
infixOps = let o = (,) in array (POINT, MOD) $
  [ o POINT evalSubscript
  , o DOT   eval_DOT
  , o OR    (evalBooleans (||))
  , o AND   (evalBooleans (&&))
  , o ORB   eval_ORB
  , o ANDB  eval_ANDB
  , o XORB  eval_XORB
  , o SHL   eval_SHL
  , o SHR   eval_SHR
  , o ADD   eval_ADD
  , o SUB   eval_SUB
  , o MULT  eval_MULT
  , o DIV   eval_DIV
  , o MOD   eval_MOD
  ]

updatingOps :: Array UpdateOp (Object -> Object -> BuiltinOp)
updatingOps = let o = (,) in array (minBound, maxBound) $
  [ o UCONST (\_ b -> return b)
  , o UADD   eval_ADD
  , o USUB   eval_SUB
  , o UMULT  eval_MULT
  , o UDIV   eval_DIV
  , o UMOD   eval_MOD
  , o UORB   eval_ORB
  , o UANDB  eval_ANDB
  , o UXORB  eval_XORB
  , o USHL   eval_SHL
  , o USHR   eval_SHR
  ]

----------------------------------------------------------------------------------------------------

getAllStringArgs :: Bool -> [Object] -> ExecScript [UStr]
getAllStringArgs fail_if_not_string ox = catch (loop 0 [] ox) where
  loop i zx ox = case ox of
    []             -> return zx
    OString o : ox -> loop (i+1) (zx++[o]) ox
    _              ->
      if fail_if_not_string then PFail i (ustr "is not a string value") else loop (i+1) zx ox
  catch ox = case ox of
    PFail i msg -> ceError $ OList $ [OString (ustr "function parameter"), OWord i, OString msg]
    Backtrack   -> return []
    OK       ox -> return ox

builtin_print :: DaoFunc
builtin_print = DaoFunc $ \ox -> do
  ox <- getAllStringArgs False ox
  lift (lift (mapM_ (putStrLn . uchars) ox))
  return (OList (map OString ox))

builtin_do :: DaoFunc
builtin_do = DaoFunc $ \ox -> do
  xunit <- ask
  ox    <- getAllStringArgs True ox
  execScriptRun (dModifyMVar_ xloc (recursiveInput xunit) (return . (++ox)))
  return (OList (map OString ox))

-- | The map that contains the built-in functions that are used to initialize every
-- 'Dao.Types.ExecUnit'.
initBuiltinFuncs :: M.Map Name DaoFunc
initBuiltinFuncs = let o a b = (ustr a, b) in M.fromList $
  [ o "print" builtin_print
  , o "do"    builtin_do
  ]

----------------------------------------------------------------------------------------------------

-- | If an 'Dao.Object.Object' value is a 'Dao.Object.Reference' (constructed with
-- 'Dao.Object.ORef'), then the reference is looked up using 'readReference'. Otherwise, the object
-- value is returned. This is used to evaluate every reference in an 'Dao.Object.ObjectExpr'.
evalObjectRef :: Object -> ExecScript Object
evalObjectRef obj = case obj of
  ORef (MetaRef o) -> return (ORef o)
  ORef ref         -> readReference ref >>= \o -> case o of
    Nothing  -> ceError $ OList [obj, OString (ustr "undefined reference")]
    Just obj -> return obj
  obj              -> return obj

-- | Will return any value from the 'Dao.Types.ExecUnit' environment associated with a
-- 'Dao.Object.Reference'.
readReference :: Reference -> ExecScript (Maybe Object)
readReference ref = case ref of
  IntRef     i     -> fmap Just (evalIntRef i)
  LocalRef   nm    -> localVarLookup nm
  QTimeRef   ref   -> qTimeVarLookup ref
  StaticRef  ref   -> staticVarLookup ref
  GlobalRef  ref   -> globalVarLookup ref
  ProgramRef p ref -> error "TODO: haven't yet defined lookup behavior for Program references"
  FileRef    f ref -> error "TODO: haven't yet defined lookup behavior for file references"
  MetaRef    _     -> error "cannot dereference a reference-to-a-reference"

-- | All assignment operations are executed with this function. To modify any variable at all, you
-- need a reference value and a function used to update the value. This function will select the
-- correct value to modify based on the reference type and value, and modify it according to this
-- function. TODO: the use of "dModifyMVar" to update variables is just a temporary fix, and will
-- almost certainly cause a deadlock. But I need this to compile before I begin adding on the
-- deadlock-free code.
updateReference :: Reference -> (Maybe Object -> ExecScript (Maybe Object)) -> ExecScript (Maybe Object)
updateReference ref modf = do
  xunit <- ask
  let updateRef :: DMVar a -> (a -> Run (a, ContErr Object)) -> ExecScript (Maybe Object)
      updateRef dmvar runUpdate = fmap Just (execScriptRun (dModifyMVar xloc dmvar runUpdate) >>= returnContErr)
      execUpdate :: ref -> a -> Maybe Object -> ((Maybe Object -> Maybe Object) -> a) -> Run (a, ContErr Object)
      execUpdate ref store lkup upd = do
        err <- flip runExecScript xunit $ modf lkup
        case err of
          CENext   val -> return (upd (const val), CENext (fromMaybe ONull val))
          CEReturn val -> return (upd (const (Just val)), CEReturn val)
          CEError  err -> return (store, CEError err)
  case ref of
    IntRef     i          -> error "cannot assign values to a pattern-matched reference"
    LocalRef   ref        -> localVarLookup ref >>= \obj -> localVarUpdate ref (const obj)
    GlobalRef  ref        -> globalVarUpdate ref modf
    QTimeRef   ref        -> qTimeVarUpdate ref modf
    StaticRef  ref        -> staticVarUpdate ref modf
    ProgramRef progID ref -> error "TODO: you haven't yet defined update behavior for Program references"
    FileRef    path   ref -> error "TODO: you haven't yet defined update behavior for File references"
    MetaRef    _          -> error "cannot assign values to a meta-reference"

-- | Retrieve a 'Dao.Types.CheckFunc' function from one of many possible places in the
-- 'Dao.Types.ExecUnit'. Every function call that occurs during execution of the Dao script will
-- use this Haskell function to seek the correct Dao function to use. Pass an error message to be
-- reported if the lookup fails. The order of lookup is: this module's 'Dao.Types.Subroutine's,
-- the 'Dao.Types.Subroutine's of each imported module (from first to last listed import), and
-- finally the built-in functions provided by the 'Dao.Types.Runtime'
lookupFunction :: String -> Name -> ExecScript Subroutine
lookupFunction msg op = do
  xunit <- ask
  let toplevs xunit = execRun (fmap (M.lookup op) (dReadMVar xloc (toplevelFuncs xunit)))
      lkup xunitMVar = execRun (dReadMVar xloc xunitMVar) >>= toplevs
  funcs <- sequence (toplevs xunit : map lkup (importsTable xunit))
  case msum funcs of -- TODO: builtinFuncs should not be used anymore
    Nothing   -> objectError (OString op) $ "undefined "++msg++" ("++uchars op++")"
    Just func -> return func

----------------------------------------------------------------------------------------------------

-- $ErrorReporting
-- The 'ContErrT' is a continuation monad that can evaluate to an error message without evaluating
-- to "bottom". The error message is any value of type 'Dao.Types.Object'. These functions provide
-- a simplified method for constructing error 'Dao.Types.Object's.

simpleError :: String -> ExecScript a
simpleError msg = ceError (OString (ustr msg))

-- | Like 'Dao.Object.Data.objectError', but simply constructs a 'Dao.Object.Monad.CEError' value
-- that can be returned in an inner monad that has been lifted into a 'Dao.Object.Monad.ContErrT'
-- monad.
objectErrorCE :: Object -> String -> ContErr a
objectErrorCE obj msg = CEError (OPair (OString (ustr msg), obj))

typeError :: Object -> String -> String -> ExecScript a
typeError o cons expect = objectError (OType (objType o)) (cons++" must be of type "++expect)

derefError :: Reference -> ExecScript a
derefError ref = objectError (ORef ref) "undefined reference"

-- | Evaluate to 'ceError' if the given 'PValue' is 'Backtrack' or 'PFail'. You must pass a
-- 'Prelude.String' as the message to be used when the given 'PValue' is 'Backtrack'. You can also
-- pass a list of 'Dao.Object.Object's that you are checking, these objects will be included in the
-- 'ceError' value.
--     This function should be used for cases when you have converted 'Dao.Object.Object' to a
-- Haskell value, because 'Backtrack' values indicate type exceptions, and 'PFail' values indicate a
-- value error (e.g. out of bounds, or some kind of assert exception), and the messages passed to
-- 'ceError' will indicate this.
checkPValue :: String -> [Object] -> PValue Location a -> ExecScript a
checkPValue altmsg tried pval = case pval of
  OK a         -> return a
  Backtrack    -> ceError $ OList $
    OString (ustr "bad data type") : (if null altmsg then [] else [OString (ustr altmsg)]) ++ tried
  PFail lc msg -> ceError $ OList $
    OString (ustr "bad data value") :
      (if null altmsg then [] else [OString (ustr altmsg)]) ++ OString msg : tried

----------------------------------------------------------------------------------------------------

-- | Convert a single 'ScriptExpr' into a function of value @'ExecScript' 'Dao.Types.Object'@.
execScriptExpr :: Com ScriptExpr -> ExecScript ()
execScriptExpr script = case unComment script of
  EvalObject  o  _             lc  -> unless (isNO_OP o) (void (evalObject o))
  IfThenElse  _  ifn  thn  els lc  -> nestedExecStack T.Void $ do
    ifn <- evalObject ifn
    case ifn of
      ORef o -> do
        true <- fmap isJust (readReference o)
        execScriptBlock (unComment (if true then thn else els))
      o      -> execScriptBlock (unComment (if objToBool o then thn else els))
  TryCatch    try  name catch  lc  -> do
    ce <- withContErrSt (nestedExecStack T.Void (execScriptBlock (unComment try))) return
    void $ case ce of
      CEError o -> nestedExecStack (T.Leaf (unComment name) o) (execScriptBlock catch)
      ce        -> returnContErr ce
  ForLoop    varName inObj thn lc  -> nestedExecStack T.Void $ do
    inObj   <- evalObject (unComment inObj)
    let block thn = if null thn then return True else scrpExpr (head thn) >> block (tail thn)
        ctrlfn ifn thn = do
          ifn <- evalObject ifn
          case ifn of
            ONull -> return (not thn)
            _     -> return thn
        scrpExpr expr = case unComment expr of
          ContinueExpr a _  ifn lc -> ctrlfn (unComment ifn) a
          _                        -> execScriptExpr expr >> return True
        loop thn name ix = case ix of
          []   -> return ()
          i:ix -> localVarDefine name i >> block thn >>= flip when (loop thn name ix)
        inObjType = OType (objType inObj)
    case asList inObj of
      OK        ox  -> loop thn (unComment varName) ox
      Backtrack     -> objectError inObj "cannot be represented as list"
      PFail loc msg -> objectError inObj (uchars msg) -- TODO: also report the location of the failure.
  ContinueExpr a    _    _     lc  -> simpleError $
    '"':(if a then "continue" else "break")++"\" expression is not within a \"for\" loop"
  ReturnExpr   a    obj        lc  -> evalObject (unComment obj) >>= \obj -> (if a then ceReturn else ceError) obj
  WithDoc      lval thn        lc  -> nestedExecStack T.Void $ do
    lval <- evalObject (unComment lval)
    let setBranch ref xunit = return (xunit{currentBranch = ref})
        setFile path xunit = do
          file <- execRun (fmap (M.lookup path) (dReadMVar xloc (execOpenFiles xunit)))
          case file of
            Nothing  -> ceError $ OList $ map OString $
              [ustr "with file path", path, ustr "file has not been loaded"]
            Just file -> return (xunit{currentDocument = Just file})
        run upd = ask >>= upd >>= \r -> local (const r) (execScriptBlock thn)
    case lval of -- TODO: change the type definition and parser for WithDoc such that it takes ONLY a Reference, not an Literal.
      ORef (GlobalRef ref)              -> run (setBranch ref)
      ORef (FileRef path [])            -> run (setFile path)
      ORef (FileRef path ref)           -> run (setFile path >=> setBranch ref)
      _ -> typeError lval "operand to \"with\" statement" $
             "file path (String type), or a Ref type, or a Pair of the two"

showObjType :: Object -> String
showObjType obj = showObj 0 (OType (objType obj))

-- | 'Dao.Types.ObjectExpr's can be evaluated anywhere in a 'Dao.Object.Script'. However, a
-- 'Dao.Types.ObjectExpr' is evaluated as a lone command expression, and not assigned to any
-- variables, and do not have any other side-effects, then evaluating an object is a no-op. This
-- function checks the kind of 'Dao.Types.ObjectExpr' and evaluates to 'True' if it is impossible
-- for an expression of this kind to produce any side effects. Otherwise, this function evaluates to
-- 'False', which indicates it is OK to evaluate the expression and disgard the resultant 'Object'.
isNO_OP :: ObjectExpr -> Bool
isNO_OP o = case o of
  Literal      _     _ -> True
  ParenExpr    _ o   _ -> isNO_OP (unComment o)
  ArraySubExpr _ _ _ _ -> True
  DictExpr     _ _ _ _ -> True
  ArrayExpr    _ _   _ -> True
  LambdaExpr   _ _   _ -> True
  _                    -> False

called_nonfunction_object :: String -> Object -> ExecScript e
called_nonfunction_object op obj =
  typeError obj (show op++" was called as a function but is not a function type, ") $
    show ScriptType++" or "++show RuleType

-- | Cache a single value so that multiple lookups of the given reference will always return the
-- same value, even if that value is modified by another thread between separate lookups of the same
-- reference value during evaluation of an 'Dao.Object.ObjectExpr'.
cacheReference :: Reference -> Maybe Object -> ExecScript ()
cacheReference r obj = case obj of
  Nothing  -> return ()
  Just obj -> ask >>= \xunit -> execRun $ dModifyMVar_ xloc (referenceCache xunit) $ \cache ->
    return (M.insert r obj cache)

-- | Evaluate an 'ObjectExpr' to an 'Dao.Types.Object' value, and does not de-reference objects of
-- type 'Dao.Types.ORef'
evalObject :: ObjectExpr -> ExecScript Object
evalObject obj = case obj of
  VoidExpr                      -> return ONull
  Literal       o            lc -> return o
  AssignExpr    nm  op_ expr lc -> do
    let op = unComment op_
    nm   <- evalObject nm
    nm   <- checkPValue ("left-hand side of "++show op) [nm] (asReference nm)
    expr <- evalObject expr >>= evalObjectRef
    fmap (fromMaybe ONull) $ updateReference nm $ \maybeObj -> case maybeObj of
      Nothing  -> ceError $ OList $ [OString $ ustr "undefined refence", ORef nm]
      Just obj -> fmap Just $ checkPValue "assignment expression" [obj, expr] $ (updatingOps!op) obj expr
  FuncCall   op  _  args     lc -> do -- a built-in function call
    bif  <- fmap builtinFuncs ask
    case M.lookup op bif of
      Nothing -> do
        -- Find the name of the function in the built-in table and execute that one if it exists.
        -- NOTE: Built-in function calls do not get their own new stack, 'execFuncPushStack' is not
        -- used, only 'catchCEREturn'.
        fn <- lookupFunction "function call" op
        args <- mapM ((evalObject >=> evalObjectRef) . unComment) args
        let argTypes = OList (map (OType . objType) args)
        runSubroutine args fn
      Just fn -> daoForeignCall fn args
  LambdaCall ref  args       lc -> do
    fn <- evalObject (unComment ref) >>= evalObjectRef
    case fn of
      OScript fn -> execScriptCall args fn
      ORule   fn -> execRuleCall   args fn
      _          -> called_nonfunction_object (showObjectExpr 0 ref) fn
  ParenExpr     _     o      lc -> evalObject (unComment o)
  ArraySubExpr  o  _  i      lc -> do
    o <- evalObject o
    i <- evalObject (unComment i)
    case evalSubscript o i of
      OK          a -> return a
      PFail loc msg -> ceError (OString msg)
      Backtrack     -> ceError (OList [i, OString (ustr "cannot be used as index of"), o])
  Equation   left  op_ right lc -> do
    let op = unComment op_
    left  <- evalObject left
    right <- evalObject right
    (left, right) <- case op of
      DOT   -> return (left, right)
      POINT -> liftM2 (,) (evalObjectRef left) (return right)
      _     -> liftM2 (,) (evalObjectRef left) (evalObjectRef right)
    case (infixOps!op) left right of
      OK result    -> return result
      Backtrack    -> ceError $ OList $
        [OString $ ustr (show op), OString $ ustr "cannot operate on objects of type", left, right]
      PFail lc msg -> ceError $ OList [OString msg]
  DictExpr   cons  _  args   lc -> do
    let loop insfn getObjVal map argx = case argx of
          []       -> return map
          arg:argx -> case unComment arg of
            AssignExpr ixObj op_ new lc -> do
              let op = unComment op_
              ixObj <- evalObject ixObj >>= evalObjectRef
              ixVal <- checkPValue (show cons++" assignment expression") [ixObj] (getObjVal ixObj)
              new   <- evalObject new >>= evalObjectRef
              map   <- insfn map ixObj ixVal op new
              loop insfn getObjVal map argx
            _ -> error "dictionary constructor contains an expression that is not an assignment"
        assign lookup insert map ixObj ixVal op new = case lookup ixVal map of
          Nothing  -> case op of
            UCONST -> return (insert ixVal new map)
            op     -> ceError $ OList [OString (ustr ("undefined left-hand side of "++show op)), ixObj]
          Just old -> case op of
            UCONST -> ceError $ OList [OString (ustr ("twice defined left-hand side "++show op)), ixObj]
            op     -> do
              new <- checkPValue (show cons++" assignment expression "++show op) [ixObj, old, new] $ (updatingOps!op) old new
              return (insert ixVal new map)
        intmap = assign I.lookup I.insert
        dict   = assign M.lookup M.insert
    case () of
      () | cons == ustr "list"   -> fmap OList (mapM (evalObject . unComment) args)
      () | cons == ustr "dict"   -> fmap ODict   (loop dict   asStringNoConvert M.empty args)
      () | cons == ustr "intmap" -> fmap OIntMap (loop intmap asHaskellInt      I.empty args)
      _ -> error ("INTERNAL ERROR: unknown dictionary declaration "++show cons)
  ArrayExpr  rang  ox        lc -> do
    case unComment rang of
      (_ : _ : _ : _) ->
        simpleError "internal error: array range expression has more than 2 arguments"
      [lo, hi] -> do
        lo <- evalObject (unComment lo)
        hi <- evalObject (unComment hi)
        case (lo, hi) of
          (OInt lo, OInt hi) -> do
            (lo, hi) <- return (if lo<hi then (lo,hi) else (hi,lo))
            ox <- mapM (evalObject . unComment) ox
            return (OArray (listArray (lo, hi) ox))
          _ -> objectError (OPair (OType (objType lo), OType (objType hi))) $
                   "range specified to an "++show ArrayType
                 ++" constructor must evaluate to two "++show IntType++"s"
      _ -> simpleError "internal error: array range expression has fewer than 2 arguments"
  LambdaExpr argv  code      lc -> return (OScript (FuncExpr{scriptArgv = argv, scriptCode = Com code}))

-- | Simply checks if an 'Prelude.Integer' is within the maximum bounds allowed by 'Data.Int.Int'
-- for 'Data.IntMap.IntMap'.
checkIntMapBounds :: Integral i => Object -> i -> ExecScript ()
checkIntMapBounds o i = do
  let (lo, hi) = (minBound::Int, maxBound::Int)
  unless (fromIntegral lo < i && i < fromIntegral hi) $
    objectError o $ show IntMapType++" index is beyond the limits allowd by this data type"

----------------------------------------------------------------------------------------------------

-- | Checks if this ExecUnit is allowed to use a set of built-in rules requested by an "require"
-- attribute. Returns any value you pass as the second parameter, throws a
-- 'Dao.Object.Monad.ceError' if it access is prohibited.
verifyRequirement :: Name -> a -> ExecScript a
verifyRequirement nm a = return a -- TODO: the rest of this function.

-- | Checks if this ExecUnit is allowed to import the file requested by an "import" statement
-- attribute. Returns any value you pass as the second parameter, throws a
-- 'Dao.Object.Monad.ceError'
verifyImport :: Name -> a -> ExecScript a
verifyImport nm a = return a -- TODO: the rest of this function.

-- | When the 'programFromSource' is scanning through a 'Dao.Types.SourceCode' object, it first
-- constructs an 'IntermediateProgram', which contains no 'Dao.Debug.DMVar's. Once all the data
-- structures are in place, a 'Dao.Types.CachedProgram' is constructed from this intermediate
-- representation.
data IntermediateProgram
  = IntermediateProgram
    { inmpg_programModuleName :: Name
    , inmpg_programImports    :: [UStr]
    , inmpg_constructScript   :: [Com [Com ScriptExpr]]
    , inmpg_destructScript    :: [Com [Com ScriptExpr]]
    , inmpg_requiredBuiltins  :: [Name]
    , inmpg_programAttributes :: M.Map Name Name
    , inmpg_preExecScript     :: [Com [Com ScriptExpr]]
    , inmpg_postExecScript    :: [Com [Com ScriptExpr]]
    , inmpg_programTokenizer  :: Tokenizer
    , inmpg_programComparator :: CompareToken
    , inmpg_ruleSet           :: PatternTree [Com [Com ScriptExpr]]
    , inmpg_globalData        :: T.Tree Name Object
    }

initIntermediateProgram =
  IntermediateProgram
  { inmpg_programModuleName = nil
  , inmpg_programImports    = []
  , inmpg_constructScript   = []
  , inmpg_destructScript    = []
  , inmpg_requiredBuiltins  = []
  , inmpg_programAttributes = M.empty
  , inmpg_preExecScript     = []
  , inmpg_postExecScript    = []
  , inmpg_programTokenizer  = return . tokens . uchars
  , inmpg_programComparator = (==)
  , inmpg_ruleSet           = T.Void
  , inmpg_globalData        = T.Void
  }

initProgram :: IntermediateProgram -> TreeResource -> ExecScript Program
initProgram inmpg initGlobalData = do
  rules <- execScriptRun $
    T.mapLeavesM (mapM setupExecutable) (inmpg_ruleSet inmpg) >>= dNewMVar xloc "Program.ruleSet"
  pre   <- execRun (mapM setupExecutable (inmpg_preExecScript  inmpg))
  post  <- execRun (mapM setupExecutable (inmpg_postExecScript inmpg))
  inEvalDoModifyUnlocked_ initGlobalData (return . const (inmpg_globalData inmpg))
  return $
    Program
    { programModuleName = inmpg_programModuleName inmpg
    , programImports    = inmpg_programImports    inmpg
    , constructScript   = map unComment (inmpg_constructScript inmpg)
    , destructScript    = map unComment (inmpg_destructScript  inmpg)
    , requiredBuiltins  = inmpg_requiredBuiltins  inmpg
    , programAttributes = M.empty
    , preExecScript     = pre
    , programTokenizer  = return . tokens . uchars
    , programComparator = (==)
    , postExecScript    = post
    , ruleSet           = rules
    , globalData        = initGlobalData
    }

-- | To parse a program, use 'Dao.Object.Parsers.source' and pass the resulting
-- 'Dao.Object.SourceCode' object to this funtion. It is in the 'ExecScript' monad because it needs
-- to evaluate 'Dao.ObjectObject's defined in the top-level of the source code, which requires
-- 'evalObject'.
-- Attributes in Dao scripts are of the form:
--   a.b.C.like.name  dot.separated.value;
-- The three built-in attributes are "requires", "string.tokenizer" and "string.compare". The
-- allowed attrubites can be extended by passing a call-back predicate which modifies the given
-- program, or returns Nothing to reject the program. If you are not sure what to pass, just pass
-- @(\ _ _ _ -> return Nothing)@ which always rejects the program. This predicate will only be
-- called if the attribute is not allowed by the minimal Dao system.
programFromSource
  :: TreeResource
      -- ^ the global variables initialized at the top level of the program file are stored here.
  -> (Name -> UStr -> IntermediateProgram -> ExecScript Bool)
      -- ^ a callback to check attributes written into the script. If the attribute is bogus, Return
      -- False to throw a generic error, or throw your own CEError. Otherwise, return True.
  -> SourceCode
      -- ^ the script file to use
  -> ExecScript Program
programFromSource globalResource checkAttribute script = do
  interm <- execStateT (mapM_ foldDirectives (unComment (directives script))) initIntermediateProgram
  initProgram interm globalResource
  where
    err lst = lift $ ceError $ OList $ map OString $ (sourceFullPath script : lst)
    attrib req nm getRuntime putProg = do
      runtime <- lift $ fmap parentRuntime ask
      let item = M.lookup nm (getRuntime runtime)
      case item of
        Just item -> modify (putProg item)
        Nothing   -> err [req, ustr "attribute", nm, ustr "is not available"]
    foldDirectives directive = case unComment directive of
      Attribute  req nm lc -> ask >>= \xunit -> do
        let setName = unComment nm
            runtime = parentRuntime xunit
            builtins = M.lookup setName $ functionSets runtime
        case unComment req of
          req | req==ustr "import"           -> do
            lift $ verifyImport setName () -- TODO: verifyImport will evaluate to a CEError if the import fails.
            modify (\p -> p{inmpg_programImports = inmpg_programImports p ++ [setName]})
          req | req==ustr "require"          -> case builtins of
            Just  _ -> do
              lift $ verifyRequirement setName ()
              modify (\p -> p{inmpg_requiredBuiltins = inmpg_requiredBuiltins p++[setName]})
            Nothing -> err $
              [ustr "requires", setName, ustr "not provided by this version of the Dao system"]
          req | req==ustr "string.tokenizer" ->
            attrib req setName availableTokenizers (\item p -> p{inmpg_programTokenizer = item})
          req | req==ustr "string.compare"   ->
            attrib req setName availableComparators (\item p -> p{inmpg_programComparator = item})
          req -> do
            p  <- get
            ok <- lift (checkAttribute req setName p)
            if ok
              then return ()
              else err [ustr "script contains unknown attribute declaration", req]
      ToplevelDefine name obj lc -> do
        obj <- lift $ evalObject (unComment obj)
        modify (\p -> p{inmpg_globalData = T.insert (unComment name) obj (inmpg_globalData p)})
      TopRuleExpr rule' lc -> modify (\p -> p{inmpg_ruleSet = foldl fol (inmpg_ruleSet p) rulePat}) where
        rule    = unComment rule'
        rulePat = map unComment (unComment (rulePattern rule))
        fol tre pat = T.merge T.union (++) tre (toTree pat [ruleAction rule])
      SetupExpr    scrp lc -> modify (\p -> p{inmpg_constructScript = inmpg_constructScript p ++ [scrp]})
      TakedownExpr scrp lc -> modify (\p -> p{inmpg_destructScript  = inmpg_destructScript  p ++ [scrp]})
      BeginExpr    scrp lc -> modify (\p -> p{inmpg_preExecScript   = inmpg_preExecScript   p ++ [scrp]})
      EndExpr      scrp lc -> modify (\p -> p{inmpg_postExecScript  = inmpg_postExecScript  p ++ [scrp]})
      ToplevelFunc _ nm argv code lc -> lift $ do
        xunit <- ask
        let func objx = execScriptCall (map (Com . flip Literal lc) objx) $
              FuncExpr{scriptArgv = argv, scriptCode = code}
        execScriptRun $ do
          let name = unComment nm
          func <- dNewMVar xloc ("Program.topLevelFunc("++uchars name++")") func :: Run Subroutine
          dModifyMVar_ xloc (toplevelFuncs xunit) (return . M.insert name func)

