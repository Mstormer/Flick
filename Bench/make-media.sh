#!/bin/zsh
# Builds the 4K test corpus. Every frame carries a 16-bit frame-number barcode
# (top row = bits, bottom row = inverted bits) at x=1920..3456, y=600..696,
# so a screen capture can tell exactly which frame a player is showing.
set -e
cd "${0:A:h}/../Media"
SRC="$HOME/Desktop/iPhone TurkeyGreece"
BAR="color=c=black:s=1536x96:r=RATE,format=gray,geq=lum='if(lt(Y,48), if(mod(floor(N/pow(2,floor(X/96))),2),235,16), if(mod(floor(N/pow(2,floor(X/96))),2),16,235))'"
STAMP="[0:v]setpts=N/(RATE*TB),fps=RATE[v];BAR[b];[v][b]overlay=1920:600:shortest=1,format=yuv420p[o]"

if [[ ! -f dji-concat.mp4 ]]; then
  : > list.txt
  for r in 1 2; do for f in DJI_0845 DJI_0851 DJI_0855 DJI_0886 DJI_0902; do echo "file '$SRC/$f.mp4'" >> list.txt; done; done
  ffmpeg -y -v error -f concat -safe 0 -i list.txt -an -c copy dji-concat.mp4
fi
# 16-minute version so a held arrow key (30 repeats/s x 5 s) never reaches the end
if [[ ! -f dji-long.mp4 ]]; then
  ffmpeg -y -v error -stream_loop 5 -i dji-concat.mp4 -c copy dji-long.mp4
fi

# A: real drone footage, HEVC 4K30, 10 s GOP (what DJI/iPhone cameras actually write)
f=${STAMP//RATE/30000\/1001}; f=${f//BAR/${BAR//RATE/30000\/1001}}
[[ -f A-hevc-4k30-gop300-long.mp4 ]] || ffmpeg -y -v error -i dji-long.mp4 -filter_complex "$f" -map '[o]' \
  -c:v hevc_videotoolbox -b:v 40M -g 300 -tag:v hvc1 A-hevc-4k30-gop300-long.mp4

# B: same footage, H.264 High 4K30, x264 keyint 250 + 3 B-frames (typical web download)
[[ -f B-h264-4k30-gop250-long.mp4 ]] || ffmpeg -y -v error -i dji-long.mp4 -filter_complex "$f" -map '[o]' \
  -c:v libx264 -preset veryfast -crf 20 -g 250 -bf 3 B-h264-4k30-gop250-long.mp4

# C: synthetic 4K60 HEVC 10-bit in Matroska, 2 s GOP, with stereo audio
f=${STAMP//RATE/60}; f=${f//BAR/${BAR//RATE/60}}
# C kept short (format test only)
# Matroska copies of the long files (same video, plus a mono 48 kHz AAC tone so the MKV audio path is exercised)
for v in A-hevc-4k30-gop300-long B-h264-4k30-gop250-long; do
  [[ -f $v.mkv ]] || ffmpeg -y -v error -i $v.mp4 -f lavfi -i "sine=f=440:r=48000" -map 0:v -map 1:a -c:v copy -c:a aac -ac 1 -shortest $v.mkv
done
[[ -f C-hevc10-4k60.mkv ]] || ffmpeg -y -v error -f lavfi -i "testsrc2=s=3840x2160:r=60:d=120" -f lavfi -i "sine=f=440:d=120" \
  -filter_complex "${f/format=yuv420p/noise=alls=12:allf=t,format=p010le}" -map '[o]' -map 1:a \
  -c:v hevc_videotoolbox -profile:v main10 -b:v 50M -g 120 -c:a aac C-hevc10-4k60.mkv
ls -la
