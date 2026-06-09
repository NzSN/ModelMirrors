-- | Normalize 'MirrorStep' sequences and compare them structurally.
-- 
-- This module provides a lightweight trace comparison ('check') that works on
-- full 'MirrorStep' values rather than collapsing to action names.
--
-- Relationship to 'Protocol.Mirror.normalizeMirrorSteps':
--
-- * 'normalizeMirrorSteps' in "Protocol.Mirror" converts 'MirrorStep's to
--   @['Text']@ (action names), dropping /all/ 'MirrorSendAllStepsDone'
--   occurrences and collapsing every @ReportState@+@StepOk/@/@Mismatch@ pair
--   into a single @\"MirrorRecvReportState\"@ string — suitable for model-based
--   testing (MBT) protocol-level comparisons.
--
-- * This module's 'normalize' preserves 'MirrorStep' values (the concrete
--   steps, not just their names), only strips /trailing/
--   'MirrorSendAllStepsDone' (via 'stripTrailingDone'), and collapses
--   @ReportState@+result pairs into the /result/ step (keeping step identity
--   and diff payloads).  This enables structural comparison where step
--   identity and payloads matter.
module MinimalTraceCheck
  ( normalize
  , check
  ) where

import Protocol.Mirror (MirrorStep (..))

stripTrailingDone :: [MirrorStep] -> [MirrorStep]
stripTrailingDone = reverse . dropWhile isDone . reverse
  where
    isDone MirrorSendAllStepsDone = True
    isDone _ = False

collapsePairs :: [MirrorStep] -> [MirrorStep]
collapsePairs = go
  where
    go [] = []
    go (MirrorRecvReportState i1 _ : MirrorSendStepOk i2 : rest) | i1 == i2 =
      MirrorSendStepOk i2 : go rest
    go (MirrorRecvReportState i1 _ : MirrorSendStepMismatch i2 diff : rest) | i1 == i2 =
      MirrorSendStepMismatch i2 diff : go rest
    go (x : xs) = x : go xs

normalize :: [MirrorStep] -> [MirrorStep]
normalize = collapsePairs . stripTrailingDone

check :: [MirrorStep] -> [MirrorStep] -> Bool
check expected produced = normalize expected == normalize produced
