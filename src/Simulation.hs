{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Simulation where

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
    liftIO $ sequence_ $ (flip map) consumers $ \pid -> forkIO $ do
      delay <- sendDelay
      let doSend = cast pid $ OtpInputMessage selfPid timeStamp input in
        case delay of
          Delay x -> do
            threadDelay (asTimeout x)
            _ <- return doSend
            return ()
          NoDelay -> do
            _ <- return doSend
            return ()
          Infinity -> return () -- Infinite delay = just skip the message

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