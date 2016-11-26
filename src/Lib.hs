module Lib
    ( otpRand,
      otpRand', -- preferably, would keep this one private but easiest tactical for testing in separation from real RNG
      otpRandIO,
      RunMode(Master,Slave),
      RunParams(MasterParams, SlaveParams),
      StateModel(..),
      GenModel(..),
      SimulationModel(..),
      parseArgs,
      usage,
      now,
      host,
      port,
      rngSeed,
      sendFor,
      waitFor,
      simulationModel
    ) where

import Control.Distributed.Process.Extras.Time
import Data.Time.Clock.POSIX
import System.Random
import Text.Heredoc
import OtpProtocol

now :: IO Integer
now = do
  time <- getPOSIXTime
  return $ round $ time * 1000.0

otpRandCorrection :: Double -> Double
otpRandCorrection d = if d == 0 then 1 else d

otpRand :: RandomGen g => g -> (Double, g)
otpRand = otpRand' . random

otpRand' :: RandomGen g => (Double, g) -> (Double, g)
otpRand' (d, g) = (otpRandCorrection d, g)

otpRandIO :: IO Double
otpRandIO = otpRandCorrection <$> randomIO

-- What to do now?
-- Running state modification: lists or trees (or dynamic) for low reordering vs high reordering
-- Protocol for information exchange: see somthing, share (and reshare until you get explicit ACK);
--   all inputs shared (and ACKed) to all other participants -> communication: O(#Msgs * #workers^2 * avg#resendsPerMessage)
-- O(#Msgs * #workers^2 * #"rounds")
-- Protocol for data synch (i.e. after long network break) - Merkle lists or Merkle trees synch
-- Kinds of errors: stopping (processors breaks, network breaks), messagees delays; Byzantine faults?

-- Commandline parameters parsing
data RunMode = Master | Slave
  deriving (Show)

data StateModel = Simple | Tree | List | Dynamic
  deriving (Show, Read)

data GenModel = OneGen | MultiGen | FinDelays | InfDelays
  deriving (Show, Read)

data SimulationModel = SimulationModel StateModel GenModel
  deriving (Show)

simulatonFrom :: String -> String -> SimulationModel
simulatonFrom stateModel genModel = SimulationModel (read stateModel) (read genModel)

data RunParams = MasterParams { host :: String
                              , port :: String
                              , rngSeed :: Int
                              , sendFor :: Int
                              , waitFor :: Int
                              , simulationModel :: SimulationModel
                              }
               | SlaveParams { host :: String
                             , port :: String
                             , rngSeed :: Int
                             }
  deriving (Show)

data IncompleteRunParams = IRP { mRunMode :: Maybe RunMode
                               , mHost :: Maybe String
                               , mPort :: Maybe String
                               , mRngSeed :: Maybe Int
                               , mSendFor :: Maybe Int
                               , mWaitFor :: Maybe Int
                               , mModel :: Maybe SimulationModel
                               }

parseArgs :: [String] -> Maybe RunParams
parseArgs = parseArgs' $ IRP Nothing Nothing Nothing Nothing Nothing Nothing Nothing

parseArgs' :: IncompleteRunParams -> [String] -> Maybe RunParams
parseArgs' irp@IRP{} ("--master":h:p:params) = parseArgs' irp{mRunMode=Just Master, mHost=Just h, mPort=Just p} params
parseArgs' irp@(IRP{}) ("--slave":h:p:params) = parseArgs' irp{mRunMode=Just Slave, mHost=Just h, mPort=Just p} params
parseArgs' irp@(IRP{}) ("--send-for":sendForStr:params) = parseArgs' irp{mSendFor=Just (read sendForStr)} params
parseArgs' irp@(IRP{}) ("--wait-for":waitForStr:params) = parseArgs' irp{mWaitFor=Just (read waitForStr)} params
parseArgs' irp@(IRP{}) ("--with-seed":rngSeedStr:params) = parseArgs' irp{mRngSeed=Just (read rngSeedStr)} params
parseArgs' irp@(IRP{}) ("--sim":stateModel:genModel:params) =
  parseArgs' irp{mModel =Just (simulatonFrom stateModel genModel)} params
parseArgs' irp [] = argsFrom irp
parseArgs' _ _ = Nothing

argsFrom :: IncompleteRunParams -> Maybe RunParams
argsFrom (IRP runMode host port rngSeed sendFor waitFor simModel) = do
  mode <- runMode
  h <- host
  p <- port
  seed <- rngSeed
  case mode of
    Master -> do
      sF <- sendFor
      wF <- waitFor
      sM <- simModel
      return $ MasterParams h p seed sF wF sM
    Slave -> return $ SlaveParams h p seed

usage :: IO ()
usage = putStrLn $ "Usage: stack exec otp-exe -- <options>\n" ++
                 "  where options are:\n" ++
                 "        --master <host> <port>\n" ++
                 "        --slave  <host> <port>\n" ++
                 "        --with-seed <RNG seed>\n" ++
                 "        --send-for <send for period> *\n" ++
                 "        --wait-for <wait for period> *\n" ++
                 "        --sim <state model> <generators model> *\n" ++
                 "  * not required for slave\n" ++
                 "  available state models: \n" ++
                 "    Simple - just the counter for input messages processed and running product\n" ++
                 "    Tree - tree of input messages with keys of (timestamp, generator pid)\n" ++
                 "    List - list of input messages with keys of (timestamp, generator pid)\n" ++
                 "    Dynamic - state switching dynamically betwen Tree and List\n" ++
                 "  available generator models:\n" ++
                 "    OneGen - only one generator (on master's node)\n" ++
                 "    MultiGen - a generator per slave node, no delays\n" ++
                 "    FinDelays - a generator per slave node, finite random delays\n" ++
                 "    InfDelays - a generator per slave node, possibly infinite random delays\n"
