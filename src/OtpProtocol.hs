{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module OtpProtocol where

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
import qualified Data.HashTable.IO as H
import Data.List
import Data.Ord
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.ManagedProcess

runExchangeManager :: Process ()
runExchangeManager = do
  selfPid <- getSelfPid
  say $ "Running exchange manager " ++ (show selfPid)
  timer <- liftIO $ forkIO $ forever $ do
    threadDelay 400000
    putStrLn $ "(STDOUT) TICK! from " ++ (show selfPid)
    _ <- return $ do
      say $ "TICK! from " ++ (show selfPid)
      cast selfPid Resend
    return ()
  serve () initExchangeState $ defaultProcess {
    apiHandlers = [
        handleCast exchangeAction
      , handleCast exchangeInputAction
      -- TODO: kill timer on handleShutdown
    ]
  , unhandledMessagePolicy = Log
  , timeoutHandler = \s _ -> (say $ "timeout") >> continue s
  , shutdownHandler = \_ _ -> do
      say $ "shutting down server " ++ (show selfPid)
      return ()
  }
  say $ "exchange manager " ++ (show selfPid) ++ " finished"

initExchangeState :: InitHandler () ExchangeState
initExchangeState _ = do
  ht <- liftIO H.new
  return $ InitOk (ExchangeState{exchanges=[],known=ht,stateMgr=Nothing}) Infinity

-- exchangeInputAction :: ExchangeState -> OtpInputMessage -> Process (ProcessAction a)
exchangeInputAction :: ExchangeManagerInputAction ExchangeState
exchangeInputAction state input = do
  say "exchangeInputAction"
  handle state input
  continue state

-- exchangeInputAction :: ExchangeState -> OtpExchangeMessage -> Process (ProcessAction a)
exchangeAction :: ExchangeManagerExchangeAction ExchangeState
exchangeAction state exchange@(XMsg input _) = do
  say "XMsg"
  liftIO $ putStrLn "XXXMsg"
  acknowledge exchange
  handle state input
  continue $ state
exchangeAction state exchange@(Ack _ _) = do
  say "Ack"
  liftIO $ putStrLn "AAAck"
  removeWaitingForAck state exchange
  continue state
exchangeAction state (Neighbours pids) = do
  say "Neigh"
  liftIO $ putStrLn "NNNeigh"
  selfPid <- getSelfPid
  continue $ state {exchanges=(delete selfPid pids)}
exchangeAction state (PairWith pid master) = do
  selfPid <- getSelfPid
  say $ (show selfPid) ++ " pairing up with state manager " ++ (show pid)
  cast master (PairingAck selfPid)
  continue $ state {stateMgr=Just pid}
exchangeAction state Resend = do
  say "Resend"
  liftIO $ putStrLn "RRResend"
  advertiseAll state
  continue state

handle :: ExchangeState -> OtpInputMessage -> Process ExchangeState
handle state@(ExchangeState{known=pending}) input = do
  selfPid <- getSelfPid
  say $ (show selfPid) ++ " handling " ++ (show input)
  known <- liftIO $ H.lookup pending input
  maybe (markAsKnownAndAdvertise state input) (\_ -> return state) known

markAsKnownAndAdvertise :: ExchangeState -> OtpInputMessage -> Process ExchangeState
markAsKnownAndAdvertise state@(ExchangeState{exchanges=others,stateMgr=maybeMgr}) input = do
    selfPid <- getSelfPid
    maybe (return ()) (\pid -> do say $ (show selfPid) ++ " casting input to mgr " ++ (show pid)
                                  cast pid input) maybeMgr
    advertise selfPid (input, others)
    addPendingForAck state input
    return state

advertiseAll :: ExchangeState -> Process ExchangeState
advertiseAll state@(ExchangeState{known=pending}) = do
  selfPid <- getSelfPid
  let advertiseAction = return . (advertise selfPid) in
    liftIO $ H.mapM_ advertiseAction pending
  return state

advertise :: ProcessId -> (OtpInputMessage, [ProcessId]) -> Process ()
advertise selfPid (input, others) = do
  sequence $ map (\pid -> cast pid $ XMsg input selfPid) others
  return ()

acknowledge :: OtpExchangeMessage -> Process ()
acknowledge (XMsg input sender) = do
  selfPid <- getSelfPid
  cast sender (Ack input selfPid)

addPendingForAck :: ExchangeState -> OtpInputMessage -> Process ExchangeState
addPendingForAck state@(ExchangeState{known=pending, exchanges=others}) input = do
  liftIO $ H.insert pending input others
  return state

removeWaitingForAck :: ExchangeState -> OtpExchangeMessage -> Process ()
removeWaitingForAck state@(ExchangeState{known=pending}) (Ack input sender) = do
  pendingPids <- liftIO $ H.lookup pending input
  maybe (return ()) (\pendingPids -> liftIO $ H.insert pending input (delete sender pendingPids)) pendingPids
