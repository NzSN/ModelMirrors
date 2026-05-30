module Main (main) where

import qualified Apalache.CommandSpec as CommandSpec
import qualified Apalache.TraceSpec as TraceSpec
import qualified Apalache.TypesSpec as TypesSpec
import qualified ClientSpec
import qualified EngineSpec

main :: IO ()
main = do
  ClientSpec.spec
  EngineSpec.spec
  CommandSpec.spec
  TraceSpec.spec
  TypesSpec.spec
