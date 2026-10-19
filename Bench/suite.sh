#!/bin/zsh
# Flick benchmark suite: seek tests (hold / drag / click) and memory, on real screen with real input.
#
#   ./suite.sh <run-name> [reps]
#   env: PLAYERS="Flick Leah"   VIDEOS="A-hevc-4k30-gop300-long.mp4 …"   SCENARIOS="hold drag click"   MEMORY=1
#
# Writes Results/<run-name>/{raw/*.json, memory.tsv, suite.log}. Needs Screen Recording + Accessibility,
# an unlocked screen, and nobody using the Mac (it drives the keyboard and mouse). Closes every player at the end.
set -u
cd "${0:A:h}"
RUN=${1:?run name}; REPS=${2:-3}
PLAYERS=(${=PLAYERS:-Flick Leah})
VIDEOS=(${=VIDEOS:-A-hevc-4k30-gop300-long.mp4 B-h264-4k30-gop250-long.mp4 A-hevc-4k30-gop300-long.mkv B-h264-4k30-gop250-long.mkv})
SCENARIOS=(${=SCENARIOS:-hold drag click play1 play2 play4})
OUT=../Results/$RUN
mkdir -p $OUT/raw
typeset -A BAR; source ./bars.env
log() { print -r -- "$(date +%H:%M:%S) $*" | tee -a $OUT/suite.log; }

closeall() { for a in Flick Leah IINA mpv VLC; do pkill -x $a 2>/dev/null; done; sleep 1; }

# Per-run copies live outside Documents/Desktop/Downloads, so opening them never triggers a
# folder-access privacy prompt (Flick scans the video's folder for subtitle files).
CLONES=$HOME/Library/Caches/FlickBench
mkdir -p $CLONES
clone() { local c=$CLONES/$1-$(date +%s)$RANDOM-$2; cp -c ../Media/$2 $c; print -r -- $c; }

# MKV in IINA/mpv was never part of the comparison; skip unless asked.
skip() {
  [[ $2 == *.mkv && ( $1 == IINA || $1 == mpv ) && -z ${MKV_ALL:-} ]] && return 0
  [[ ( ${3:-} == play2 || ${3:-} == play4 ) && $1 == Leah ]] && return 0   # Leah has no speed control
  return 1
}

# The play tests change Flick's remembered speed; put the user's back at the end.
FLICK_RATE=$(defaults read app.flick.player rate 2>/dev/null)
restore_rate() { [[ -n $FLICK_RATE ]] && defaults write app.flick.player rate -float $FLICK_RATE || defaults delete app.flick.player rate 2>/dev/null; true; }
trap 'closeall; restore_rate; log "stopped"; exit 130' INT TERM

swiftc -O -swift-version 5 -o bench bench.swift 2>&1 | grep error: && { log "bench failed to build"; exit 1; }
log "start: window x=${BENCH_X:-0} players=$PLAYERS reps=$REPS videos=$VIDEOS scenarios=$SCENARIOS"

# --- seek tests: players interleaved per repetition ---
for rep in $(seq 1 $REPS); do
  for v in $VIDEOS; do
    for sc in $SCENARIOS; do
      for p in $PLAYERS; do
        skip $p $v $sc && continue
        out=$OUT/raw/$p-${v%.*}-${v##*.}-$sc-$rep.json
        [[ -f $out ]] && continue
        c=$(clone r$rep-$p-$sc $v)
        for attempt in 1 2; do
          if [[ $sc == hold ]]; then ./bench $p $c $sc $out >> $OUT/suite.log 2>&1
          else ./bench $p $c $sc $out --bar ${BAR[$p]} >> $OUT/suite.log 2>&1; fi
          [[ -f $out ]] && python3 check_run.py $out >> $OUT/suite.log 2>&1 && break
          log "retry $p $v $sc $rep"; [[ -f $out ]] && mv $out $out.bad
        done
        /usr/bin/trash $c 2>/dev/null
        sleep 1
      done
    done
  done
  log "rep $rep done"
done

# --- memory: app footprint + VideoToolbox decoder services, 1.5 s (busy) and 6 s (settled) after each phase ---
if [[ ${MEMORY:-1} == 1 ]]; then
  mb() { footprint -p $1 2>/dev/null | awk '/Footprint:/ {v=$(NF-5); u=$(NF-4); if (u=="GB") v*=1024; if (u=="KB") v/=1024; print int(v); exit}'; }
  vt() { local t=0 m; for q in $(pgrep -f "VTDecoderXPCService|VTEncoderXPCService"); do m=$(mb $q); t=$((t + ${m:-0})); done; print $t; }
  print "player\tvideo\tphase\tbusy_app\tbusy_vt\tsettled_app\tsettled_vt" > $OUT/memory.tsv
  for v in ${VIDEOS[1]} ${VIDEOS[3]:-}; do
    [[ -z $v ]] && continue
    for p in $PLAYERS; do
      skip $p $v && continue
      for ph in none play1 hold drag; do
        c=$(clone m-$p-$ph $v)
        BENCH_KEEP=1 ./bench $p $c $ph /dev/null --bar ${BAR[$p]} >> $OUT/suite.log 2>&1
        sleep 1.5; pid=$(pgrep -x $p | head -1)
        if [[ -n $pid ]]; then
          a1=$(mb $pid); v1=$(vt); sleep 4.5; a2=$(mb $pid); v2=$(vt)
          print "$p\t$v\t$ph\t$a1\t$v1\t$a2\t$v2" >> $OUT/memory.tsv
        else log "memory: $p not running after $ph"; fi
        closeall; /usr/bin/trash $c 2>/dev/null
      done
    done
  done
  log "memory done"
fi

closeall; restore_rate
log "SUITE DONE"
