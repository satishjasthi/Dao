-- "src/Dao/Object/Binary.hs"  provides the instantiation of the Dao
-- "Object" data type into the "Data.Binary" class that is exported by
-- the "binary" package.
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

module Dao.Object.Binary where

import           Dao.Types
import qualified Dao.Tree as T
import           Dao.Pattern
import           Dao.Object
import           Dao.Object.Data

import           Control.Monad

import           Data.Typeable
import           Data.Dynamic
import           Data.Word
import           Data.Bits
import           Data.Char
import           Data.Complex
import qualified Data.ByteString.Lazy   as B
import qualified Data.Set               as S
import qualified Data.Map               as M
import qualified Data.IntMap            as I
import           Data.Array.IArray
import           Data.Time hiding (parseTime)

import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Put

import Debug.Trace

----------------------------------------------------------------------------------------------------

-- | The magic number is the first 8 bytes to every bytecode compiled object program. It is the
-- ASCII value of the string "DaoExec\0".
program_magic_number :: Word64
program_magic_number = 0x44616F4578656300

-- | This is the version number of the line protocol for transmitting bytecode compiled program
-- objects.
program_data_version :: Word64
program_data_version = 0

-- | Take a the last four 'Data.Char.Char's in a string and convert them to a 4-byte
-- 'Data.Word.Word', the earliest 'Data.Char.Char' being in the highest byte, the last character
-- being in the lowest byte.
char4code :: String -> Word32
char4code = foldl (\a b -> shift a 8 .|. fromIntegral (ord b)) 0

-- | This is a simple 64-bit checksum I wrote myself because I don't currently have a better one.
simpleChecksum :: Word64 -> B.ByteString -> Word64
simpleChecksum init b = foldl f init (B.unpack b) where
  f sum b =
    let lo  = 0x0000000000FFFFFF
        mid = 0x0000FFFFFF000000
        s3 = fromIntegral (0x07 .&. sum) -- get a rotation value from the bottom 3 bits of the sum
        r1 = shift (fromIntegral b) (s3+48)
        r2 = xor r1 ((sum .&. lo)*0x0A + fromIntegral b) -- on the lower 24 bits, x*10+y
        r3 = shift (r2 .&. mid) 1
        r4 = (r3 .&. mid) .|. if testBit r3 48 then shift 1 24 else 0
        r5 = xor 0x00000FFF $ -- gather bits from various locations into a 24-bit number
               f [ 63, 62, 59, 50, 56, 54, 3, 6, 6,  2, 12, 23
                 , 61, 48, 53, 48, 51, 59, 2, 5, 7, 14, 17,  1]
        f = foldl (\x d -> shift x 1 .|. if testBit r2 d then 1 else 0) 0
    in  r2 .|. (xor r4 (shift r5 24))

-- | Returns the string of bytes created by 'Data.Binary.Put.Put' and the checksum of those bytes.
putWithChecksum :: (B.ByteString -> s) -> Put -> PutM (B.ByteString, s)
putWithChecksum checkSum puta = let bx = runPut puta in return (bx, checkSum bx)

getWithChecksum :: Binary a => (B.ByteString -> s) -> Get a -> Get (a, s)
getWithChecksum checkSum geta = do
  (a, count) <- lookAhead (geta >>= \a -> bytesRead >>= \count -> return (a, count))
  bx <- getLazyByteString count
  return (a, checkSum bx)

----------------------------------------------------------------------------------------------------

putListWith :: [a] -> (a -> Put) -> Put
putListWith ax p = mapM_ p ax >> putWord8 0x00

getListWith :: Get a -> Get [a]
getListWith getx = loop [] where
  loop ax = do
    w <- lookAhead getWord8
    case w of
      0x00 -> getWord8 >> return ax
      _    -> getx >>= \a -> loop (ax++[a])

putList :: Binary a => [a] -> Put
putList ax = putListWith ax put

getList :: Binary a => Get [a]
getList = getListWith get

----------------------------------------------------------------------------------------------------

putMapWith :: (Eq k, Ord k) => (k -> Put) -> (v -> Put) -> M.Map k v -> Put
putMapWith putk putv m = putListWith (M.assocs m) (\ (a, b) -> putk a >> putv b)

getMapWith :: (Eq k, Ord k) => Get k -> Get v -> Get (M.Map k v)
getMapWith getk getv = fmap M.fromList (getListWith (liftM2 (,) getk getv))

putMap :: (Eq k, Ord k, Binary k, Binary v) => M.Map k v -> Put
putMap m = putMapWith put put m

getMap :: (Eq k, Ord k, Binary k, Binary v) => Get (M.Map k v)
getMap = getMapWith get get

putObjMap :: Binary a => (m -> [(a, Object)]) -> m -> Put
putObjMap asocs o = putListWith (asocs o) (\ (i, o) -> put i >> put o)

getObjMap :: Binary a => ([(a, Object)] -> m) -> Get m
getObjMap fromList = fmap fromList (getListWith (get >>= \i -> get >>= \o -> return (i, o)))

putTreeWith :: (Eq p, Ord p) => (p -> Put) -> (a -> Put) -> T.Tree p a -> Put
putTreeWith putp puta t =
  case t of
    T.Void           -> putWord8 0x21
    T.Leaf       a   -> putWord8 0x22 >> puta a
    T.Branch       t -> putWord8 0x23 >> putMapWith putp (putTreeWith putp puta) t
    T.LeafBranch a t -> putWord8 0x24 >> puta a >> putMapWith putp (putTreeWith putp puta) t

getTreeWith :: (Eq p, Ord p, Show p, Show a) => Get p -> Get a -> Get (T.Tree p a)
getTreeWith getp geta = do
  t <- getWord8
  case t of
    0x21 -> return T.Void
    0x22 -> geta >>= \a -> return (T.Leaf{T.branchData=a})
    0x23 -> getMapWith getp (getTreeWith getp geta) >>= \t -> return (T.Branch{T.branchMap=t})
    0x24 -> do
      a <- geta
      t <- getMapWith getp (getTreeWith getp geta)
      return (T.LeafBranch{T.branchData=a, T.branchMap=t})
    _    -> error "corrupted T.Tree data"

instance (Eq p, Ord p, Binary p, Binary a, Show p, Show a) => Binary (T.Tree p a) where
  put t = putTreeWith put put t
  get   = getTreeWith get get

----------------------------------------------------------------------------------------------------

typeIDBytePrefix :: TypeID -> Word8
typeIDBytePrefix t = case t of
  NullType     -> 0x05
  TrueType     -> 0x06
  TypeType     -> 0x07
  IntType      -> 0x08
  WordType     -> 0x09
  LongType     -> 0x0a
  FloatType    -> 0x0b
  RatioType    -> 0x0C
  ComplexType  -> 0x0D
  TimeType     -> 0x0E
  DiffTimeType -> 0x0F
  CharType     -> 0x10
  StringType   -> 0x11
  RefType      -> 0x12
  PairType     -> 0x13
  ListType     -> 0x14
  SetType      -> 0x15
  ArrayType    -> 0x16
  IntMapType   -> 0x17
  DictType     -> 0x18
  TreeType     -> 0x19
  PatternType  -> 0x1A
  ScriptType   -> 0x1B
  RuleType     -> 0x1C
  BytesType    -> 0x1D

bytePrefixToTypeID :: Word8 -> TypeID
bytePrefixToTypeID t = case t of
  0x05 ->     NullType
  0x06 ->     TrueType
  0x07 ->     TypeType
  0x08 ->      IntType
  0x09 ->     WordType
  0x0a ->     LongType
  0x0b ->    FloatType
  0x0C ->    RatioType
  0x0D ->  ComplexType
  0x0E ->     TimeType
  0x0F -> DiffTimeType
  0x10 ->     CharType
  0x11 ->   StringType
  0x12 ->      RefType
  0x13 ->     PairType
  0x14 ->     ListType
  0x15 ->      SetType
  0x16 ->    ArrayType
  0x17 ->   IntMapType
  0x18 ->     DictType
  0x19 ->     TreeType
  0x1A ->  PatternType
  0x1B ->   ScriptType
  0x1C ->     RuleType
  0x1D ->    BytesType

instance Binary TypeID where
  put t = putWord8 (typeIDBytePrefix t)
  get = do
    w <- getWord8
    if 0x05<=w && w<=0x1D
      then return (bytePrefixToTypeID w)
      else fail "was expecting type data"

instance Binary Object where
  put o = do
    let x o p = putWord8 (typeIDBytePrefix (objType o)) >> put p
        px o putx = putWord8 (typeIDBytePrefix (objType o)) >> putx
    case o of
      ONull           -> px ONull (return ())
      OTrue           -> px OTrue (return ())
      OType         a -> x o a
      OInt          a -> x o a
      OWord         a -> x o a
      OLong         a -> x o a
      OFloat        a -> x o a
      ORatio        a -> x o a
      OComplex      a -> x o a
      OTime         a -> x o a
      ODiffTime     a -> x o a
      OChar         a -> x o a
      OString       a -> x o a
      ORef         rx -> px o (putList rx)
      OPair     (a,b) -> px o (put a >> put b)
      OList         a -> px o (putList a)
      OSet          a -> px o (putList (S.elems a))
      OArray        a -> px o $
        let (lo, hi) = bounds a in put lo >> put hi >> putList (elems a)
      OIntMap       a -> px o (putObjMap I.assocs a)
      ODict         a -> px o (putObjMap M.assocs a)
      OTree         a -> x o a
      OPattern      a -> px o (put a)
      OScript       a -> px o (put a)
      ORule         a -> px o (put a)
      OBytes        a -> x o a
  get = do
    ty <- getWord8
    let x fn = fmap fn get
    case bytePrefixToTypeID ty of
      NullType     -> return ONull
      TrueType     -> return OTrue
      TypeType     -> x OType
      IntType      -> x OInt
      WordType     -> x OWord
      LongType     -> x OLong
      FloatType    -> x OFloat
      RatioType    -> x ORatio
      ComplexType  -> x OComplex
      TimeType     -> x OTime
      DiffTimeType -> x ODiffTime
      CharType     -> x OChar
      StringType   -> x OString
      RefType      -> fmap ORef getList
      PairType     -> get >>= \a -> get >>= \b -> return (OPair (a, b))
      ListType     -> fmap OList getList
      SetType      -> fmap (OSet . S.fromList) getList
      ArrayType    -> do
        get >>= \lo -> get >>= \hi -> getList >>= \ax ->
          return (OArray (listArray (lo, hi) ax))
      IntMapType   -> fmap OIntMap (getObjMap (I.fromList))
      DictType     -> fmap ODict   (getObjMap (M.fromList))
      TreeType     -> x OTree
      PatternType  -> x OPattern
      ScriptType   -> x OScript
      RuleType     -> x ORule
      BytesType    -> x OBytes

instance Binary UTCTime where
  put t = do
    put (toModifiedJulianDay (utctDay t))
    put (toRational (utctDayTime t))
  get = do
    d <- fmap ModifiedJulianDay get
    t <- fmap fromRational get
    return (UTCTime{ utctDay = d, utctDayTime = t })

instance Binary NominalDiffTime where
  put t = put (toRational t)
  get = fmap fromRational get

instance (Binary a, RealFloat a) => Binary (Complex a) where
  put o = put (realPart o) >> put (imagPart o)
  get = liftM2 (:+) get get

----------------------------------------------------------------------------------------------------

--  instance Binary PatUnit where
--    put p = case objToList (OPattern p) of
--      Nothing -> error "internal error: failed to convert Pattern to OPattern"
--      Just ox -> putObjList ox
--    get = do
--      p <- getWord8 :: Get Word8
--      case p of
--        0x29 -> return Wildcard
--        0x2A -> return AnyOne
--        0x2B -> fmap Single get
--        _    -> fail "failed while decoding pattern object from binary data"
--  
--  instance Binary Pattern where
--    put p = put (getPatternLength p) >> put (getPatUnits p)
--    get = get >>= \i -> get >>= \px -> return (Pattern{getPatternLength = i, getPatUnits = px })

instance Binary PatUnit where
  put p = case p of
    Wildcard -> putWord8 1
    AnyOne   -> putWord8 2
    Single o -> putWord8 3 >> put o
  get = getWord8 >>= \w -> case w of
    1 -> return Wildcard
    2 -> return AnyOne
    3 -> fmap Single get
    _ -> error "corrupted Pattern object in binary file"

instance Binary Pattern where
  put p = putList (getPatUnits p)
  get   = getList >>= \px -> return $
    Pattern
    { getPatUnits = px
    , getPatternLength = length px
    }

----------------------------------------------------------------------------------------------------

putNullTermStr :: Name -> Put
putNullTermStr nm = mapM_ putWord8 (uwords nm) >> putWord8 0

getNullTermStr :: Get UStr
getNullTermStr = loop [] where
  loop wx = getWord8 >>= \w -> if w==0 then return (upack wx) else loop (wx++[w])

putCommentList :: [Comment] -> Put
putCommentList comx = putListWith comx $ \com ->
  case com of
    InlineComment  com -> putWord8 0x31 >> put com
    EndlineComment com -> putWord8 0x32 >> put com

getCommentList :: Get [Comment]
getCommentList = getListWith $ do
  w <- getWord8
  case w of
    0x31 -> fmap InlineComment  get
    0x32 -> fmap EndlineComment get
    _    -> error "expecting comment string"

putComWith :: (a -> Put) -> Com a -> Put
putComWith p com = case com of
  Com          a    -> p a
  ComBefore c1 a    -> putWord8 0x39 >> putCommentList c1 >> p a
  ComAfter     a c2 -> putWord8 0x3A >> p a >> putCommentList c2
  ComAround c1 a c2 -> putWord8 0x3B >> putCommentList c1 >> p a >> putCommentList c2

getComWith :: Get a -> Get (Com a)
getComWith getx = do
  let g = getWord8
  w <- lookAhead g
  case w of
    0x39 -> g >> liftM2 ComBefore getCommentList getx
    0x3A -> g >> liftM2 ComAfter                 getx getCommentList
    0x3B -> g >> liftM3 ComAround getCommentList getx getCommentList
    _    ->      liftM  Com                      getx

putCom :: Binary a => Com a -> Put
putCom c = putComWith put c

getCom :: Binary a => Get (Com a)
getCom = getComWith get

putComListWith :: (a -> Put) -> Com [Com a] -> Put
putComListWith fn rx = putComWith (flip putListWith (putComWith fn)) rx

getComListWith :: Binary a => Get a -> Get (Com [Com a])
getComListWith fn = getComWith (getListWith (getComWith fn))

putComList :: Binary a => Com [Com a] -> Put
putComList ax = putComListWith put ax

getComList :: Binary a => Get (Com [Com a])
getComList = getComListWith get

----------------------------------------------------------------------------------------------------

instance Binary ObjectExpr where
  put o = case o of
    Literal      a     -> x 0x41 $ putCom a
    IntRef       a     -> x 0x42 $ putCom a
    LocalRef     a     -> x 0x43 $ putCom a
    GlobalRef    a     -> x 0x44 $ putComWith putList a
    AssignExpr   a b   -> x 0x45 $ putCom a >> putCom b
    FuncCall     a b   -> x 0x46 $ putCom a >> putComList b
    LambdaCall   a b c -> x 0x47 $ putComWith return a >> putCom b >> putComList c
    ParenExpr    a     -> x 0x48 $ putCom a
    Equation     a b c -> x 0x49 $ putCom a >> putCom b >> putCom c
    DictExpr     a b   -> x 0x4A $ putCom a >> putComList b
    ArrayExpr    a b c -> x 0x4B $ putComWith return a >> putComList b >> putComList c
    ArraySubExpr a b   -> x 0x4C $ putCom a >> putCom b
    LambdaExpr   a b c -> x 0x4D $ putComWith return a >> putComList b >> putComList c
    where
      x i putx  = putWord8 i >> putx
      char3 str = mapM_ (putWord8 . fromIntegral) (take 3 (map ord (uchars str) ++ repeat 0))
  get = do
    w <- getWord8
    case w of
      0x41 -> liftM  Literal      getCom
      0x42 -> liftM  IntRef       getCom
      0x43 -> liftM  LocalRef     getCom
      0x44 -> liftM  GlobalRef    (getComWith getList)
      0x45 -> liftM2 AssignExpr   getCom getCom
      0x46 -> liftM2 FuncCall     getCom getComList
      0x47 -> liftM3 LambdaCall   (getComWith (return ())) getCom getComList
      0x48 -> liftM  ParenExpr    getCom
      0x49 -> liftM3 Equation     getCom getCom getCom
      0x4A -> liftM2 DictExpr     getCom getComList
      0x4B -> liftM3 ArrayExpr    (getComWith (return ())) getComList getComList
      0x4C -> liftM2 ArraySubExpr getCom getCom
      0x4D -> liftM3 LambdaExpr   (getComWith (return ())) getComList getComList
      _    -> error "could not load, corrupted data in object expression"
      where
        { char3 = do
            (a, b, c) <- liftM3 (,,) getWord8 getWord8 getWord8
            return (ustr (map (chr . fromIntegral) [a, b, c]))
        }

instance Binary ScriptExpr where
  put s = case s of
    NO_OP              -> putWord8 0x51
    EvalObject   a     -> x 0x52 $ putCom a
    IfThenElse   a b c -> x 0x53 $ putCom a            >> putComList b >> putComList c
    TryCatch     a b c -> x 0x54 $ putComList a        >> putCom b     >> putComList c
    ForLoop      a b c -> x 0x55 $ putCom a            >> putCom b     >> putComList c
    ContinueExpr a b c -> x 0x56 $ putComWith bool a   >> putCom b     >> putComWith return c
    ReturnExpr   a b c -> x 0x57 $ putComWith bool a   >> putCom b     >> putComWith return c
    WithDoc      a b   -> x 0x58 $ putCom a            >> putComList b
    where
      x i putx = putWord8 i >> putx
      bool a = putWord8 (if a then 0x82 else 0x81)
  get = do
    w <- getWord8
    case w of
      0x51 -> return NO_OP
      0x52 -> liftM  EvalObject   getCom
      0x53 -> liftM3 IfThenElse   getCom     getComList getComList
      0x54 -> liftM3 TryCatch     getComList getCom     getComList
      0x55 -> liftM3 ForLoop      getCom     getCom     getComList
      0x56 -> liftM3 ContinueExpr getComBool getCom     getBlank
      0x57 -> liftM3 ReturnExpr   getComBool getCom     getBlank
      0x58 -> liftM2 WithDoc      getCom     getComList
      _    -> error "could not load, script data is corrupted"
      where
        bool = getWord8 >>= \w -> case w of
          0x82 -> return True
          0x81 -> return False
          _    -> error "expecting boolean for continue/return expression, script data is corrupted"
        getComBool = getComWith bool
        getBlank = getComWith (return ())

----------------------------------------------------------------------------------------------------

instance Binary Rule where
  put r = putComListWith put (rulePattern r) >> putComListWith put (ruleAction r)
  get   = liftM2 Rule (getComListWith get) (getComListWith get)

instance Binary Script where
  put s = putComList (scriptArgv s) >> putComList (scriptCode s)
  get   = liftM2 Script getComList getComList

instance Binary Directive where
  put d = case d of
    ImportExpr     name           -> x 0x61 (putCom name)
    ToplevelDefine name obj       -> x 0x62 (putComWith putList name >> putCom obj)
    RuleExpr       rule           -> x 0x63 (putCom rule)
    BeginExpr      scrp           -> x 0x64 (putComList scrp)
    EndExpr        scrp           -> x 0x65 (putComList scrp)
    Requires       req nm         -> x 0x66 $
      putComWith putNullTermStr req >> putComWith putNullTermStr nm
    ToplevelFunc   f nm args scrp -> x 0x67 $ do
      putComWith     return         f
      putComWith     putNullTermStr nm
      putComListWith putNullTermStr args
      putComList     scrp
    where { x i putx = putWord8 i >> putx }
  get = do
    w <- getWord8
    case w of
      0x61 -> liftM  ImportExpr     getCom
      0x62 -> liftM2 ToplevelDefine (getComWith getList) (getCom)
      0x63 -> liftM  RuleExpr       getCom
      0x64 -> liftM  BeginExpr      getComList
      0x65 -> liftM  EndExpr        getComList
      0x66 -> liftM  EndExpr        getComList
      0x67 -> do
        f    <- getComWith (return ())
        nm   <- getComWith getNullTermStr
        args <- getComListWith getNullTermStr
        scrp <- getComList
        return (ToplevelFunc f nm args scrp)

instance Binary SourceCode where
  put sc = do
    (bx, cksum) <- putWithChecksum (simpleChecksum 0) $ do
      putWord64be program_magic_number
      putWord64be program_data_version
      putCom (sourceModuleName sc)
      putComList (directives sc)
    putLazyByteString bx
    putWord64be cksum
  get = do
    let chk msg a = get >>= \b -> if b==a then return () else error ("failed reading binary, "++msg)
    (sc, myCksum) <- getWithChecksum (simpleChecksum 0) $ do
      chk "wrong \"magic\" number, this may not be a Dao compiled program" $
        program_magic_number
      chk "this program was compiled with an incompatible version of the Dao binary protocal" $
        program_data_version
      liftM2 (SourceCode nil) getCom getComList
    theirCksum <- getWord64be
    if myCksum == theirCksum
      then return sc
      else error "the checksum test for the compiled source code failed"

----------------------------------------------------------------------------------------------------

testBinary :: (Binary o, Show o) => o -> IO o
testBinary o = do
  putStrLn ("Original:\n\t"++show o)
  let b = B.unpack (runPut (put o))
  seq b $ putStrLn ("Binary:\n\t"++showEncoded b++"\n")
  return $! (runGet get (B.pack b))

