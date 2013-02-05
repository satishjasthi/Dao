-- "src/Dao/Debug.hs"  data types used for debugging the Dao System.
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


{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Dao.Debug where

-- | Used to debug multi-threading problems, deadlocks in particular. The basic idea is to rewrite
-- the Haskell code that you want to debug such that all pertinent system calls, like
-- 'Control.Concurrent.forkIO', 'Control.Concurrent.MVar.modifyMVar', and 'System.IO.putStrLn' with
-- debugging equivalents. Each of these calls then logs an event with the debugger, and these events
-- can be written to a file.

import           Dao.String

import           Control.Exception
import           Control.Concurrent
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.IO.Class

import           Data.Maybe
import           Data.List hiding (lookup)
import           Data.Word
import           Data.IORef
import           Data.Time.Clock
import qualified Data.Map as M

import           System.IO

-- | Every function in "Dao.Debug.ON" takes a source code 'Language.Haskell.TH.Location', which can
-- be generated by template Haskell using the $('loc') splice given below. If you don't need a
-- "Dao.Debug.ON" function call to emit source code location at a particular call site, you can pass
-- 'nonloc' instead.
type MLoc = Maybe (String, Int, Int)

data DUnique = DUnique{ dElapsedTime :: !Float, dUniqueWord :: !Word } deriving (Eq, Ord)

data DThread
  = DThread{ dThreadGetId :: !ThreadId }
  | DebugThread{ dThreadGetId :: !ThreadId, dThreadUnique :: !DUnique, dThreadName :: Name }
  deriving (Eq, Ord)

showThID :: ThreadId -> String
showThID tid = let th = show tid in fromMaybe th (stripPrefix "ThreadId " th)

-- | The most fundamental types in "Control.Concurrent" are 'Control.Concurrent.MVar',
-- 'Control.Concurrent.Chan' and 'Control.Concurrent.QSem'. These types are wrapped in a data type
-- that provides more useful information about the variable, particularly a comment string
-- describing the nature of the variable, and a unique identifier.
data DVar v
  = DVar { dbgVar :: v }
  | IDVar { dbgVar :: v, varID :: !DUnique, dbgTypeName :: String }

-- | To avoid dealing with Haskell "forall"ed types, I have here a type which contains the same
-- information found in a 'IDVar' but without the type specific 'dbgVar'. Use 'dVarInfo' to
-- construct this data.
data DVarInfo
  = DNoInfo { varFunction :: String }
  | DVarInfo
    { varFunction  :: String
    , infoVarID    :: DUnique
    , infoTypeName :: String
    }

-- | Takes the interesting information from 'IDVar' so it can be stored in a 'DEvent' data
-- structure.
dVarInfo :: String -> DVar v -> DVarInfo
dVarInfo func dvar = case dvar of
  DVar  _      -> DNoInfo func
  IDVar _ i nm ->
    DVarInfo{varFunction = func, infoVarID = i, infoTypeName = nm}

type DQSem = DVar QSem
type DMVar v = DVar (MVar v)
type DChan v = DVar (Chan v)

-- | These are event signals that are sent when certain functions from the "Control.Concurrent"
-- library are used in a debugging context. The neme of each constructor closely matches the name of
-- the "Control.Concurrent" function that signals it.
data DEvent
  = DStarted        MLoc DThread          String  UTCTime
  | DMsg            MLoc DThread          String
    -- ^ does nothing more than send a 'Prelude.String' message to the debugger.
  | DVarAction      MLoc DThread          DVarInfo
    -- ^ Some 'DVar' was updated somewhere.
  | DStdout         MLoc DThread          String
  | DStderr         MLoc DThread          String
  | DFork           MLoc DThread DThread  String
  | DCatch          MLoc DThread          SomeException
  | DThrowTo        MLoc DThread DThread  SomeException
  | DThrow          MLoc DThread          SomeException
  | DThreadDelay    MLoc DThread Int
  | DThreadUndelay  MLoc DThread Int
  | DThreadDied     MLoc DThread
    -- ^ a signal sent when a thread dies (assuming the thread must have been created with
    -- 'Dao.Debug.ON.dFork')
  | DUncaught       MLoc DThread          SomeException
    -- ^ a signal sent when a thread is killed (assuming the thread must have been created with
    -- 'Dao.Debug.ON.dFork').
  | DHalt -- ^ Sent when the thread being debugged is done.

-- | This is a state that is passed around to every function that uses the "Dao.Debug" facilities.
-- If you have a state data type @R@ that you pass around your program via the
-- 'Control.Monad.Reader.ReaderT' monad, instantiate @R@ into the 'Bugged' class, and your monad
-- will be able to use any of the functions in the "Dao.Debug.ON" module.
data DebugData
  = DebugData
    { debugGetThreadId :: DThread
    , debugChan        :: Chan DEvent
    , debugStartTime   :: UTCTime
    , debugUniqueCount :: MVar Word
    , debugPrint       :: DEvent -> IO ()
    , debugClose       :: IO ()
    }

initDebugData :: IO DebugData
initDebugData = do
  this <- myThreadId
  chan <- newChan
  time <- getCurrentTime
  uniq <- newMVar 1
  return $
    DebugData
    { debugGetThreadId =
        DebugThread
        { dThreadGetId = this
        , dThreadUnique = DUnique 0 0
        , dThreadName = ustr "DEBUG THREAD"
        }
    , debugChan        = chan
    , debugStartTime   = time
    , debugUniqueCount = uniq
    , debugPrint       = \_ -> return ()
    , debugClose       = return ()
    }

type DebugRef = Maybe DebugData

data DHandler r a =
  DHandler
  { getHandlerMLoc :: MLoc
  , getHandler :: r -> (SomeException -> IO ()) -> Handler a
  }

dHandler :: (Exception e, Bugged r m) => MLoc -> (e -> m a) -> DHandler r a
dHandler loc catchfn =
  DHandler
  { getHandlerMLoc = loc
  , getHandler = \r sendEvent -> Handler $ \e ->
      sendEvent (SomeException e) >> debugUnliftIO (askDebug >>= \debug -> catchfn e) r
  }

data DebugOutputTo
  = DebugOutputToDefault
  | DebugOutputToHandle  Handle
  | DebugOutputToFile    FilePath
  | DebugOutputToChannel (Chan DEvent)

data SetupDebugger r m
  = SetupDebugger
    { debugEnabled      :: Bool
      -- ^ explicitly enable or disable debugging
    , debugComment      :: String
      -- ^ a comment to write at the beggining of the debug output stream
    , debugOutputTo     :: DebugOutputTo
      -- ^ if the 'debugHandle' is not specified, it can be created by specifying a file path here.
    , initializeRuntime :: DebugRef -> IO r
      -- ^ the function to initialize the state that will be used for the 'beginProgram' function.
    , beginProgram      :: m ()
      -- ^ the program to run in the debug thread.
    }

setupDebugger :: Bugged r m => SetupDebugger r m
setupDebugger =
  SetupDebugger
  { debugEnabled      = True
  , debugComment      = ""
  , debugOutputTo     = DebugOutputToDefault
  , initializeRuntime = error "main program does not define \"Dao.Debug.initializeRuntime\""
  , beginProgram      = return ()
  }

----------------------------------------------------------------------------------------------------

class HasDebugRef st where
  getDebugRef :: st -> DebugRef
  setDebugRef :: DebugRef -> st -> st

instance HasDebugRef (Maybe DebugData) where { getDebugRef = id ; setDebugRef = const }

-- | Any monad that evaluates with stateful data in the IO monad, including
-- @('Control.Monad.Reader.ReaderT' r IO)@ or @('Control.Monad.State.Lazy.StateT' st IO)@, can be
-- made into a 'Bugged' monad, so long as the stateful data type contains a 'DebugData' that has
-- been initialized only once. Instantiating 'askDebug' with
-- @('Control.Monad.Trans.Class.lift' 'Dao.Debug.ON.initDebugger')@ will deadlock the debugger
-- thread and most likely result in a 'Control.Exception.BlockedIndefinitelyOnMVar' exception.
class (Functor m, MonadIO m, Monad m, HasDebugRef r) => Bugged r m | m -> r where
  askDebug :: m DebugRef
  askState :: m r
  setState :: (r -> r) -> m a -> m a
  debugUnliftIO :: m a -> r -> IO a

instance HasDebugRef r => Bugged r (ReaderT r IO) where
  askDebug = fmap getDebugRef ask
  askState = ask
  setState = local
  debugUnliftIO = runReaderT

instance HasDebugRef st => Bugged st (StateT st IO) where
  askDebug = fmap getDebugRef get
  askState = get
  setState = withStateT
  debugUnliftIO = evalStateT

withDebugger :: Bugged r m => DebugRef -> m a -> m a
withDebugger d = setState (setDebugRef d)

inheritDebugger :: Bugged r m => m a -> m a
inheritDebugger fn = askDebug >>= \d -> setState (setDebugRef d) fn

