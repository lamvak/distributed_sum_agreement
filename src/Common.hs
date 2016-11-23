{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
module Common where

import Data.Binary
import Control.Distributed.Process
import Control.Distributed.Process.ManagedProcess
import qualified Data.Map.Strict as Map
import Data.Hashable
import Data.Typeable (Typeable)
import GHC.Generics
import qualified Data.HashTable.IO as H

data OtpInputMessage = OtpInputMessage ProcessId Integer Double
  deriving (Typeable, Generic, Show, Eq)
instance Binary OtpInputMessage
instance Hashable OtpInputMessage

--                             Original payload, Exchange sender
data OtpExchangeMessage = XMsg OtpInputMessage   ProcessId
                        | Ack  OtpInputMessage   ProcessId
                        | Neighbours [ProcessId]
                        | Resend
  deriving (Typeable, Generic, Show)
instance Binary OtpExchangeMessage

data OtpControlMessage = DumpState | StopGenerating
  deriving (Typeable, Generic, Show)
instance Binary OtpControlMessage

askForState :: ProcessId -> Process ()
askForState pid = cast pid DumpState

type HashTable k v = H.BasicHashTable k v
type HashSet k = H.BasicHashTable k ()

type ExchangeManagerInputAction a = a -> OtpInputMessage -> Process (ProcessAction a)
type ExchangeManagerExchangeAction a = a -> OtpExchangeMessage-> Process (ProcessAction a)
-- type ExchangeManagerControlAction a = (a -> String) -> a -> OtpControlMessage -> Process (ProcessAction a)

data ExchangeState = ExchangeState { known :: HashTable OtpInputMessage [ProcessId]
                                   , exchanges :: [ProcessId]
                                   }


type SimpleState = (Integer, Double)
type StateKey = (Integer, ProcessId)
type StateItem = (StateKey, Double)
type ListState = [StateItem]
type TreeState = Map.Map StateKey Double

type StateManagerInputAction a = a -> OtpInputMessage -> Process (ProcessAction a)
type StateManagerControlAction a = (a -> String) -> a -> OtpControlMessage -> Process (ProcessAction a)
