#!/bin/zsh
# Open a player at the bench window size, hover the bottom to reveal controls, screenshot.
p=$1; f=$2
./bench $p $f none /dev/null >/dev/null 2>&1 &
