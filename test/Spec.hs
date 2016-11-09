import Test.Hspec
import Lib
import System.Random

main :: IO ()
main = hspec $ do
  describe "Random number generation" $ do
    it "generates a random number" $ do
      let g = mkStdGen 42 in
          fst (otpRand g) `shouldBe` 0.010663729393723398
    it "generates from (0, 1] instead of [0, 1)" $ do
      let g = mkStdGen 42 in
          (fst $ otpRand' (0, g)) `shouldBe` 1

