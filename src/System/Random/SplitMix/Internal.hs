{-# LANGUAGE ScopedTypeVariables, BangPatterns, UnboxedTuples, MagicHash, GADTs #-}
{-# LANGUAGE DeriveFunctor #-}


module System.Random.SplitMix.Internal(
  nextSeedSplitMix
  ,splitGeneratorSplitMix
  ,nextWord64SplitMix
  ,SplitMix64(..)
  ,Random(..)
  ,RandomT(..)
  ) where

import qualified  Data.Bits  as DB
import Data.Bits (xor,(.|.))
import Data.Word(Word64(..))
import Data.Functor.Identity

{-# SPECIALIZE popCount :: Word64 -> Word64 #-}
{-# SPECIALIZE popCount :: Int -> Word64 #-}
{-# SPECIALIZE popCount :: Word -> Word64 #-}
popCount :: DB.FiniteBits b => b -> Word64
popCount  = \ w ->  fromIntegral $ DB.popCount w


{-# SPECIALIZE xorShiftR :: Int -> Word64 -> Word64 #-}
xorShiftR :: DB.FiniteBits  b => Int -> b ->  b
xorShiftR = \ shift val  ->  val `xor` ( val `DB.unsafeShiftR` shift)


xorShiftR33 :: Word64 -> Word64
xorShiftR33 = \ w -> xorShiftR 33 w


firstRoundMix64 :: Word64 -> Word64
firstRoundMix64 = \ w ->  xorShiftR33 w * 0xff51afd7ed558ccd

secondRoundMix64 :: Word64 -> Word64
secondRoundMix64 = \ w -> xorShiftR33 w * 0xc4ceb9fe1a85ec53



mix64variant13 :: Word64 -> Word64
mix64variant13 = \ w -> xorShiftR 31 $ secondRoundMix64Variant13 $ firstRoundMix64Variant13 w

firstRoundMix64Variant13 :: Word64 -> Word64
firstRoundMix64Variant13 = \ w -> xorShiftR 30 w * 0xbf58476d1ce4e5b9


secondRoundMix64Variant13 :: Word64 -> Word64
secondRoundMix64Variant13 = \ w -> xorShiftR 27 w * 0x94d049bb133111eb

mix64 :: Word64 -> Word64
mix64 = \ w -> xorShiftR33 $  secondRoundMix64 $ firstRoundMix64 w

mixGamma :: Word64 -> Word64
mixGamma = \ w -> runIdentity $!
  do
    !mixedGamma <- return $! (mix64variant13 w .|. 1)
    !bitCount <- return $! popCount $ xorShiftR 1 mixedGamma
    if bitCount >= 24
      then return (mixedGamma `xor` 0xaaaaaaaaaaaaaaaa)
      else return mixedGamma

{-

theres a few different alternatives we could do for the RNG state

-- this isn't quite expressible
type SplitMix64 = (# Word64# , Word64# #)
-}

data SplitMix64 = SplitMix64 { sm64seed :: {-# UNPACK #-} !Word64
                              ,sm64Gamma :: {-# UNPACK #-} !Word64 }



advanceSplitMix :: SplitMix64 -> SplitMix64
advanceSplitMix (SplitMix64 sd gamma) = SplitMix64 (sd + gamma) gamma

nextSeedSplitMix :: SplitMix64 -> (# Word64, SplitMix64 #)
nextSeedSplitMix gen@(SplitMix64 result _) =  newgen `seq` (# result,newgen #)
  where
    newgen = advanceSplitMix gen


newtype Random  a =  Random# (SplitMix64 -> (# a , SplitMix64 #))
  --deriving Functor



newtype RandomT m a = RandomT# { unRandomT# :: (SplitMix64 -> (# m a , SplitMix64 #)) }

instance Functor m => Functor (RandomT m) where
  fmap = \ f (RandomT# mf) ->
              RandomT# $  \ seed ->
                       let  (# !ma , !s'  #) = mf seed
                            !mb = fmap f ma
                          in  (# mb , s' #)

instance Applicative m => Applicative (RandomT m) where
  pure = \ x ->  RandomT# $  \ s  -> (# pure x , s  #)
  (<*>)  = \ (RandomT# frmb) (RandomT# rma) ->  RandomT# $ \ s ->
                    let (# !fseed, !maseed #) = splitGeneratorSplitMix s
                        (# !mf , _boringSeed #) = frmb fseed
                        (# !ma , newSeed #) = rma  maseed
                        in (#  mf <*> ma , newSeed  #)


instance Monad m => Monad (RandomT m) where
  (>>=) = \ (RandomT# ma) mf ->
    RandomT# $  \ s ->
      let
         (# splitSeed, nextSeed #) = splitGeneratorSplitMix s
         (# maRes, _boringSeed #) = ma splitSeed
         (# mfRes , resultSeed  #)

{-
there are two models of RandomT m a we could do

1)  s -> (m a , s)

or

2)  s -> m (a,s)

-- The 'return' function leaves the state unchanged, while @>>=@ uses
-- split on the rng state so that the final state of the first computation
-- is independent of the second ...
so lets try writing an instance using 1
-}



nextWord64SplitMix :: SplitMix64 -> (# Word64 , SplitMix64 #)
nextWord64SplitMix gen = mixedRes `seq` (# mixedRes , newgen #)
  where
    mixedRes = mix64 premixres
    (#  premixres , newgen  #) = nextSeedSplitMix  gen

splitGeneratorSplitMix :: SplitMix64 -> (# SplitMix64 , SplitMix64 #)
splitGeneratorSplitMix gen = splitGen `seq`( nextNextGen `seq` (# splitGen , nextNextGen #))
  where
    (# splitSeed , nextGen  #) = nextWord64SplitMix gen
    (# splitPreMixGamma , nextNextGen #) = nextSeedSplitMix nextGen
    !splitGenGamma = mixGamma splitPreMixGamma
    !splitGen = SplitMix64 splitSeed splitGenGamma


