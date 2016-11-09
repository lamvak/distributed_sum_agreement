module Lib
    ( someFunc,
      otpRand,
      otpRand', -- preferably, would keep this one private but easiest tactical for testing in separation from real RNG
    ) where

import System.Random

someFunc :: IO ()
someFunc = putStrLn "someFunc"

otpRand :: RandomGen g => g -> (Double, g)
otpRand = otpRand' . random

otpRand' :: RandomGen g => (Double, g) -> (Double, g)
otpRand' (d, g) = (if d == 0 then 1 else d, g)
