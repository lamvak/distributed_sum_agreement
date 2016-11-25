{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Common
import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Extras (ExitReason(ExitNormal))
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.Node
import Control.Monad
import Control.Monad.Trans.Class
import Data.Binary
import Data.List
import Data.Typeable (Typeable)
import OtpProtocol
import GHC.Generics
import Lib
import State
import System.Environment (getArgs)
import System.IO
import System.Random (mkStdGen, setStdGen)
import Simulation


procKiller :: ProcessId -> Process ()
procKiller pid = do
  say $ "Sending kill signal to " ++ (show pid)
  kill pid  "sendFor timeout +0.5s reached - killing generators"
  say $ (show pid) ++ "should be killed now"

remotable ['runOptimisticStateManager, -- State Managers [managed]
           'runListStateManager,
           'runTreeStateManager,
           'runExchangeManager,        -- Exchange Managers [managed]
           'optimisticInputGenerator,  -- Simulation input generators
           'finDelaysInputGenerator,
           'infDelaysInputGenerator,
           'procKiller]

spawnOptimisticInputGenerator :: [ProcessId] -> NodeId -> Process ProcessId
spawnOptimisticInputGenerator consumers node = do
  say "spawning optimisticInputGenerator"
  spawn node $ $(mkClosure 'optimisticInputGenerator) consumers

spawnFinDelaysInputGenerator :: [ProcessId] -> NodeId -> Process ProcessId
spawnFinDelaysInputGenerator consumers node = do
  say "spawning finDelaysInputGenerator"
  spawn node $ $(mkClosure 'finDelaysInputGenerator) consumers

spawnInfDelaysInputGenerator :: [ProcessId] -> NodeId -> Process ProcessId
spawnInfDelaysInputGenerator consumers node = do
  say "spawning infDelaysInputGenerator"
  spawn node $ $(mkClosure 'infDelaysInputGenerator) consumers

spawnGenerators :: GenModel -> [NodeId] -> [ProcessId] -> Process [(NodeId, ProcessId)]
spawnGenerators OneGen slaves stateMgrs = spawnGenerators MultiGen [minimum slaves] stateMgrs
spawnGenerators MultiGen slaves stateMgrs = do
  generators <- sequence $ map (\node -> (spawnOptimisticInputGenerator stateMgrs node >>= return  . ((,) node))) slaves
  say $ "Generators: " ++ (show generators)
  return generators
spawnGenerators FinDelays slaves stateMgrs = do
  generators <- sequence $ map (\node -> (spawnFinDelaysInputGenerator stateMgrs node >>= return . ((,) node))) slaves
  say $ "Generators: " ++ (show generators)
  return generators
spawnGenerators InfDelays slaves stateMgrs = do
  generators <- sequence $ map (\node -> (spawnInfDelaysInputGenerator stateMgrs node >>= return . ((,) node))) slaves
  say $ "Generators: " ++ (show generators)
  return generators

spawnSlaveWorkers :: StateModel -> [NodeId] -> Process [(NodeId,ProcessId)]
spawnSlaveWorkers Simple slaves = do
  sequence $ map (\node -> do pid <- spawn node $ $(mkStaticClosure 'runOptimisticStateManager)
                              return (node, pid)) slaves
spawnSlaveWorkers Tree slaves = do
  sequence $ map (\node -> do pid <- spawn node $ $(mkStaticClosure 'runTreeStateManager)
                              return (node, pid)) slaves
spawnSlaveWorkers List slaves = do
  sequence $ map (\node -> do pid <- spawn node $ $(mkStaticClosure 'runListStateManager)
                              return (node, pid)) slaves
spawnSlaveWorkers Dynamic _ = do
  say "Dynamic state switch not implemented yet"
  return []

spawnExchangeServers :: [NodeId] -> Process [(NodeId,ProcessId)]
spawnExchangeServers slaves = do
  exchanges <- sequence $ map (\node -> do pid <- spawn node $ $(mkStaticClosure 'runExchangeManager)
                                           return (node, pid)) slaves
  let pids = map snd exchanges in
    sequence $ map (\pid -> cast pid (Neighbours pids)) pids
  return exchanges

-- ofc, should synchronize rather than delay like below, but that would be the next step
master :: Int -> Int -> SimulationModel -> Backend -> [NodeId] -> Process ()
master sendFor waitFor (SimulationModel stateModel genModel) backend slaves = do
  selfPid <- getSelfPid
  say $ "Starting master: " ++ (show selfPid)
  say $ "Slaves: " ++ (show slaves)
  stateManagers <- spawnSlaveWorkers stateModel slaves
  say $ "State managers: " ++ (show stateManagers)
  exchanges <- spawnExchangeServers slaves
  say $ "Exchanges: " ++ (show exchanges)
  liftIO $ threadDelay 1000000
  let bindings = zip (map snd $ sortOn fst stateManagers) (map snd $ sortOn fst exchanges) in do
    say $ "bindings: " ++ (show bindings)
    sequence $ map (\(sm, ex) -> cast ex $ PairWith sm selfPid) bindings
  say "Pairing requests sent"
  liftIO $ threadDelay 2000000
  say "Starting generators"
  inputGenerators <- spawnGenerators genModel slaves (map snd exchanges)
  say $ "Generators: " ++ (show inputGenerators)
  liftIO $ threadDelay (sendFor * 1000000)
  say "Exiting generators"
  sequence $ map (\(node, pid) -> exit pid "sendFor timeout reached") inputGenerators
  liftIO $ threadDelay 500000
  say "Killing generators"
  sequence $ map (\(node, pid) -> spawn node $ $(mkClosure 'procKiller) pid) inputGenerators
  liftIO $ threadDelay $ max 0 ((waitFor -1) * 1000000)
  say "Asking state managers to dump state"
  sequence $ map (askForState . snd) stateManagers
  liftIO $ threadDelay 500000
  say "done waiting for state managers to dump state; to secure most abrupt deadline, kill slaves"
  terminateAllSlaves backend
  say "master terminating"


main :: IO ()
main = do
  argv <- getArgs
  maybe usage runApp $ parseArgs argv

runApp :: RunParams -> IO ()
runApp params@(MasterParams{ host=host, port=port,
                             rngSeed=seed, sendFor=sendFor,
                             waitFor=waiting,
                             simulationModel=simulationModel}) = do
  backend <- initApp "Master" host port seed
  threadDelay 500000
  startMaster backend $ master sendFor waiting simulationModel backend
runApp params@(SlaveParams{host=host, port=port, rngSeed=seed}) = do
  backend <- initApp "Slave" host port seed
  startSlave backend

initApp :: String -> String -> String -> Int -> IO Backend
initApp mode host port seed = do
  setStdGen $ mkStdGen seed
  dbgStr $ "Starting " ++ mode ++ " at " ++ host ++ ":" ++ port
  initializeBackend host port (__remoteTable initRemoteTable)

dbgStr :: String -> IO ()
dbgStr = hPutStrLn stderr
