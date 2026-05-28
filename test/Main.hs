module Main (main) where

import qualified Apalache.CommandSpec as CommandSpec
import qualified Apalache.TraceSpec as TraceSpec
import qualified Apalache.TypesSpec as TypesSpec

main :: IO ()
main = do
  CommandSpec.spec
  TraceSpec.spec
  TypesSpec.spec
