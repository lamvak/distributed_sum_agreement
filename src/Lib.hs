module Lib
    ( someFunc,
      otpRand,
      otpRand', -- preferably, would keep this one private but easiest tactical for testing in separation from real RNG
      otpRandIO,
      RunMode(Master,Slave),
      RunParams(RunParams),
      parseArgs,
      usage,
    ) where

import System.Random
import Text.Heredoc

someFunc :: IO ()
someFunc = putStrLn "someFunc"

otpRandCorrection :: Double -> Double
otpRandCorrection d = if d == 0 then 1 else d

otpRand :: RandomGen g => g -> (Double, g)
otpRand = otpRand' . random

otpRand' :: RandomGen g => (Double, g) -> (Double, g)
otpRand' (d, g) = (otpRandCorrection d, g)

otpRandIO :: IO Double
otpRandIO = otpRandCorrection <$> randomIO


-- list operations (i.e. filter out -> for rediscovery of new slaves)


-- Commandline parameters parsing
data RunMode = Master | Slave
  deriving (Show)
data RunParams = RunParams { runMode :: RunMode
                           , host :: String
                           , port :: String
                           , rngSeed :: Int
                           , sendFor :: Int
                           , waitFor :: Int
                           } deriving (Show)
data IncompleteRunParams = IRP { mRunMode :: Maybe RunMode
                               , mHost :: Maybe String
                               , mPort :: Maybe String
                               , mRngSeed :: Maybe Int
                               , mSendFor :: Maybe Int
                               , mWaitFor :: Maybe Int
                               }

parseArgs :: [String] -> Maybe RunParams
parseArgs = parseArgs' $ IRP Nothing Nothing Nothing Nothing Nothing Nothing

parseArgs' :: IncompleteRunParams -> [String] -> Maybe RunParams
parseArgs' irp@IRP{} ("--master":h:p:params) = parseArgs' irp{mRunMode=Just Master, mHost=Just h, mPort=Just p} params
parseArgs' irp@(IRP{}) ("--slave":h:p:params) = parseArgs' irp{mRunMode=Just Slave, mHost=Just h, mPort=Just p} params
parseArgs' irp@(IRP{}) ("--send-for":sendForStr:params) = parseArgs' irp{mSendFor=Just (read sendForStr)} params
parseArgs' irp@(IRP{}) ("--wait-for":waitForStr:params) = parseArgs' irp{mWaitFor=Just (read waitForStr)} params
parseArgs' irp@(IRP{}) ("--with-seed":rngSeedStr:params) = parseArgs' irp{mRngSeed=Just (read rngSeedStr)} params
parseArgs' irp [] = argsFrom irp
parseArgs' _ _ = Nothing

argsFrom :: IncompleteRunParams -> Maybe RunParams
argsFrom (IRP runMode host port rngSeed sendFor waitFor) = do
  mode <- runMode
  h <- host
  p <- port
  seed <- rngSeed
  case mode of
    Master -> do
      sF <- sendFor
      wF <- waitFor
      return $ RunParams mode h p seed sF wF
    Slave -> return $ RunParams mode h p seed (-1) (-1)

usage :: IO ()
usage = putStrLn $ "Usage: stack exec otp-exe -- <options>\n" ++
                 "  where options are:\n" ++
                 "        --master <host> <port>\n" ++
                 "        --slave  <host> <port>\n" ++
                 "        --send-for <send for period> *\n" ++
                 "        --wait-for <wait for period> *\n" ++
                 "        --with-seed <RNG seed>\n" ++
                 "  * not required for slave\n"