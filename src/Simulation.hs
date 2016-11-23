{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Simulation where

import Common
import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Extras (ExitReason(ExitNormal))
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.Node
import Control.Monad
--import Control.Monad.Trans.Class
import Data.Binary
import Data.List
import Data.Ord
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import OtpProtocol
import GHC.Generics
import Lib

-- Input Generator: generate input and send out to state managers
inputGenerator :: IO () -> IO () -> [ProcessId] -> Process ()
inputGenerator sendDelay iterationDelay consumers = do
  liftIO $ putStrLn "foo"
  say "bar"
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


