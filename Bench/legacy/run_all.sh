#!/bin/zsh
# Runs the full black-box suite. Players are interleaved per repetition so thermal/background drift
# hits everyone equally. Each run opens a fresh APFS clone of the video (instant, no extra disk) so no
# player can resume from a remembered position.
#   usage: run_all.sh [reps] [players...]
cd "${0:A:h}"
REPS=${1:-3}; shift
PLAYERS=(${@:-Flick Leah IINA mpv VLC})
typeset -A BAR
source ./bars.env   # BAR[player]="x0,x1,yFromBottom" in window points, measured from screenshots
mkdir -p ../Results/raw ../Media/runs
for rep in $(seq 1 $REPS); do
  for video in ${=VIDEOS:-A-hevc-4k30-gop300-long.mp4 B-h264-4k30-gop250-long.mp4}; do
    for sc in ${=SCENARIOS:-hold drag click}; do
      for p in $PLAYERS; do
        out=../Results/raw/${p}-${video%%.*}-${sc}-${rep}.json
        [[ -f $out ]] && continue
        clone=../Media/runs/r${rep}-${p}-${sc}-$(date +%s)$RANDOM-${video}
        cp -c ../Media/$video $clone
        for attempt in 1 2; do
          if [[ $sc == hold ]]; then ./bench $p $clone $sc $out
          else ./bench $p $clone $sc $out --bar ${BAR[$p]}; fi
          [[ -f $out ]] && python3 check_run.py $out && break
          echo "RETRY $p $video $sc $rep"; mv $out $out.bad 2>/dev/null
        done
        /usr/bin/trash $clone 2>/dev/null
        sleep 1
      done
    done
  done
done
