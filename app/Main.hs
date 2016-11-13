{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Monad
import Data.Typeable
import Data.Binary
import GHC.Generics
import Lib
import System.Environment (getArgs)

data OtpInstruction = Quit | Ping
  deriving (Typeable, Generic)

instance Binary OtpInstruction

slaveAction :: OtpInstruction -> Process ()
slaveAction Ping = do
  selfNode <- getSelfNode
  say $ "PONG! (from " ++ (show selfNode) ++ ")"
  return ()
slaveAction Quit = terminate

slaveLoop :: Process ()
slaveLoop = do
  selfNode <- getSelfNode
  liftIO $ putStrLn . ("Starting slave " ++) . show $ selfNode
  forever $ do
    receiveWait [
      match slaveAction,
      matchAny (\_ -> return ())
      ]

remotable ['slaveLoop]

spawnSlave :: NodeId -> Process ProcessId
spawnSlave node = spawn node $ $(mkStaticClosure 'slaveLoop)

master :: Backend -> [NodeId] -> Process ()
master backend slaves = do
  -- Do something interesting with the slaves
  liftIO . putStrLn $ "Slaves: " ++ show slaves
  slaveProcIds <- return . sequence $ map spawnSlave slaves
  redirectLogsHere backend <$> slaveProcIds
  pings <- (take 16) . cycle <$> slaveProcIds
  liftIO $ putStrLn $ "Pings: " ++ (show pings)
  sequence $ map (\slavePID -> send slavePID Ping) pings
  liftIO $ threadDelay 1000000
  -- Terminate the slaves when the master terminates (this is optional)
  terminateAllSlaves backend

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["master", host, port] -> do
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      startMaster backend (master backend)
    ["slave", host, port] -> do
      putStrLn $ "Starting slave at " ++ host ++ ":" ++ port
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      startSlave backend