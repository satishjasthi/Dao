-- "src/Dao/Object/Random.hs"  instantiates Objects into the RandO class.
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

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}

module Dao.Object.Random where

import           Dao.Token
import           Dao.Glob
import           Dao.Object
import           Dao.Random
import           Dao.Object.AST
import qualified Dao.Tree              as T

import           Control.Applicative
import           Control.Monad
import           Control.Monad.State

import           Data.Monoid
import           Data.List
import           Data.Char
import           Data.Bits
import           Data.Word
import           Data.Ratio
import           Data.Complex
import           Data.Time
import           Data.Array.IArray
import qualified Data.Binary           as Db
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy  as Bz
import qualified Data.Set              as S
import qualified Data.Map              as M
import qualified Data.IntMap           as I

import           System.Random

-- import           Debug.Trace

----------------------------------------------------------------------------------------------------

randObjMap :: (map Object -> Object) -> ([(key, Object)] -> map Object) -> RandO key -> RandO Object
randObjMap objConstruct mapConstruct keygen = (randList 0 7) >>= \ox ->
  fmap (objConstruct . mapConstruct) (forM ox (\obj -> keygen >>= \key -> return (key, obj)))

randComWith :: RandO a -> RandO (Com a)
randComWith rand = fmap Com rand
--  randComWith :: RandO a -> RandO (Com a)
--  randComWith rand = do
--    typ <- fmap (flip mod 24 . unsign) randInt
--    a <- rand
--    case typ of
--      0 -> do
--        before <- randO
--        after  <- randO
--        return (ComAround before a after)
--      1 -> do
--        before <- randO
--        return (ComBefore before a)
--      2 -> do
--        after <- randO
--        return (ComAfter a after)
--      _ -> return (Com a)

instance HasRandGen a => HasRandGen (Com a) where { randO = randComWith randO }

instance HasRandGen [Comment] where { randO = return [] }
--  randO = do
--    i0 <- randInt
--    let (i1, many) = divMod i0 4
--        (i2, typn) = divMod i1 16
--        typx = take many (randToBase 2 typn ++ replicate 4 0)
--        lenx = map (+1) (randToBase 29 i2)
--        com typ = if typ==0 then EndlineComment else InlineComment
--    forM (zip typx lenx) $ \ (typ, len) ->
--      fmap (com typ . ustr . unwords . map (B.unpack . getRandomWord)) (replicateM len randInt)

----------------------------------------------------------------------------------------------------

randSingleton :: RandO Object
randSingleton = randOFromList randSingletonList

randSingletonList :: [RandO Object]
randSingletonList =
  [ return ONull
  , return OTrue
--  , fmap OType randO
  , randInteger (OInt  0) $ \i -> randInt >>= \j -> return (OInt$fromIntegral$ i*j)
  , randInteger (OWord 0) $ \i -> randInt >>= \j -> return (OWord$fromIntegral$abs$ i*j)
  , randInteger (OLong 0) $ \i -> replicateM (mod i 4 + 1) randInt >>= return . OLong . longFromInts
  , randInteger (ORatio 0) $ \i -> return (ORatio (toInteger i % 1))
  , randInteger (OComplex (0:+0)) $ \i -> return (OComplex (0 :+ (fromRational (toInteger i % 1))))
  , randInteger (OFloat 0) (fmap (OFloat . fromRational) . randRational)
  , randInteger (OChar '\n') (\i -> return (OChar $ chr $ mod i $ ord (maxBound::Char)))
  , fmap OString randO
  , fmap ORef    randO
  ]

instance HasRandGen Object where
  randO = randOFromList $ randSingletonList ++
--  [ randInteger (ORatio 0) (fmap ORatio . randRational)
--  , randInteger (OComplex 0) $ \i0 -> do
--      let (i1, rem) = divMod i0 4
--      real <- fmap fromRational (randRational i1)
--      cplx <- fmap fromRational (randRational rem)
--      return (OComplex (real:+cplx))
    [ fmap ORef randO
--  , fmap OPair (liftM2 (,) randO randO)
    , fmap OList (randList 0 40)
--  , fmap (OSet . S.fromList) (randList 0 40)
    , fmap OAbsTime randO
    , fmap ORelTime randO
--  , do -- OArray
--        hi <- nextInt 12
--        lo <- nextInt 8
--        fmap (OArray . listArray (fromIntegral lo, fromIntegral (lo+hi))) $
--          replicateM (hi+1) (limSubRandO ONull)
--  , randObjMap ODict   M.fromList (randO)
--  , randObjMap OIntMap I.fromList randInt
    , fmap OTree randO
--  , fmap OGlob randO
--  , fmap OScript randO
      -- OBytes
    , do  i <- nextInt 10
          fmap (OBytes . Bz.concat) $
            replicateM i (fmap (Db.encode . (\i -> fromIntegral i :: Word32)) randInt)
    ]

instance HasRandGen CoreType where
  randO = fmap toEnum (nextInt (fromEnum (maxBound::CoreType)))

randMultiName :: RandO [UStr]
randMultiName = do
  i0 <- randInt
  let (i1, len) = divMod i0 4
  fmap ((randUStr i1 :) . map randUStr) (replicateM len randInt)

instance HasRandGen Reference where { randO = fmap Reference (randList 1 6) }
instance HasRandGen QualRef where
  randO = do
    let maxbnd = fromEnum(maxBound::RefQualifier)
    i   <- nextInt (2*(maxbnd-fromEnum(minBound::RefQualifier)+1))
    let (d, m) = divMod i 2
    if m==0
      then  liftM Unqualified randO
      else  if d==maxbnd then liftM ObjRef randSingleton else liftM (Qualified (toEnum d)) randO

instance HasRandGen ObjectExpr where
  randO = randO >>= \o -> case toInterm o of
    [o] -> return o
    _   -> error "randO generated AST_Object that failed to be converted to an ObjectExpr"

instance HasRandGen ParamExpr where { randO = pure ParamExpr <*> randO <*> randO <*> no }
instance HasRandGen [ParamExpr] where { randO = randList 0 10 }
instance HasRandGen ParamListExpr where { randO = pure ParamListExpr <*> randO <*> no }

instance HasRandGen Glob where
  randO = do
    len <- fmap (+6) (nextInt 6)
    i <- randInt
    let loop len i =
          if len<=1 then [] else let (i', n) = divMod i len 
          in  (n+1) : loop (len-n-1) i'
        cuts = loop len i
    tx <- fmap (([]:) . map (\t -> if t==0 then [AnyOne] else [Wildcard]) . randToBase 2) randInt
    let loop tx cuts ax = case cuts of
          []       -> [ax]
          cut:cuts ->
            let (wx, ax') = splitAt cut ax
                (t,  tx') = splitAt 1 tx
            in  t ++ wx : loop tx' cuts ax'
    patUnits <- fmap (concat . loop tx cuts . intersperse (Single (ustr " "))) $
      replicateM len (fmap (Single . randUStr) randInt)
    return (Glob{getPatUnits=patUnits, getGlobLength=length patUnits})

instance HasRandGen (T.Tree Name Object) where
  randO = do
    branchCount <- nextInt 4
    cuts <- fmap (map (+1) . randToBase 6) randInt
    fmap (T.fromList . concat) $ replicateM (branchCount+1) $ do
      wx <- replicateM 6 randO
      forM cuts $ \cut -> do
        obj <- limSubRandO ONull
        return (take cut wx, obj)

instance HasRandGen CallableCode where
  randO = do
    pats <- randO
    scrp <- fmap toInterm randO
    scrp <- case scrp of
      []  -> return mempty
      o:_ -> return o
    let msg = "Subroutine generated by \"randO\" is not intended to be executed."
    return $
      CallableCode
      { argsPattern    = pats
      , returnType     = anyType
      , codeSubroutine =
          Subroutine
          { origSourceCode = scrp
          , staticVars     = error msg
          , executable     = error msg
          }
      }

----------------------------------------------------------------------------------------------------

no :: RandO Location
no = return LocationUnknown

lit :: Object -> AST_Object
lit = flip AST_Literal LocationUnknown

instance HasRandGen AST_Ref where
  randO = do
    r <- randList 1 6
    case r of
      []   -> return AST_RefNull
      r:rx -> mapM (randComWith . return) rx >>= \rx -> return (AST_Ref r rx LocationUnknown)

instance HasRandGen AST_QualRef where
  randO = do
    let n = 2*(fromEnum (maxBound::RefQualifier) - fromEnum (minBound::RefQualifier))
    i <- fmap (flip mod n) randInt
    let (d, m) = divMod i 2
    if m==0
      then  fmap AST_Unqualified randO
      else  liftM3 (AST_Qualified (toEnum d)) randO randO no

instance HasRandGen AST_ObjList where { randO = AST_ObjList <$> randO <*> randO <*> no }
instance HasRandGen AST_CodeBlock where { randO = fmap AST_CodeBlock (randList 0 30) }
instance HasRandGen [Com AST_Object] where { randO = randList 1 20 }

instance HasRandGen RefQualifier where
  randO = fmap toEnum (nextInt (1+fromEnum (maxBound::RefQualifier)))

instance HasRandGen UpdateOp where
  randO = fmap toEnum (nextInt (1+fromEnum (maxBound::UpdateOp)))

instance HasRandGen PrefixOp where
  randO = fmap toEnum (nextInt (1+fromEnum (maxBound::PrefixOp)))

instance HasRandGen InfixOp where
  randO = fmap toEnum (nextInt (1+fromEnum (maxBound::InfixOp)))

--instance HasRandGen AST_ElseIf where
--  randO = randOFromList $
--    [ return AST_NullElseIf
--    , liftM3 AST_Else   randO randO no
--    , liftM4 AST_ElseIf randO randO randO no
--    ]

instance HasRandGen AST_If     where { randO = liftM3 AST_If     randO randO no }
instance HasRandGen AST_Else   where { randO = liftM3 AST_Else   randO randO no }
instance HasRandGen AST_IfElse where { randO = liftM5 AST_IfElse randO (randList 0 4) randO randO no }
instance HasRandGen AST_While  where { randO = liftM  AST_While  randO }
instance HasRandGen AST_Paren  where { randO = pure AST_Paren <*> randO <*> no }

randScriptList :: [RandO AST_Script]
randScriptList =
  [ pure AST_EvalObject   <*> randAssignExpr <*> randO <*> no
  , pure AST_IfThenElse   <*> randO
  , pure AST_WhileLoop    <*> randO
  , pure AST_TryCatch     <*> randO <*> randO <*> randO <*> no
  , pure AST_ForLoop      <*> randO <*> randO <*> randO <*> no
  , pure AST_ContinueExpr <*> randO <*> randO <*> randComWith randObjectASTVoid <*> no
  , pure AST_ReturnExpr   <*> randO <*> randComWith randObjectASTVoid <*> no
  , pure AST_WithDoc      <*> randO <*> randO <*> no
  ]

randScript :: RandO AST_Script
randScript = randOFromList randScriptList

instance HasRandGen AST_Script where
  randO = randOFromList $ randScriptList ++ [liftM AST_Comment randO]

-- | Will create a random 'Dao.Object.AST_Object' of a type suitable for use as a stand-alone script
-- expression, which is only 'AST_Assign'.
randAssignExpr :: RandO AST_Object
randAssignExpr = do
  ox <- randListOf 0 3 (liftM2 (,) randFuncHeader randO)
  o  <- randFuncHeader
  return (foldr (\(left, op) right -> AST_Assign (AST_LValue left) op right LocationUnknown) o ox)

randSingletonASTList :: [RandO AST_Object]
randSingletonASTList = fmap (fmap (flip AST_Literal LocationUnknown)) randSingletonList

randSingletonAST :: RandO AST_Object
randSingletonAST = randOFromList randSingletonASTList

randFuncHeaderList :: [RandO AST_Object]
randFuncHeaderList = fmap loop $
  [ liftM  AST_ObjQualRef randO
  , liftM2 AST_Literal    randO no
  , liftM2 AST_MetaEval   randO no
  ]
  where
    loop rand = rand >>= \o -> nextInt 2 >>= \i ->
      if i==0
        then return o
        else nextInt 2 >>= \c -> 
          (if c==0 then AST_FuncCall else AST_ArraySub) <$> randFuncHeader <*> randO <*> no

randFuncHeader :: RandO AST_Object
randFuncHeader = randOFromList randFuncHeaderList

instance HasRandGen AST_LValue where { randO = liftM AST_LValue randFuncHeader }

randPrefixWith :: RandO AST_Object -> [PrefixOp] -> RandO AST_Object
randPrefixWith randGen ops = randOFromList $ randGen : fmap randOps ops where
  randOps op = do
    obj <- randComWith randGen
    return (AST_Prefix op obj LocationUnknown)

randObjectASTList :: [RandO AST_Object]
randObjectASTList =
  [ randAssignExpr
  , randPrefixWith (randOFromList randSingletonASTList) [INVB, NEGTIV, POSTIV, REF, DEREF]
  , pure AST_Func   <*> randO <*> randO <*> randO <*> randO <*> no
  , pure AST_Lambda <*> randO <*> randO <*> no
  ] ++ randSingletonASTList

randObjectAST :: RandO AST_Object
randObjectAST = randOFromList randObjectASTList

randInfixOp :: RandO (Com InfixOp, (Int, Bool))
randInfixOp = do
  (op, prec) <- randOFromList opGroups
  op         <- randComWith (return op)
  return (op, prec)
  where
    left  op = (op, True )
    right op = (op, False)
    opGroups = fmap return $ do
      (precedence, operators) <- zip [1..] $ (++[[right POW]]) $ fmap (fmap left) $
        [ [EQUL, NEQUL]
        , [GTN, LTN, GTEQ, LTEQ], [SHL, SHR]
        , [OR], [AND], [ORB], [XORB], [ANDB]
        , [ADD, SUB], [DIV, MOD], [MULT], [ARROW]
        ]
      (operator, associativity) <- operators
      return (operator, (precedence, associativity))

randArithmetic :: RandO AST_Object
randArithmetic = do
  o  <- randObjectAST
  ox <- randListOf 0 4 (liftM2 (,) randObjectAST randInfixOp)
  return (fst $ loop 0 o ox)
  where
    bind right op left = AST_Equation right op left LocationUnknown
    loop prevPrec left opx = case opx of
      []                                    -> (left, [])
      -- (right, (op, _                )):[]   -> bind right op left
      (right, (op, (prec, leftAssoc))):next ->
        if prevPrec<prec || (prevPrec==prec && not leftAssoc) -- ? If so, we should bind right
          then  let (right, next) = loop prec left opx in loop prevPrec right next
          else  loop prec (bind right op left) next

-- Can also produce void expressions.
randObjectASTVoidList :: [RandO AST_Object]
randObjectASTVoidList = return AST_Void : randObjectASTList

-- Can also produce void expressions.
randObjectASTVoid :: RandO AST_Object
randObjectASTVoid = randOFromList randObjectASTVoidList

instance HasRandGen AST_Object where
  -- | Differs from 'randAssignExpr' in that this 'randO' can generate 'Dao.Object.AST_Literal' expressions
  -- whereas 'randAssignExpr' will not so it does not generate stand-alone constant expressions within
  -- 'Dao.Object.AST_Script's.
  randO = randOFromList randObjectASTList

randArgsDef :: RandO [Com AST_Object]
randArgsDef = randList 0 7

instance HasRandGen TopLevelEventType where
  randO = fmap toEnum (nextInt 3)

instance HasRandGen a => HasRandGen (TyChkExpr a) where
  randO = randOFromList [NotTypeChecked <$> randO, pure TypeChecked <*> randO <*> randO <*> no]

instance HasRandGen a => HasRandGen (AST_TyChk a) where
  randO = randOFromList [AST_NotChecked <$> randO, pure AST_Checked <*> randO <*> randO <*> randO <*> no]

instance HasRandGen AST_Param where
  randO = randOFromList [return AST_NoParams, pure AST_Param <*> randO <*> randO <*> no]

instance HasRandGen [Com AST_Param] where { randO = randList 0 8 }

instance HasRandGen AST_ParamList where { randO = pure AST_ParamList <*> randO <*> no }

instance HasRandGen AST_TopLevel where
  randO = randOFromList $
    [ do  req_ <- nextInt 2
          let req = ustr $ if req_ == 0 then "require" else "import"
          typ  <- nextInt 2
          item <- randComWith randFuncHeader
          return (AST_Attribute req item LocationUnknown)
    , pure AST_TopScript <*> randScript <*> no
    , pure AST_Event     <*> randO <*> randO <*> randO <*> no
    ]

