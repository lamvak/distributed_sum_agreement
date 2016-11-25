{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Simulation where

import Common
--import Control.Concurrent
import Control.Concurrent.Lifted
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Extras (ExitReason(ExitNormal))
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.ManagedProcess
import Control.Distributed.Process.MonadBaseControl
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
import System.Random

-- Input Generator: generate input and send out to state managers
inputGenerator :: IO Delay -> IO () -> [ProcessId] -> Process ()
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
--    liftIO $ sequence $ (flip map) consumers $ (\pid -> forkIO $ do
    sequence $ (flip map) consumers $ (\pid -> fork $ do
      delay <- liftIO sendDelay
      case delay of
        Delay x -> do
          threadDelay (asTimeout x)
          say $ "Sending " ++ (show input) ++ " with delay of " ++ (show $ asTimeout x)
          cast pid $ OtpInputMessage selfPid timeStamp input
          say $ ">> " ++ (show input) ++ " sent"
        NoDelay -> do
          say $ "Sending " ++ (show input) ++ " without delay"
          cast pid $ OtpInputMessage selfPid timeStamp input
          say $ ">> " ++ (show input) ++ " sent"
        Infinity -> do
          say $ "Skipping " ++ (show input) ++ " (INFINITE delay)"
      )

optimisticInputGenerator :: [ProcessId] -> Process ()
optimisticInputGenerator = inputGenerator noDelay iterationDelayer

finDelaysInputGenerator :: [ProcessId] -> Process ()
finDelaysInputGenerator = inputGenerator finDelayer iterationDelayer

infDelaysInputGenerator :: [ProcessId] -> Process ()
infDelaysInputGenerator = inputGenerator infDelayer iterationDelayer

iterationDelayer :: IO ()
iterationDelayer = threadDelay 300000

noDelay :: IO Delay
noDelay = return NoDelay

finDelayer :: IO Delay
finDelayer = do
  r <- randomIO :: IO Int
  return $ Delay $ microSeconds $ 100 * (r `mod` 40000)

infDelayer :: IO Delay
infDelayer = do
  r <- randomIO :: IO Int
  if r `mod` 1000 < 3 then return Infinity else finDelayer