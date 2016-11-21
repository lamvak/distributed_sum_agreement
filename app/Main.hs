{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Extras (ExitReason(ExitNormal))
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.Node
import Control.Monad
import Control.Monad.Trans.Class
import Data.Binary
import Data.Typeable (Typeable)
import Data.Time.Clock.POSIX
import GHC.Generics
import Lib
import System.Environment (getArgs)
import System.IO
import System.Random (mkStdGen, setStdGen)

now :: IO Integer
now = do
  time <- getPOSIXTime
  return $ round $ time * 1000.0

data OtpInputMessage = OtpInputMessage ProcessId Integer Double
  deriving (Typeable, Generic)
instance Binary OtpInputMessage

data OtpControlMessage = DumpState | StopGenerating | Quit
  deriving (Typeable, Generic)
instance Binary OtpControlMessage

type SimpleState = (Integer, Double)
type DuplicatesHandlingState = ([Integer], Double)

type StateManagerInputAction a = a -> OtpInputMessage -> Process (ProcessAction a)
type StateManagerControlAction a = (a -> String) -> a -> OtpControlMessage -> Process (ProcessAction a)

-- State Manager: manage state of the application
stateManagerControlAction :: StateManagerControlAction a
stateManagerControlAction stateFormatter state DumpState = do
  selfPid <- getSelfPid
  say $ "stateManagerControlAction " ++ (show selfPid) ++ ": " ++ (stateFormatter state)
  continue state
stateManagerControlAction _ state Quit = stop ExitNormal

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

-- Optimistic State Manager - assume all messages come through, no duplicates, no reordering, no adversaries
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


-- Input Generator: generate input and send out to state managers
inputGenerator :: IO () -> IO () -> [ProcessId] -> Process ()
inputGenerator sendDelay iterationDelay consumers = do
  selfPid <- getSelfPid
  say $ "starting generator " ++ (show selfPid)
  forever $ do
    say $ "iteration of " ++ (show selfPid)
    liftIO iterationDelay
    timeStamp <- liftIO now
    input <- liftIO otpRandIO
    say $ (show selfPid) ++ " sending out " ++ (show input) ++
         " at " ++ (show timeStamp) ++ " to " ++ (show consumers)
    sequence_ $ (flip map) consumers $ \pid -> do
        liftIO sendDelay
        cast pid $ OtpInputMessage selfPid timeStamp input

optimisticInputGenerator :: [ProcessId] -> Process ()
optimisticInputGenerator = inputGenerator (return ()) (threadDelay 300000)

remotable ['runOptimisticStateManager, 'optimisticInputGenerator]

spawnOptimisticInputGenerator :: [ProcessId] -> NodeId -> Process ProcessId
spawnOptimisticInputGenerator consumers node = spawn node $ $(mkClosure 'optimisticInputGenerator) consumers

spawnOptimisticServer :: NodeId -> Process ProcessId
spawnOptimisticServer node = spawn node $ $(mkStaticClosure 'runOptimisticStateManager)

askForState :: ProcessId -> Process ()
askForState pid = cast pid DumpState

requestStop :: ProcessId -> Process ()
requestStop pid = cast pid Quit

master :: Int -> Int -> Backend -> [NodeId] -> Process ()
master sendFor waitFor backend slaves = do
  selfPid <- getSelfPid
  say $ "Starting master: " ++ (show selfPid)
  say $ "Slaves: " ++ (show slaves)
  stateManagers <- sequence $ map spawnOptimisticServer slaves
  say $ "State managers: " ++ (show stateManagers)
  inputGenerators <- let spawner = spawnOptimisticInputGenerator stateManagers in
    sequence $ map spawner slaves
  liftIO $ threadDelay 500000
  say "Asking state managers to dump state"
  sequence $ map askForState stateManagers
  liftIO $ threadDelay 2000000
  say "done waiting for state managers to dump state; requesting state managers to stop"
  sequence $ map requestStop stateManagers
  liftIO $ threadDelay 2000000
  say "done waiting for state managers to stop"
  terminateAllSlaves backend

main :: IO ()
main = do
  argv <- getArgs
  maybe usage runApp $ parseArgs argv

runApp :: RunParams -> IO ()
runApp (RunParams mode host port seed sendFor waitFor) = do
  setStdGen $ mkStdGen seed
  dbgStr $ "Starting " ++ (show mode) ++ " at " ++ host ++ ":" ++ port
  backend <- initializeBackend host port (__remoteTable initRemoteTable)
  case mode of
    Master -> threadDelay 500000 >> (startMaster backend $ master sendFor waitFor backend)
    Slave -> startSlave backend

dbgStr :: String -> IO ()
dbgStr = hPutStrLn stderr
