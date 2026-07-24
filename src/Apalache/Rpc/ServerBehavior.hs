-- Replay ITF traces generated from specs/ApalacheRPCClient.tla against a
-- live apalache explorer server, checking in lockstep that every observed
-- RPC outcome is permitted by the oracle state machine modeled in
-- specs/AapalacheRPCProtocol.tla / specs/ApalacheRPCClient.tla.
--
-- The trace supplies the call sequence (method + parameters via the
-- clLastMethod / clLastTid / clLastIid / clLastSnap variables). The
-- lockstep oracle supplies the correctness criterion: an observed
-- successful outcome must be reachable in the oracle from the current
-- abstract state; observed errors are always permitted (the client
-- oracle has an unconstrained error branch for every method).
module Apalache.Rpc.ServerBehavior
  ( OracleState (..)
  , ServerStep (..)
  , initOracle
  , replayTrace
  ) where

import Apalache.Explorer
  ( Explorer (..)
  , exploreAssumeState
  , exploreCheck
  , exploreDispose
  , exploreQueryState
  , exploreRollback
  , newExplorer
  , withApalacheServer
  )
import Apalache.Rpc.Client (assumeTransition, health, newRpcClient, nextStep)
import Apalache.Rpc.Types
  ( ApalacheServer (..)
  , ApalacheSpec
  , AssumeTransitionParams (..)
  , AssumeTransitionResult (..)
  , InvariantKind (..)
  , InvariantStatus (..)
  , NextStateParams (..)
  , NextStateResult (..)
  , RpcError (..)
  , SpecParams (..)
  , TransitionStatus (..)
  )
import Apalache.Types (ItfTrace (..), TraceState (..), Value (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

data OracleState = OracleState
  { osPhase    :: !Text  -- "uninitialized" | "ready" | "running" | "terminal" | "disposed"
  , osStep     :: !Int
  , osSnapshot :: !Int
  , osPending  :: !Int   -- pending transition id, -1 when none
  , osSession  :: !Bool
  , osStepsOk  :: !Bool  -- step-counter correspondence with the server intact
  } deriving (Show, Eq)

initOracle :: OracleState
initOracle = OracleState (T.pack "uninitialized") 0 0 (-1) False True

data ServerStep = ServerStep
  { ssMethod    :: !Text
  , ssExpResult :: !Text        -- clLastResult from the trace
  , ssObsResult :: !Text        -- "ok" | "http_error" | "protocol_error" | "parse_error" | "skipped"
  , ssOracle    :: !OracleState -- oracle state after this step
  , ssMatch     :: !Bool        -- observed outcome permitted by the oracle
  , ssNote      :: !Text
  } deriving (Show, Eq)

noPending :: Int
noPending = -1

classifyResult :: RpcError -> Text
classifyResult (RpcHttpError _)       = T.pack "http_error"
classifyResult (RpcProtocolError _ _) = T.pack "protocol_error"
classifyResult (RpcParseError _)      = T.pack "parse_error"

isErrResult :: Text -> Bool
isErrResult r = r `elem` map T.pack ["http_error", "protocol_error", "parse_error"]

textVar :: Text -> Map Text Value -> Text
textVar k m = case Map.lookup k m of
  Just (VStr s) -> s
  _             -> T.empty

intVar :: Text -> Map Text Value -> Int
intVar k m = case Map.lookup k m of
  Just (VInt n) -> fromIntegral n
  _             -> -1

replayTrace :: ApalacheSpec -> [Text] -> [Text] -> ItfTrace -> IO (Either RpcError [ServerStep])
replayTrace spec invs exports trace =
  withApalacheServer Nothing $ \server -> do
    client <- newRpcClient (serverPort server)
    steps <- go server client Nothing initOracle (drop 1 (traceStates trace)) []
    pure (Right steps)
  where
    go _ _ _ _ [] acc = pure (reverse acc)
    go server client mExpl os (ts : rest) acc = do
      let allVars   = Map.union (parameters ts) (stateVars ts)
          method    = textVar (T.pack "clLastMethod") allVars
          expResult = textVar (T.pack "clLastResult") allVars
      if T.null method || method == T.pack "none" || isErrResult expResult
        then do
          let st = ServerStep method expResult (T.pack "skipped") os True
                     (T.pack "init state or non-replayable error branch")
          go server client mExpl os rest (st : acc)
        else do
          (mExpl', os', obs, ok, note) <- execStep server client mExpl os method allVars
          let st = ServerStep method expResult obs os' ok note
          go server client mExpl' os' rest (st : acc)

    execStep server client mExpl os method allVars
      | method == T.pack "health" = do
          r <- health client
          case r of
            Left err -> permitted mExpl os (classifyResult err)
            Right _  -> permitted mExpl os (T.pack "ok")

      | method == T.pack "loadSpec" =
          if osPhase os /= T.pack "uninitialized"
            then mismatch mExpl os (T.pack "loadSpec called with an active session")
            else do
              r <- newExplorer server spec invs exports
              case r of
                Left err ->
                  pure ( mExpl
                       , os { osPhase = T.pack "terminal" }
                       , classifyResult err
                       , True
                       , T.pack "loadSpec failed on the server; oracle phase terminal"
                       )
                Right expl ->
                  pure ( Just expl
                       , os { osPhase = T.pack "ready", osStep = 0, osSnapshot = 0
                            , osPending = noPending, osSession = True }
                       , T.pack "ok"
                       , True
                       , T.empty
                       )

      | method == T.pack "assumeTransition" = withSession mExpl os $ \expl -> do
          let refs = if osPhase os == T.pack "ready"
                then spInitTransitions (explParams expl)
                else spNextTransitions (explParams expl)
              tid = if null refs then 0 else intVar (T.pack "clLastTid") allVars `mod` length refs
          r <- assumeTransition client (AssumeTransitionParams (explSessionId expl) tid True Nothing)
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right atr
              | osPhase os `notElem` [T.pack "ready", T.pack "running"] ->
                  mismatch (Just expl) os (T.pack "assumeTransition ok in phase " <> osPhase os)
              | osPending os /= noPending ->
                  mismatch (Just expl) os (T.pack "assumeTransition ok while another transition is pending")
              | otherwise ->
                  let pending' = case atrStatus atr of
                        TransDisabled -> noPending
                        _             -> tid
                  in pure ( Just expl { explSnap = atrSnapshotId atr }
                          , os { osPending = pending' }
                          , T.pack "ok"
                          , True
                          , T.empty
                          )

      | method == T.pack "nextStep" = withSession mExpl os $ \expl -> do
          r <- nextStep client (NextStateParams (explSessionId expl))
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right nsr
              | osPending os == noPending ->
                  mismatch (Just expl) os (T.pack "nextStep ok with no pending transition")
              | osStepsOk os && nsrNewStepNo nsr /= osStep os + 1 ->
                  mismatch (Just expl) os $ T.pack
                    ("newStepNo divergence: server=" ++ show (nsrNewStepNo nsr)
                      ++ " oracle=" ++ show (osStep os + 1))
              | otherwise ->
                  pure ( Just expl { explSnap = nsrSnapshotId nsr }
                       , os { osPhase = T.pack "running", osStep = osStep os + 1
                            , osSnapshot = osSnapshot os + 1, osPending = noPending }
                       , T.pack "ok"
                       , True
                       , T.empty
                       )

      | method == T.pack "checkInvariant" = withSession mExpl os $ \expl -> do
          let nInvs = length (spStateInvariants (explParams expl))
              iid = if nInvs == 0 then 0 else intVar (T.pack "clLastIid") allVars `mod` nInvs
          r <- exploreCheck expl iid StateInvariant
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right (status, _)
              | osPhase os `notElem` [T.pack "ready", T.pack "running"] ->
                  mismatch (Just expl) os (T.pack "checkInvariant ok in phase " <> osPhase os)
              | status == InvViolated ->
                  pure ( Just expl
                       , os { osPhase = T.pack "terminal" }
                       , T.pack "ok"
                       , True
                       , T.pack "invariant violated; harness-policy terminal"
                       )
              | otherwise -> permitted (Just expl) os (T.pack "ok")

      | method == T.pack "query" = withSession mExpl os $ \expl -> do
          r <- exploreQueryState expl
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right _
              | osPhase os `elem` [T.pack "ready", T.pack "running"] ->
                  permitted (Just expl) os (T.pack "ok")
              | otherwise ->
                  mismatch (Just expl) os (T.pack "query ok in phase " <> osPhase os)

      | method == T.pack "assumeState" = withSession mExpl os $ \expl -> do
          r <- exploreAssumeState expl Map.empty
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right (expl', _)
              | osPhase os /= T.pack "running" ->
                  mismatch (Just expl) os (T.pack "assumeState ok in phase " <> osPhase os)
              | otherwise -> permitted (Just expl') os (T.pack "ok")

      | method == T.pack "rollback" = withSession mExpl os $ \expl -> do
          r <- exploreRollback expl 0
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right expl'
              | osPhase os `notElem` [T.pack "ready", T.pack "running"] ->
                  mismatch (Just expl) os (T.pack "rollback ok in phase " <> osPhase os)
              | otherwise ->
                  pure ( Just expl'
                       , os { osPhase = T.pack "ready", osStep = 0, osSnapshot = 0
                            , osPending = noPending, osStepsOk = False }
                       , T.pack "ok"
                       , True
                       , T.empty
                       )

      | method == T.pack "disposeSpec" = withSession mExpl os $ \expl -> do
          r <- exploreDispose expl
          case r of
            Left err -> permitted (Just expl) os (classifyResult err)
            Right ()
              | osPhase os `elem` [T.pack "uninitialized", T.pack "disposed"] ->
                  mismatch (Just expl) os (T.pack "disposeSpec ok in phase " <> osPhase os)
              | otherwise ->
                  pure ( Nothing
                       , os { osPhase = T.pack "disposed", osSession = False }
                       , T.pack "ok"
                       , True
                       , T.empty
                       )

      | otherwise = mismatch mExpl os (T.pack "unknown method in trace: " <> method)

    permitted mExpl os obs = pure (mExpl, os, obs, True, T.empty)
    mismatch mExpl os note = pure (mExpl, os, T.pack "ok", False, note)
    withSession mExpl os f = case mExpl of
      Nothing -> pure (Nothing, os, T.pack "skipped", False, T.pack "session-gated call with no active session")
      Just expl -> f expl
