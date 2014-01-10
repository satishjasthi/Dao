-- "src/Dao.hs"  the smallest interface that can be imported by any
-- Haskell program that makes use of the Dao System by way of linking
-- to the modules in the dao package.
-- 
-- Copyright (C) 2008-2014  Ramin Honary.
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

-- | This module is pretty much where everything begins. It is the smallest interface that can be
-- imported by any Haskell program making use of the Dao System. You can use the functions in this
-- module to initialize a 'Dao.Object.Runtime' data structure, then use it to start an input query
-- loop with 'inputQueryLoop'. The query loop requires you pass a callback function that, on each
-- evaluation, returns the next string to be used the query to the 'Dao.Object.Runtime'.
--
-- To have more control over execution of string queries, you will need to import the "Dao.Tasks"
-- module and make use of those functions to create 'Dao.Object.Job's from string queries, then wait
-- for those 'Dao.Object.Job's to complete.
module Dao
  ( module Dao.String
  , module Dao.Object
  , module Dao.Evaluator
  , module Dao
  ) where

import Debug.Trace

import           Dao.String
import qualified Dao.Tree as T
import           Dao.Glob
import           Dao.Object
import           Dao.Predicate
import           Dao.Evaluator
import           Dao.PPrint
import           Dao.Token
import           Dao.Parser
import           Dao.Object.Parser

import           Data.Function
import           Data.Monoid
import           Data.IORef
import qualified Data.Map as M

import           Control.Applicative
import           Control.Concurrent
import           Control.DeepSeq
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Reader.Class

import           System.IO

----------------------------------------------------------------------------------------------------

-- | The minimum amount of time allowable for a single input string to execute before timing out.
-- Any time smaller than this ammount, and it may not be possible to execute anything before it
-- times out, so if you are setting a timeout limit, make sure it is as large as what you have
-- patience for.
min_exec_time :: Int
min_exec_time = 200000

-- | Evaluate this function as one of the instructions in the monadic function passed to the
-- 'setupDao' function in order to install the most fundamental functions into the Dao evaluator.
-- This function must be evaluated in order to have access to the following functions:
-- > exec, prove
daoFuncs :: DaoSetup
daoFuncs = return ()

----------------------------------------------------------------------------------------------------

-- | An 'Action' is the result of a pattern match that occurs during an input string query. It is a
-- data structure that contains all the information necessary to run an 'Subroutine' assocaited with
-- a 'Glob', including the parent 'ExecUnit', the 'Dao.Glob.Glob' and the 'Dao.Glob.Match' objects,
-- and the 'Executables'. Use 'Dao.Evaluator.execute' to evaluate a 'Dao.Action' in the current
-- thread.
-- 
-- To execute an action in a separate thread, use 'forkExecAction'.
data Action
  = Action
    { actionQuery     :: Maybe UStr
    , actionPattern   :: Maybe (Glob UStr)
    , actionMatch     :: T.Tree Name [UStr]
    , actionCodeBlock :: Subroutine
    }

instance Executable Action (Maybe Object) where
  execute act =
    local
      (\xunit ->
          xunit
          { currentQuery     = actionQuery act
          , currentPattern   = actionPattern act
          , currentCodeBlock = StaticStore (Just $ actionCodeBlock act)
          }
      )
      (runCodeBlock (fmap (obj . fmap obj) $ actionMatch act) (actionCodeBlock act))

-- | An 'ActionGroup' is a group of 'Action's created within a given 'ExecUnit', this data structure
-- contains both the list of 'Action's and the 'ExecUnit' from which the actions were generated. The
-- 'Action's within the group will all be evaluated inside of the 'ExecUnit'. Use
-- 'Dao.Evaluator.execute' to execute an 'ActionGroup' in the current thread.
-- 
-- Instantiates 'Executable' such that for every 'Dao.Object.Action' in the
-- 'Dao.Object.ActionGroup', evaluate that 'Dao.Object.Action' in a the current thread but in using
-- the 'Dao.Object.ExecUnit' of the given 'Dao.Object.ActionGroup'.
data ActionGroup
  = ActionGroup
    { actionExecUnit :: ExecUnit
    , getActionList  :: [Action]
    }

instance Executable ActionGroup () where
  execute o = local (const (actionExecUnit o)) $ do
    xunit <- ask
    mapM_ execute (preExec xunit)
    mapM_ execute (getActionList o)
    mapM_ execute (postExec xunit)

----------------------------------------------------------------------------------------------------

type DepGraph = M.Map UPath [UPath]

getDepFiles :: DepGraph -> [UPath]
getDepFiles = M.keys

loadEveryModule :: [UPath] -> Exec ()
loadEveryModule args = do
  deps <- importFullDepGraph args
  mapM_ loadModule (getDepFiles deps)

-- | Simply converts an 'Dao.Object.AST.AST_SourceCode' directly to a list of
-- 'Dao.Object.TopLevelExpr's.
evalTopLevelAST :: AST_SourceCode -> Exec Program
evalTopLevelAST ast = case toInterm ast of
  [o] -> return o
  []  -> fail "converting AST_SourceCode to Program by 'toInterm' returned null value"
  _   -> fail "convertnig AST_SourceCode to Program by 'toInterm' returned ambiguous value"

-- Called by 'loadModHeader' and 'loadModule', throws a Dao exception if the source file could not
-- be parsed.
loadModParseFailed :: Maybe UPath -> DaoParseErr -> Exec ig
loadModParseFailed path err = execThrow $ obj $ concat $
  [ maybe [] (\path -> [obj $ uchars path ++ maybe "" show (parseErrLoc err)]) path
  , maybe [] (return . obj) (parseErrMsg err)
  , maybe [] (\tok -> [obj "on token", obj (show tok)]) (parseErrTok err)
  ]

-- | Load only the "require" and "import" statements from a Dao script file at the given filesystem
-- path. Called by 'importDepGraph'.
loadModHeader :: UPath -> Exec [(Name, Object, Location)]
loadModHeader path = do
  text <- liftIO (readFile (uchars path))
  case parse daoGrammar mempty text of
    OK    ast -> do
      let attribs = takeWhile isAST_Attribute (directives ast) >>= attributeToList
      forM attribs $ \ (attrib, astobj, loc) -> case toInterm (unComment astobj) of
        []  -> execThrow $ obj $
          [obj ("bad "++uchars attrib++" statement"), obj (prettyShow astobj)]
        o:_ -> do
          o <- execute o
          case o of
            Nothing -> execThrow $ obj $
              [ obj $ "parameter to "++uchars attrib++" evaluated to void"
              , obj (prettyShow astobj)
              ]
            Just  o -> return (attrib, o, loc)
    Backtrack -> execThrow $ obj $
      [obj path, obj "does not appear to be a valid Dao source file"]
    PFail err -> loadModParseFailed (Just path) err

-- | Creates a child 'ExecUnit' for the current 'ExecUnit' and populates it with data by parsing and
-- evaluating the contents of a Dao script file at the given filesystem path. If the module at the
-- given path has already been loaded, the already loaded module 'ExecUnit' is returned.
loadModule :: UPath -> Exec ExecUnit
loadModule path = do
  xunit <- ask
  mod   <- fmap (M.lookup path) (asks importGraph >>= liftIO . readMVar)
  case mod of
    Just mod -> return mod
    Nothing  ->  do
      text <- liftIO (readFile (uchars path))
      case parse daoGrammar mempty text of
        OK    ast -> deepseq ast $! do
          mod <- newExecUnit (Just path)
          mod <- local (const mod) (evalTopLevelAST ast >>= execute) -- modifeis and returns 'mod' 
          liftIO $ modifyMVar_ (pathIndex xunit) (return . M.insert path mod)
          return mod
        Backtrack -> execThrow $ obj [obj path, obj "does not appear to be a valid Dao source file"]
        PFail err -> loadModParseFailed (Just path) err

-- | Takes a non-dereferenced 'Dao.Object.Object' expression which was returned by 'execute'
-- and converts it to a file path. This is how "import" statements in Dao scripts are evaluated.
-- This function is called by 'importDepGraph', and 'importFullDepGraph'.
objectToImport :: UPath -> Object -> Location -> Exec [UPath]
objectToImport file o lc = case o of
  OString str -> return [str]
  o           -> execThrow $ obj $ 
    [ obj (uchars file ++ show lc)
    , obj "contains import expression evaluating to an object that is not a file path", o
    ]

objectToRequirement :: UPath -> Object -> Location -> Exec UStr
objectToRequirement file o lc = case o of
  OString str -> return str
  o           -> execThrow $ obj $ 
    [ obj (uchars file ++ show lc)
    , obj "contains import expression evaluating to an object that is not a file path", o
    ]

-- | Calls 'loadModHeader' for several filesystem paths, creates a dependency graph for every import
-- statement. This function is not recursive, it only gets the imports for the paths listed. It
-- takes an existing 'DepGraph' of any files that have already checked so they are not checked
-- again. The returned 'DepGraph' will contain only the lists of imports for files in the given list
-- of file paths that are not already in the given 'DepGraph', so you may need to
-- 'Data.Monoid.mappend' the returned 'DepGraph's to the one given as a parameter. If the returned
-- 'DepGraph' is 'Data.Monoid.mempty', there is no more work to be done.
importDepGraph :: DepGraph -> [UPath] -> Exec DepGraph
importDepGraph graph files = do
  let isImport  attrib = attrib == ustr "import"  || attrib == ustr "imports"
  -- let isRequire attrib = attrib == ustr "require" || attrib == ustr "requires"
  fhdrs <- forM files (\file -> loadModHeader file >>= \hdrs -> return (file, hdrs))
  fmap mconcat $ forM fhdrs $ \ (file, attribs) ->
    if M.member file graph
      then  return mempty
      else  do
        imports <- fmap mconcat $ forM attribs $ \ (attrib, o, lc) ->
          if isImport attrib
            then objectToImport file o lc
            else return mempty
        return (M.singleton file imports)

-- | Recursively 'importDepGraph' until the full dependency graph is generated.
importFullDepGraph :: [UPath] -> Exec DepGraph
importFullDepGraph = loop mempty where
  loop graph files = importDepGraph graph files >>= \newGraph ->
    if M.null newGraph then return graph else loop (mappend graph newGraph) (M.keys newGraph)

----------------------------------------------------------------------------------------------------

-- | This is the main input loop. Pass an input function callback to be called on every loop. This
-- function should return strings to be evaluated, and return 'Data.Maybe.Nothing' to signal that
-- this loop should break.
daoInputLoop :: Exec (Maybe UStr) -> Exec ()
daoInputLoop getString = fix $ \loop -> do
  inputString <- getString
  case inputString of
    Nothing          -> return ()
    Just inputString -> execStringQuery inputString >> loop

-- | Match a given input string to the 'Dao.Evaluator.currentPattern' of the current 'ExecUnit'.
-- Return all patterns and associated match results and actions that matched the input string, but
-- do not execute the actions. This is done by tokenizing the input string and matching the tokens
-- to the program using 'Dao.Glob.matchTree'. NOTE: Rules that have multiple patterns may execute
-- more than once if the input matches more than one of the patterns associated with the rule. *This
-- is not a bug.* Each pattern may produce a different set of match results, it is up to the
-- programmer of the rule to handle situations where the action may execute many times for a single
-- input.
-- 
-- Once you have created an action group, you can execute it with 'Dao.Evaluator.execute'.
makeActionsForQuery :: UStr -> Exec ActionGroup
makeActionsForQuery instr = do
  --tokenizer <- asks programTokenizer
  --tokenizer instr >>= match -- TODO: put the customizable tokenizer back in place
  match (map toUStr $ words $ fromUStr instr)
  where
    match tox = do
      xunit <- ask
      tree  <- liftIO $ readIORef (ruleSet xunit)
      return $
        ActionGroup
        { actionExecUnit = xunit
          -- (\o -> trace ("matched: "++show (map (\ (a,_,_) -> a) o)) o) $ 
        , getActionList = flip concatMap (matchTree False tree tox) $ \ (patn, mtch, execs) ->
            flip map execs $ \exec -> seq exec $! seq instr $! seq patn $! seq mtch $!
              Action
              { actionQuery      = Just instr
              , actionPattern    = Just patn
              , actionMatch      = mtch
              , actionCodeBlock  = exec
              }
        }

-- | When executing strings against Dao programs (e.g. using 'Dao.Tasks.execInputString'), you often
-- want to execute the string against only a subset of the number of total programs. Pass the
-- logical names of every module you want to execute strings against, and this function will return
-- them.
selectModules :: [UStr] -> Exec [ExecUnit]
selectModules names = do
  xunit <- ask
  ax <- case names of
    []    -> liftIO $ readMVar (pathIndex xunit)
    names -> do
      pathTab <- liftIO $ readMVar (pathIndex xunit)
      let set msg           = M.fromList . map (\mod -> (toUStr mod, error msg))
          request           = set "(selectModules: request files)" names
      return (M.intersection pathTab request)
  return (M.elems ax)

-- | Like 'execStringQueryWith', but executes against every loaded module.
execStringQuery :: UStr -> Exec ()
execStringQuery instr =
  asks pathIndex >>= liftIO . fmap M.elems . readMVar >>= execStringQueryWith instr

-- | This is the most important function in the Dao universe. It executes a string query with the
-- given module 'ExecUnit's. The string query is executed in each module, execution in each module
-- runs in it's own thread. This function is syncrhonous; it blocks until all threads finish
-- working.
execStringQueryWith :: UStr -> [ExecUnit] -> Exec ()
execStringQueryWith instr xunitList = do
  task <- asks taskForExecUnits
  liftIO $ taskLoop_ task $ flip map xunitList $ \xunit -> do
    result <- flip ioExec xunit $ makeActionsForQuery instr >>= execute
    -- TODO: this case statement should really call into some callback functions installed into the
    -- root 'ExecUnit'.
    case result of
      PFail (ExecReturn{}) -> return ()
      PFail err            -> liftIO $ hPutStrLn stderr (prettyShow err)
      Backtrack            -> case programModuleName xunit of
        Nothing   -> return ()
        Just name -> liftIO $ hPutStrLn stderr $ '(' : uchars name ++ ": does not compute)"
      OK                _  -> return ()

-- | Runs a single line of Dao scripting language code. In the current thread parse an input string
-- of type 'Dao.Evaluator.ScriptExpr' and then evaluate it. This is used for interactive evaluation.
-- The parser used in this function will parse a block of Dao source code, the opening and closing
-- curly-braces are not necessary. Therefore you may enter a semi-colon separated list of commands
-- and all will be executed.
evalScriptString :: String -> Exec ()
evalScriptString instr =
  void $ execNested T.Void $ mapM_ execute $
    case parse (daoGrammar{mainParser = concat <$> (many script <|> return [])}) mempty instr of
      Backtrack -> error "cannot parse expression"
      PFail tok -> error ("error: "++show tok)
      OK   expr -> concatMap toInterm expr

-- | Evaluates the @EXIT@ scripts for every presently loaded dao program, and then clears the
-- 'Dao.Object.pathIndex', effectively removing every loaded dao program and idea file from memory.
daoShutdown :: Exec ()
daoShutdown = do
  idx <- asks pathIndex
  liftIO $ modifyMVar_ idx $ (\_ -> return (M.empty))
  xunits <- liftIO $ fmap M.elems (readMVar idx)
  forM_ xunits $ \xunit -> local (const xunit) $ asks quittingTime >>= mapM_ execute

