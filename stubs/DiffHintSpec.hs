-- | Bazel-only stub: the real DiffHintSpec needs QuickCheck, which is
-- cabal-only (adding stackage packages is blocked on Hackage fetching);
-- it is excluded from the Bazel test glob.
module DiffHintSpec (spec) where

import Test.Tasty (TestTree, testGroup)

spec :: TestTree
spec = testGroup "DiffHintSpec" []
