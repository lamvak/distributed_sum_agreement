{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module State where

import Common
import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Extras (ExitReason(ExitNormal))
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.Node
import Control.Monad
import Data.Binary
import Data.List
import Data.Ord
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import GHC.Generics

-- State Manager: manage state
stateManagerControlAction :: StateManagerControlAction a
stateManagerControlAction stateFormatter state DumpState = do
  selfPid <- getSelfPid
  say $ "stateManagerControlAction " ++ (show selfPid) ++ ": " ++ (stateFormatter state)
  continue state

runStateManager :: StateManagerInputAction a -> (a -> String) -> b -> (InitHandler b a) -> Process ()
runStateManager inputAction stateFormatter argv init = do
  say "in runStateManager"
  selfPid <- getSelfPid
  serve argv init $ defaultProcess {
    apiHandlers = [
            handleCast $ stateManagerControlAction stateFormatter
          , handleCast inputAction
    ]
  , unhandledMessagePolicy = Log
  , timeoutHandler = \s _ -> (say $ "timeout") >> continue s
  , shutdownHandler = \_ _ -> do
      selfPid <- getSelfPid
      say $ "shutting down server " ++ (show selfPid)
      return ()
  }
  say $ "Server terminated: StateManager at " ++ (show selfPid)

-- Optimistic State Manager - assume all messages come through, no duplicates, no reordering, etc.
optimisticInputAction :: StateManagerInputAction SimpleState
optimisticInputAction state (OtpInputMessage _ _ input) = do
  selfPid <- getSelfPid
  say $ "optimisticInputAction " ++ (show selfPid)
  let i = fst state in continue (i+1, input * (fromInteger i) + (snd state))

runOptimisticStateManager :: Process ()
runOptimisticStateManager = do
  runStateManager optimisticInputAction show () (\_ -> do
    selfPid <- getSelfPid
    say $ "initializing " ++ (show selfPid)
    return $ InitOk (0, 0.0) Infinity
    )

-- List State Manager - assume duplicates, reordering, etc; use sorted list as state model
listStateInputAction :: StateManagerInputAction ListState
listStateInputAction state (OtpInputMessage pid timestamp value) = do
  continue $ insertBy ((flip $ compare . fst) . fst) ((timestamp, pid), value) state

-- TODO: better yet! keep the result with the head of the list
listStateDump' :: ListState -> (Int, Double)
listStateDump' [] = (0, 0)
listStateDump' (item:items) =
  let (i, res) = listStateDump' items
      j = i + 1
  in (j, (fromIntegral j)* (snd item))
listStateDump :: ListState -> String
listStateDump = show . listStateDump'

runListStateManager :: Process ()
runListStateManager = do
  runStateManager listStateInputAction listStateDump () (\_ -> return $ InitOk [] Infinity)

-- TODO: handle duplicates on isnert rather than dump state
-- TODO: better impl of BST (own?) - toList / toAscList should be just O(n)!
-- Tree State Manager - assume duplicates, reordering, etc; use BST as state model
treeStateInputAction :: StateManagerInputAction TreeState
treeStateInputAction state (OtpInputMessage pid timestamp value) = do
  continue $ Map.insert (timestamp, pid) value state

treeStateDump' :: Int -> Double -> [StateItem] -> (Int, Double)
treeStateDump' i acc [] = (i, acc)
treeStateDump' i acc ((_, value):state) =
  let j = i + 1 in
    treeStateDump' (j) (acc + (fromIntegral j) * value) state

treeStateDump :: TreeState -> String
treeStateDump state = show $ treeStateDump' 0 0 $ Map.toAscList state

runTreeStateManager :: Process ()
runTreeStateManager = do
  runStateManager treeStateInputAction treeStateDump () (\_ -> return $ InitOk Map.empty Infinity)

-- TODO: implement dynamic state manager: using trees and lists / operations enriched with stats,
-- dynamically switch between lists (late inserts rate drops significantly) and tree (late inserts
-- rate raises significantly) state implementation -> requires input action dispatching input
-- message based on current state type

