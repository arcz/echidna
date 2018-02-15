{-# LANGUAGE FlexibleContexts, KindSignatures #-}

module Echidna.Exec (
    checkETest
  , eCommand
  , ePropertySeq
  , fuzz
  ) where

import Control.Lens               ((^.), assign)
import Control.Monad              (replicateM)
import Control.Monad.State.Strict (MonadState, evalState, execState)
import Data.Maybe                 (listToMaybe)
import Data.Text                  (Text)
import Data.Vector                (fromList)

import Hedgehog
import Hedgehog.Gen   (sample, sequential)
import Hedgehog.Range (linear)

import EVM          (VM, VMResult(..), calldata, pc, result, state)
import EVM.ABI      (AbiType, AbiValue(..), abiCalldata, abiValueType, encodeAbiValue)
import EVM.Concrete (Blob(..))
import EVM.Exec     (exec)

import Echidna.ABI (displayAbiCall, encodeSig, genInteractions)

execCall :: MonadState VM m => (Text, [AbiValue]) -> m VMResult
execCall (t,vs) = assign (state . calldata) cd >> exec where
  cd = B . abiCalldata (encodeSig t $ map abiValueType vs) $ fromList vs

fuzz :: Int -- Call sequence length
     -> Int -- Number of iterations
     -> [(Text, [AbiType])] -- Type signatures to call
     -> VM -- Initial state
     -> (VM -> IO Bool) -- Predicate to fuzz for violations of
     -> IO (Maybe [String]) -- Counterexample, if possible
fuzz l n ts v p = do
  callseqs <- replicateM n (replicateM l . sample $ genInteractions ts)
  results <- zip callseqs <$> mapM run callseqs
  return $ listToMaybe [map displayAbiCall cs | (cs, passed) <- results, not passed]
    where run cs = p $ execState (mapM_ (\c -> execCall c >> cleanUp) cs) v
          cleanUp = assign result Nothing >> assign (state . pc) 0

checkETest :: VM -> Text -> Bool
checkETest v t = case evalState (execCall (t, [])) v of
  VMSuccess (B s) -> s == encodeAbiValue (AbiBool True)
  _               -> False

newtype VMState (v :: * -> *) =
  Current VM

instance Show (VMState v) where
  show (Current v) = "EVM state, current result: " ++ show (v ^. result)

newtype VMAction (v :: * -> *) = 
  Call (Text, [AbiValue])

instance Show (VMAction v) where
  show (Call c) = displayAbiCall c

instance HTraversable VMAction where
  htraverse _ (Call b) = pure $ Call b

eCommand :: (MonadGen n, MonadTest m) => VM -> [(Text, [AbiType])] -> (VM -> Bool) -> Command n m VMState
eCommand v ts p = Command (const . Just . fmap Call $ genInteractions ts)
                          (\(Call b) -> pure $ evalState (execCall b) v)
                          [Ensure $ \_ (Current s) _ _ -> assert $ p s]

ePropertySeq :: VM                  -- Initial state
             -> [(Text, [AbiType])] -- Type signatures to fuzz
             -> (VM -> Bool)        -- Predicate to fuzz for violations of
             -> Int                 -- Max actions to execute
             -> Property
ePropertySeq v ts p n = property $ executeSequential (Current v) =<<
  forAll (sequential (linear 1 n) (Current v) [eCommand v ts p])

-- Should work, but missing instance MonadBaseControl b m => MonadBaseControl b (PropertyT m)
-- ePropertyPar :: VM                  -- Initial state
             -- -> [(Text, [AbiType])] -- Type signatures to fuzz
             -- -> (VM -> Bool)        -- Predicate to fuzz for violations of
             -- -> Int                 -- Max size
             -- -> Int                 -- Max post-prefix size
             -- -> Property
-- ePropertyPar v ts p n m = withRetries 10 . property $ executeParallel (Current v) =<<
--   forAll (parallel (linear 1 n) (linear 1 m) (Current v) [eCommand v ts p])
