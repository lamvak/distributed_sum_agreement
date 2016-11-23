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
import Data.Typeable (Typeable)
import OtpProtocol
import GHC.Generics
import Lib
import State
import System.Environment (getArgs)
import System.IO
import System.Random (mkStdGen, setStdGen)
import Simulation


remotable ['runOptimisticStateManager, 'optimisticInputGenerator]

spawnOptimisticInputGenerator :: [ProcessId] -> NodeId -> Process ProcessId
spawnOptimisticInputGenerator consumers node = do
  say "spawning input generator(1)"
  spawn node $ $(mkClosure 'optimisticInputGenerator) consumers

spawnOptimisticServer :: NodeId -> Process ProcessId
spawnOptimisticServer node = spawn node $ $(mkStaticClosure 'runOptimisticStateManager)

master :: Int -> Int -> SimulationModel -> Backend -> [NodeId] -> Process ()
master sendFor waitFor (SimulationModel stateModel genModel) backend slaves = do
  selfPid <- getSelfPid
  say $ "Starting master: " ++ (show selfPid)
  say $ "Slaves: " ++ (show slaves)
  stateManagers <- sequence $ map spawnOptimisticServer slaves
  say $ "State managers: " ++ (show stateManagers)
  inputGenerators <- let spawner = spawnOptimisticInputGenerator stateManagers in
--    sequence $ map spawner slaves
    sequence $ map spawner $ [minimum slaves]
  say $ "input generators: " ++ (show inputGenerators)
  liftIO $ threadDelay (sendFor * 1000000)
  mapM_ (flip exit $ "sendFor timeout reached") inputGenerators
  liftIO $ threadDelay 500000
  mapM_ (flip kill $ "sendFor timeout +0.5s reached - killing generators") inputGenerators
  liftIO $ threadDelay $ max 0 ((waitFor -1) * 1000000)
  say "Asking state managers to dump state"
  sequence $ map askForState stateManagers
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
