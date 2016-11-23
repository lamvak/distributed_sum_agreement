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
    threadDelay 250
    _ <- return $ cast selfPid Resend
    return ()
  serve () initExchangeState defaultProcess {
    apiHandlers = [
        handleCast exchangeInputAction
      , handleCast exchangeInputAction
      -- TODO: kill timer on handleShutdown
    ]
  , unhandledMessagePolicy = Log
  }

initExchangeState :: InitHandler () ExchangeState
initExchangeState _ = do
  ht <- liftIO H.new
  return $ InitOk (ExchangeState{exchanges=[],known=ht}) Infinity

-- exchangeInputAction :: ExchangeState -> OtpInputMessage -> Process (ProcessAction a)
exchangeInputAction :: ExchangeManagerInputAction ExchangeState
exchangeInputAction state input = do
  handle state input
  continue state

-- exchangeInputAction :: ExchangeState -> OtpExchangeMessage -> Process (ProcessAction a)
exchangeAction :: ExchangeManagerExchangeAction ExchangeState
exchangeAction state exchange@(XMsg input _) = do
  acknowledge exchange
  handle state input
  continue $ state
exchangeAction state exchange@(Ack _ _) = do
  _ <- liftIO $ removeWaitingForAck state exchange
  continue state
exchangeAction state (Neighbours pids) = do
  selfPid <- getSelfPid
  continue $ state {exchanges=(delete selfPid pids)}
exchangeAction state Resend = do
  advertiseAll state
  continue state

handle :: ExchangeState -> OtpInputMessage -> Process ExchangeState
handle state@(ExchangeState{known=pending}) input = do
  known <- liftIO $ H.lookup pending input
  maybe (markAsKnownAndAdvertise state input) (\_ -> return state) known

markAsKnownAndAdvertise :: ExchangeState -> OtpInputMessage -> Process ExchangeState
markAsKnownAndAdvertise state@(ExchangeState{exchanges=others}) input = do
    selfPid <- getSelfPid
    liftIO $ do
      advertise selfPid (input, others)
      addPendingForAck state input
    return state

advertiseAll :: ExchangeState -> Process ExchangeState
advertiseAll state@(ExchangeState{known=pending}) = do
  selfPid <- getSelfPid
  liftIO $ H.mapM_ (advertise selfPid) pending
  return state

advertise :: ProcessId -> (OtpInputMessage, [ProcessId]) -> IO ()
advertise selfPid (input, others) = do
  _ <- return $ sequence $ map (\pid -> cast pid $ XMsg input selfPid) others
  return ()

acknowledge :: OtpExchangeMessage -> Process ()
acknowledge (XMsg input sender) = do
  selfPid <- getSelfPid
  cast sender (Ack input selfPid)

addPendingForAck :: ExchangeState -> OtpInputMessage -> IO ExchangeState
addPendingForAck state@(ExchangeState{known=pending, exchanges=others}) input = do
  H.insert pending input others
  return state

removeWaitingForAck :: ExchangeState -> OtpExchangeMessage -> IO ()
removeWaitingForAck state@(ExchangeState{known=pending}) (Ack input sender) = do
  pendingPids <- H.lookup pending input
  maybe (return ()) (\pendingPids -> H.insert pending input (delete sender pendingPids)) pendingPids
  return ()