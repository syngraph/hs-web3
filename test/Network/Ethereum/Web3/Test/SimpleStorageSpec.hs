{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}

-- Module      :  Network.Ethereum.Web3.Test.SimpleStorage
-- Copyright   :  Alexander Krupenkin 2016
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  unportable
--
-- SimpleStorage is a Solidity contract which stores a uint256.
-- The point of this test is to test function calls to update and
-- read the value, as well as an event monitor.

module Network.Ethereum.Web3.Test.SimpleStorageSpec where

import           Control.Concurrent               (threadDelay)
import           Control.Concurrent.Async         (wait)
import           Control.Concurrent.MVar
import           Control.Monad                    (void)
import           Control.Monad.IO.Class           (liftIO)
import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Reader       (ask)
import           Data.ByteString                  (ByteString)
import           Data.Default
import           Data.Either                      (isRight)
import           Data.Foldable                    (forM_)
import           Data.List                        (sort)
import           Data.Maybe
import           Data.Monoid
import           Data.String                      (fromString)
import qualified Data.Text                        as T
import           Data.Traversable                 (for)
import           GHC.TypeLits

import           Network.Ethereum.Web3            hiding (convert)
import           Network.Ethereum.Web3.Contract   (Event (..))
import qualified Network.Ethereum.Web3.Eth        as Eth
import           Network.Ethereum.Web3.TH
import           Network.Ethereum.Web3.Types

import           Numeric                          (showHex)
import           System.Environment               (getEnv)
import           System.IO.Unsafe                 (unsafePerformIO)
import           Test.Hspec

import Network.Ethereum.Web3.Test.Utils

[abiFrom|test-support/build/contracts/abis/SimpleStorage.json|]

unCountSet :: CountSet -> UIntN 256
unCountSet (CountSet n) = n

contractAddress :: Address
contractAddress = fromString . unsafePerformIO $ getEnv "SIMPLESTORAGE_CONTRACT_ADDRESS"

spec :: Spec
spec = describe "Simple Storage" $ do
    it "should inject contract addresses" injectExportedEnvironmentVariables
    withPrimaryEthereumAccount `before` interactions
    withPrimaryEthereumAccount `before` events

interactions :: SpecWith Address
interactions = describe "can interact with a SimpleStorage contract" $ do
    -- todo: this should ideally be arbitrary!
    let theValue = 12345
    it "can set the value of a SimpleStorage contract" $ \primaryAccount -> do
        let theCall = callFromTo primaryAccount contractAddress
        ret <- runWeb3Configured $ setCount theCall theValue
        True `shouldBe` True -- we need to get this far

    it "can read the value back" $ \primaryAccount -> do
        let theCall = callFromTo primaryAccount contractAddress
        now <- runWeb3Configured Eth.blockNumber
        let later = now + 3
        awaitBlock later
        v <- runWeb3Configured (count theCall)
        v `shouldBe` theValue

events :: SpecWith Address
events = describe "can interact with a SimpleStorage contract across block intervals" $ do
    it "can stream events starting and ending in the future, unbounded" $ \primaryAccount -> do
        var <- newMVar []
        let theCall = callFromTo primaryAccount contractAddress
            theSets = map (fromJust . uIntNFromInteger) [1, 2, 3]
        print "Setting up the filter..."
        fiber <- runWeb3Configured' $ do
          let fltr = eventFilter contractAddress
          forkWeb3 $ processUntil' var fltr ((3 ==) . length)
        print "Setting the values..."
        setValues theCall theSets
        wait fiber
        print "Filter caught 3 values..."
        vals <- takeMVar var
        sort (unCountSet <$> vals) `shouldBe` sort theSets

    it "can stream events starting and ending in the future, bounded" $ \primaryAccount -> do
        runWeb3Configured Eth.blockNumber >>= \bn -> awaitBlock (bn + 1)
        var <- newMVar []
        let theCall = callFromTo primaryAccount contractAddress
            theSets = map (fromJust . uIntNFromInteger) [13, 14, 15]
        start <- runWeb3Configured Eth.blockNumber
        let later = BlockWithNumber (start + 3)
            latest = BlockWithNumber (start + 8)
            fltr = (eventFilter contractAddress :: Filter CountSet) { filterFromBlock = later
                                                                    , filterToBlock = latest
                                                                    }
        print "Setting up the filter..."
        fiber <- runWeb3Configured' $
          forkWeb3 $ processUntil' var fltr ((3 ==) . length)
        awaitBlock (start + 3)
        print "Setting the values..."
        setValues theCall theSets
        wait fiber
        print "Filter caught 3 values..."
        vals <- takeMVar var
        sort (unCountSet <$> vals) `shouldBe` sort theSets

    it "can stream events starting in the past and ending in the future" $ \primaryAccount -> do
        runWeb3Configured Eth.blockNumber >>= \bn -> awaitBlock (bn + 1)
        var <- newMVar []
        blockNumberVar <- newEmptyMVar
        let theCall = callFromTo primaryAccount contractAddress
            theSets1 = map (fromJust . uIntNFromInteger) [7, 8, 9]
            theSets2 = map (fromJust . uIntNFromInteger) [10, 11, 12]
        start <- runWeb3Configured Eth.blockNumber
        let fltr = eventFilter contractAddress :: Filter CountSet
        fiber <- runWeb3Configured' $ do
          forkWeb3 $ processUntil var fltr ((3 ==) . length) (liftIO . putMVar blockNumberVar . changeBlockNumber)
        print "Running first transactions as past transactions..."
        setValues theCall theSets1
        wait fiber
        print "All past transactions succeeded... "
        end <- takeMVar blockNumberVar
        awaitBlock $ end + 1 -- make past transactions definitively in past
        var' <- newMVar []
        fiber <- runWeb3Configured' $ do
          let fltr = (eventFilter contractAddress :: Filter CountSet) {filterFromBlock = BlockWithNumber start}
          forkWeb3 $ processUntil' var' fltr ((6 ==) . length)
        print "Setting more values"
        setValues theCall theSets2
        wait fiber
        print "All new values have ben set"
        vals <- takeMVar var'
        sort (unCountSet <$> vals) `shouldBe` sort (theSets1 <> theSets2)

    it "can stream events starting and ending in the past, bounded" $ \primaryAccount -> do
        runWeb3Configured Eth.blockNumber >>= \bn -> awaitBlock (bn + 1)
        var <- newMVar []
        let theCall = callFromTo primaryAccount contractAddress
            theSets = map (fromJust . uIntNFromInteger) [4, 5, 6]
        start <- runWeb3Configured Eth.blockNumber
        blockNumberVar <- newEmptyMVar
        let fltr = eventFilter contractAddress
        print "Setting up filter for past transactions..."
        fiber <- runWeb3Configured' $ do
          forkWeb3 $ processUntil var fltr ((3 ==) . length) (liftIO . putMVar blockNumberVar . changeBlockNumber)
        print "Setting values"
        setValues theCall theSets
        wait fiber
        print "All values have been set"
        end <- takeMVar blockNumberVar
        var' <- newMVar []
        let fltr' = fltr { filterFromBlock = BlockWithNumber start
                         , filterToBlock = BlockWithNumber end
                         }
        awaitBlock $ end + 1 -- make it definitively in the past
        runWeb3Configured $ processUntil' var' fltr' ((3 ==) . length)
        vals <- takeMVar var'
        sort (unCountSet <$> vals) `shouldBe` sort theSets

processUntil :: (Provider provider)
             => MVar [CountSet]
             -> Filter CountSet
             -> ([CountSet] -> Bool) -- TODO: make it work for any event
             -> (Change -> Web3 provider ())
             -> Web3 provider ()
processUntil var filter predicate action = do
  event' filter $ \(ev :: CountSet) -> do
    newV <- liftIO $ modifyMVar var $ \v -> return (ev:v, ev:v)
    if predicate newV
        then do
          change <- ask
          lift $ action change
          return TerminateEvent
        else return ContinueEvent

processUntil' :: (Provider provider)
              => MVar [CountSet]
              -> Filter CountSet
              -> ([CountSet] -> Bool)
              -> Web3 provider ()
processUntil' var filter predicate = processUntil var filter predicate (const $ return ())

setValues :: Call -> [UIntN 256] -> IO ()
setValues theCall theSets = forM_ theSets $ \v -> do
  runWeb3Configured (setCount theCall v)
  threadDelay 1000000
