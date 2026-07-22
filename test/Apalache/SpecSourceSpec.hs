module Apalache.SpecSourceSpec (spec) where

import Apalache.Rpc.Types (ApalacheSpec (..))
import Apalache.SpecSource (materializeSpec, moduleName, removeSpecDir)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

spec :: TestTree
spec = testGroup "SpecSourceSpec"
  [ testModuleNameValid
  , testModuleNameMissing
  , testModuleNameMalformed
  , testMaterializeEmpty
  , testMaterializeTwoModules
  , testMaterializeDuplicateNames
  ]

extMainSrc :: Text
extMainSrc = T.pack "---- MODULE ExtMain ----\nEXTENDS Integers, ExtDep\n====\n"

extDepSrc :: Text
extDepSrc = T.pack "---- MODULE ExtDep ----\nEXTENDS Integers\n====\n"

testModuleNameValid :: TestTree
testModuleNameValid = testCase "moduleName parses a valid header" $
  moduleName extMainSrc @?= Right (T.pack "ExtMain")

testModuleNameMissing :: TestTree
testModuleNameMissing = testCase "moduleName rejects source without header" $
  case moduleName (T.pack "EXTENDS Integers\n====\n") of
    Left _ -> pure ()
    Right n -> assertFailure ("expected Left, got " ++ show n)

testModuleNameMalformed :: TestTree
testModuleNameMalformed = testCase "moduleName rejects dash-only module name" $
  case moduleName (T.pack "---- MODULE ----\n====\n") of
    Left _ -> pure ()
    Right n -> assertFailure ("expected Left, got " ++ show n)

testMaterializeEmpty :: TestTree
testMaterializeEmpty = testCase "materializeSpec rejects empty sources" $ do
  r <- materializeSpec (ApalacheSpec [])
  case r of
    Left _ -> pure ()
    Right (dir, _) -> removeSpecDir dir >> assertFailure "expected Left"

testMaterializeTwoModules :: TestTree
testMaterializeTwoModules = testCase "materializeSpec writes files named after modules" $ do
  r <- materializeSpec (ApalacheSpec [extMainSrc, extDepSrc])
  case r of
    Left err -> assertFailure (T.unpack err)
    Right (dir, rootPath) -> do
      assertBool "root path is <dir>/ExtMain.tla"
        (T.pack "/ExtMain.tla" `T.isSuffixOf` T.pack rootPath)
      mainExists <- doesFileExist (dir ++ "/ExtMain.tla")
      depExists <- doesFileExist (dir ++ "/ExtDep.tla")
      assertBool "ExtMain.tla written" mainExists
      assertBool "ExtDep.tla written" depExists
      removeSpecDir dir
      stillThere <- doesDirectoryExist dir
      assertBool "removeSpecDir cleans up" (not stillThere)

testMaterializeDuplicateNames :: TestTree
testMaterializeDuplicateNames = testCase "materializeSpec rejects duplicate module names" $ do
  r <- materializeSpec (ApalacheSpec [extMainSrc, extMainSrc])
  case r of
    Left _ -> pure ()
    Right (dir, _) -> removeSpecDir dir >> assertFailure "expected Left"
