#!/bin/zsh
# Memory after each phase, player kept open: app footprint + VideoToolbox decoder services (out-of-process decode)
cd "${0:A:h}"
typeset -A BAR; source ./bars.env
mb() { footprint -p $1 2>/dev/null | awk '/Footprint:/ {v=$(NF-5); u=$(NF-4); if (u=="GB") v*=1024; if (u=="KB") v/=1024; print int(v); exit}'; }
vt() { local t=0; for p in $(pgrep -f "VTDecoderXPCService|VTEncoderXPCService"); do t=$((t + $(mb $p))); done; echo $t; }
proc() { [[ $1 == mpv ]] && pgrep -x mpv || pgrep -x $1; }
for v in ${=VIDEOS}; do for p in ${=PLAYERS}; do
  [[ $v == *.mkv && ( $p == IINA || $p == mpv ) ]] && continue
  for sc in none hold drag; do
    clone=../Media/runs/m-$p-$sc-$(date +%s)$RANDOM-$v; cp -c ../Media/$v $clone
    BENCH_KEEP=1 ./bench $p $clone $sc /dev/null --bar ${BAR[$p]} > /dev/null 2>&1
    sleep 1.5
    pid=$(proc $p | head -1)
    a1=$(mb $pid); v1=$(vt); sleep 4.5; a2=$(mb $pid); v2=$(vt)
    echo "$p $v $sc +1.5s app=${a1}MB vt=${v1}MB total=$((a1+v1))MB | +6s app=${a2}MB vt=${v2}MB total=$((a2+v2))MB"
    pkill -x $p; sleep 1; /usr/bin/trash $clone 2>/dev/null
  done
done; done
