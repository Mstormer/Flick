#!/bin/zsh
# Test clips for the FFmpeg path: every frame carries a 16-bit frame-number barcode at 40,200 (640x48)
set -e
mkdir -p "${0:A:h}/../Media/fftest"; cd "${0:A:h}/../Media/fftest"
bar() { print -r -- "color=c=black:s=${1}x${2}:r=${3},format=gray,geq=lum='if(lt(Y,$(( $2/2 ))), if(mod(floor(N/pow(2,floor(X/$(( $1/16 ))))),2),235,16), if(mod(floor(N/pow(2,floor(X/$(( $1/16 ))))),2),16,235))'"; }
stamp() { print -r -- "[0:v]setpts=N/(${3}*TB),fps=${3}[v];$(bar $1 $2 $3)[b];[v][b]overlay=40:200:shortest=1,format=${4:-yuv420p}[o]"; }
ff() { ffmpeg -y -v error "$@"; }
ff -f lavfi -i "testsrc2=s=720x480:r=30000/1001:d=30" -f lavfi -i "sine=f=440:d=30" -filter_complex "$(stamp 640 48 30000/1001)" \
   -map '[o]' -map 1:a -c:v wmv2 -b:v 3M -c:a wmav2 -b:a 128k -g 300 wmv2-sd.wmv
ff -f lavfi -i "testsrc2=s=1920x1080:r=30:d=20" -f lavfi -i "sine=f=330:d=20" -filter_complex "$(stamp 640 48 30)" \
   -map '[o]' -map 1:a -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 6M -g 120 -c:a libopus vp9-1080.webm
ff -f lavfi -i "testsrc2=s=1920x1080:r=30:d=10" -filter_complex "$(stamp 640 48 30 yuv420p10le)" \
   -map '[o]' -c:v libvpx-vp9 -profile:v 2 -deadline realtime -cpu-used 8 -b:v 6M -g 120 vp9-10bit.webm
ff -f lavfi -i "testsrc2=s=1280x720:r=24:d=20" -f lavfi -i "sine=f=220:d=20:sample_rate=48000" -filter_complex "$(stamp 640 48 24);[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" \
   -map '[o]' -map '[a]' -c:v h264_videotoolbox -b:v 4M -c:a dca -strict -2 -b:a 768k h264-dts.mkv
ff -f lavfi -i "testsrc2=s=1280x720:r=24:d=20" -f lavfi -i "sine=f=550:d=20:sample_rate=48000" -filter_complex "$(stamp 640 48 24)" \
   -map '[o]' -map 1:a -c:v h264_videotoolbox -b:v 4M -c:a truehd -strict -2 h264-truehd.mkv
ff -f lavfi -i "testsrc2=s=1280x720:r=24:d=20" -f lavfi -i "sine=f=660:d=20" -filter_complex "$(stamp 640 48 24)" \
   -map '[o]' -map 1:a -c:v h264_videotoolbox -b:v 4M -c:a vorbis -strict -2 -ac 2 h264-vorbis.mkv
# VP9 4:4:4 (profile 1): VideoToolbox refuses it, so it exercises the software VP9 path
ff -f lavfi -i "testsrc2=s=1280x720:r=30:d=10" -f lavfi -i "sine=f=770:d=10" -filter_complex "$(stamp 640 48 30 yuv444p)" \
   -map '[o]' -map 1:a -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 4M -g 60 -c:a libopus vp9-444.webm
ls -la
