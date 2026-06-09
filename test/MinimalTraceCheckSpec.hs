module MinimalTraceCheckSpec (spec) where

import Apalache.Types (Value (..))
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Engine.Types (StateDiff (..), VarDiff (..))
import MinimalTraceCheck (check, normalize)
import Protocol.Mirror (MirrorStep (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

spec :: TestTree
spec = testGroup "MinimalTraceCheck"
  [ normalizeEmpty
  , normalizeOnlyAllDone
  , normalizeWithTrailingAllDone
  , normalizeCollapseOkPair
  , normalizeCollapseMismatchPair
  , normalizeMultipleCollapses
  , normalizeNoAllDoneInMiddle
  , normalizeMismatchedIndexNoCollapse
  , normalizeDanglingRecvReport
  , checkSameTrace
  , checkDifferentTrace
  , checkBothEmpty
  , checkNormalizesToSame
  , checkEmptyVsNonEmpty
  ]

-------------------------------------------------------------------------------
-- normalize tests

normalizeEmpty :: TestTree
normalizeEmpty = testCase "normalize empty" $
  normalize [] @?= []

normalizeOnlyAllDone :: TestTree
normalizeOnlyAllDone = testCase "normalize strips sole AllStepsDone" $
  normalize [MirrorSendAllStepsDone] @?= []

normalizeWithTrailingAllDone :: TestTree
normalizeWithTrailingAllDone = testCase "normalize strips trailing AllStepsDone" $
  normalize
    [ MirrorSendInitialState act (Map.singleton (T.pack "x") (VInt 1))
    , MirrorRecvReportState 0 act
    , MirrorSendStepOk 0
    , MirrorSendAllStepsDone
    ]
  @?=
    [ MirrorSendInitialState act (Map.singleton (T.pack "x") (VInt 1))
    , MirrorSendStepOk 0
    ]
  where
    act = T.pack "init"

normalizeCollapseOkPair :: TestTree
normalizeCollapseOkPair = testCase "normalize collapses RecvReport+StepOk" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?=
    [ MirrorSendStepOk 0 ]

normalizeCollapseMismatchPair :: TestTree
normalizeCollapseMismatchPair = testCase "normalize collapses RecvReport+StepMismatch" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepMismatch 0 mismatch
    ]
  @?=
    [ MirrorSendStepMismatch 0 mismatch ]
  where
    mismatch = StateMismatch Map.empty Map.empty [ValueMismatch (T.pack "x") (VInt 1) (VInt 2)]

normalizeMultipleCollapses :: TestTree
normalizeMultipleCollapses = testCase "normalize collapses multiple pairs" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    , MirrorSendNextStep (T.pack "tick") Map.empty
    , MirrorRecvReportState 1 (T.pack "tick")
    , MirrorSendStepOk 1
    , MirrorSendAllStepsDone
    ]
  @?=
    [ MirrorSendStepOk 0
    , MirrorSendNextStep (T.pack "tick") Map.empty
    , MirrorSendStepOk 1
    ]

normalizeNoAllDoneInMiddle :: TestTree
normalizeNoAllDoneInMiddle = testCase "normalize keeps AllStepsDone if not trailing" $
  normalize
    [ MirrorSendAllStepsDone
    , MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?=
    [ MirrorSendAllStepsDone
    , MirrorSendStepOk 0
    ]

normalizeMismatchedIndexNoCollapse :: TestTree
normalizeMismatchedIndexNoCollapse = testCase "normalize does not collapse RecvReport+StepOk with different indices" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 1
    ]
  @?=
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 1
    ]

normalizeDanglingRecvReport :: TestTree
normalizeDanglingRecvReport = testCase "normalize preserves dangling RecvReport" $
  normalize
    [ MirrorRecvReportState 0 (T.pack "init")
    ]
  @?=
    [ MirrorRecvReportState 0 (T.pack "init")
    ]

-------------------------------------------------------------------------------
-- check tests

checkSameTrace :: TestTree
checkSameTrace = testCase "check returns True for identical traces" $
  let trace =
        [ MirrorSendInitialState (T.pack "init") (Map.singleton (T.pack "x") (VInt 1))
        , MirrorRecvReportState 0 (T.pack "init")
        , MirrorSendStepOk 0
        , MirrorSendAllStepsDone
        ]
   in check trace trace @?= True

checkDifferentTrace :: TestTree
checkDifferentTrace = testCase "check returns False for different traces" $
  check
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepMismatch 0 (StateMismatch Map.empty Map.empty [])
    ]
  @?= False

checkBothEmpty :: TestTree
checkBothEmpty = testCase "check [] [] returns True" $
  check [] [] @?= True

checkNormalizesToSame :: TestTree
checkNormalizesToSame = testCase "check returns True for traces that normalize to same" $ do
  let expected = [MirrorRecvReportState 0 (T.pack "tick"), MirrorSendStepOk 0]
      produced = [MirrorRecvReportState 0 (T.pack "tick"), MirrorSendStepOk 0, MirrorSendAllStepsDone]
  check expected produced @?= True

checkEmptyVsNonEmpty :: TestTree
checkEmptyVsNonEmpty = testCase "check returns False for empty vs non-empty" $
  check
    []
    [ MirrorRecvReportState 0 (T.pack "init")
    , MirrorSendStepOk 0
    ]
  @?= False
