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
