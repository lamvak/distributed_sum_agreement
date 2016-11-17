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

data OtpInstruction = Ping | NoMorePings ProcessId
  deriving (Typeable, Generic)
instance Binary OtpInstruction

data OtpSlaveResponse = NoMorePingsAck
  deriving (Typeable, Generic)
instance Binary OtpSlaveResponse

slaveAction :: OtpInstruction -> Process ()
slaveAction instruction = getSelfPid >>= ((flip slaveAction' instruction) . show)

slaveAction' :: String -> OtpInstruction -> Process ()
slaveAction' selfPid Ping = say $ "PONG! (from " ++ selfPid ++ ")"
slaveAction' selfPid (NoMorePings masterPid) = do
  say $ "ACK for NoMorePings from " ++ selfPid
  send masterPid NoMorePingsAck

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
  slaveProcIds <- mapM spawnSlave slaves
  let pings = take 100 . cycle $ slaveProcIds in do
    sequence $ map (\slavePID -> send slavePID Ping) pings
  selfPid <- getSelfPid
  sequence $ flip map slaveProcIds $ \pid -> send pid $ NoMorePings selfPid
  sequence $ flip map slaveProcIds $ \_ -> receiveWait [ match ((\_ -> return ()) :: OtpSlaveResponse -> Process()) ]
  liftIO . putStrLn $ "done waiting for slaves - terminating"
  -- Terminate the slaves when the master terminates (this is optional)
  terminateAllSlaves backend

main :: IO ()
main = do
  args <- getArgs
  putStrLn $ "Application run with following args: " ++ (show args)
  case args of
    ["master", host, port] -> do
      putStrLn $ "Starting master at " ++ host ++ ":" ++ port
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      liftIO $ threadDelay 100000
      startMaster backend (master backend)
    ["slave", host, port] -> do
      putStrLn $ "Starting slave at " ++ host ++ ":" ++ port
      backend <- initializeBackend host port (__remoteTable initRemoteTable)
      startSlave backend