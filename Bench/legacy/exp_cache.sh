#!/bin/zsh
# Flick at several frame-cache budgets: memory after each phase + one run of each seek test per file.
cd "${0:A:h}"
typeset -A BAR; source ./bars.env
mkdir -p ../Results/cache-exp
for mb in ${=BUDGETS:-1024 512 256 64}; do
  defaults write app.flick.player cacheMB -int $mb
  VIDEOS="A-hevc-4k30-gop300-long.mp4" PLAYERS="Flick" ./memtest.sh | sed "s/^/cache=${mb} /" >> ../Results/cache-exp/memory.txt
  for v in A-hevc-4k30-gop300-long.mp4 B-h264-4k30-gop250-long.mp4; do for sc in hold drag click; do
    out=../Results/cache-exp/Flick-c${mb}-${v%%.*}-${sc}.json
    [[ -f $out ]] && continue
    clone=../Media/runs/x-$mb-$sc-$(date +%s)$RANDOM-$v; cp -c ../Media/$v $clone
    ./bench Flick $clone $sc $out --bar ${BAR[Flick]} > /dev/null 2>&1
    /usr/bin/trash $clone 2>/dev/null; sleep 1
  done; done
done
defaults delete app.flick.player cacheMB
pkill -x Flick
echo EXP DONE
