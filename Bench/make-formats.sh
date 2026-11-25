#!/bin/zsh
# Test clips for the formats only FFmpeg opens (AVI, VOB, TS, FLV, Ogg/Opus, RealMedia…) and damaged files:
# truncated, corrupted in the middle, no index, garbage, empty. Written to Media/formats (not in git).
set -e
mkdir -p "${0:A:h}/../Media/formats"; cd "${0:A:h}/../Media/formats"
ff() { ffmpeg -y -v error "$@"; }
src=(-f lavfi -i "testsrc2=s=720x480:r=30000/1001:d=20" -f lavfi -i "sine=f=440:d=20:sample_rate=48000")
ff $src -c:v mpeg4 -vtag XVID -q:v 4 -bf 2 -c:a libmp3lame -b:a 128k -ac 2 divx-mp3.avi
ff $src -c:v msmpeg4v3 -q:v 4 -c:a pcm_s16le div3-pcm.avi
ff $src -c:v libx264 -preset veryfast -c:a ac3 h264-ac3.avi
ff $src -c:v cinepak -c:a pcm_alaw -ar 8000 -ac 1 cinepak-alaw.avi
ff $src -c:v dvvideo -s 720x480 -pix_fmt yuv411p -c:a pcm_s16le -ar 48000 dv-ntsc.avi
ff $src -c:v mpeg2video -b:v 5M -c:a ac3 -b:a 192k -f vob dvd.vob
ff $src -c:v mpeg2video -b:v 5M -c:a mp2 mpeg2.mpg
ff $src -c:v libx264 -preset veryfast -c:a aac broadcast.ts
ff $src -c:v flv -q:v 4 -c:a libmp3lame -ar 44100 old.flv
ff $src -c:v rv20 -q:v 4 -an real.rm
ff -f lavfi -i "sine=f=330:d=30:sample_rate=48000" -c:a libopus -b:a 96k voice.opus
ff -f lavfi -i "sine=f=550:d=30:sample_rate=44100" -c:a libmp3lame -b:a 128k song.mp3
ff -f lavfi -i "sine=f=660:d=30:sample_rate=44100" -c:a flac lossless.flac
ff -f lavfi -i "sine=f=770:d=30:sample_rate=44100" -c:a ac3 surround.ac3
# sound only FFmpeg decodes (macOS has no decoder for these)
ff -f lavfi -i "sine=f=440:d=30:sample_rate=44100" -c:a vorbis -strict -2 -ac 2 vorbis.ogg
ff -f lavfi -i "sine=f=495:d=30:sample_rate=44100" -c:a wavpack pack.wv
ff -f lavfi -i "sine=f=587:d=30:sample_rate=44100" -c:a wmav2 windows.wma
ff -f lavfi -i "sine=f=622:d=30:sample_rate=44100" -c:a vorbis -strict -2 -ac 2 audio.mka
ff $src -c:v libx264 -preset veryfast -c:a aac -movflags +faststart whole.mp4
ff $src -c:v libx264 -preset veryfast -c:a aac moov-at-end.mp4
ff $src -c:v libx264 -preset veryfast -c:a aac whole.mkv

# damage: cut off half way (no index at the end, or no moov at all), garbage in the middle, nonsense, nothing
cut() { head -c $(( $(stat -f%z $1) * ${3:-50} / 100 )) $1 > $2; }
cut divx-mp3.avi broken-truncated.avi
cut dvd.vob broken-truncated.vob
cut broadcast.ts broken-truncated.ts
cut voice.opus broken-truncated.opus
cut whole.mp4 broken-truncated.mp4
cut moov-at-end.mp4 broken-no-moov.mp4
cut whole.mkv broken-truncated.mkv
smash() {   # overwrite 8 blocks of 4 KB in the middle 60% with random bytes
  cp $1 $2; local n=$(stat -f%z $2)
  for i in 1 2 3 4 5 6 7 8; do
    dd if=/dev/urandom of=$2 bs=4096 count=1 seek=$(( (n * (20 + i * 7) / 100) / 4096 )) conv=notrunc 2>/dev/null
  done
}
smash divx-mp3.avi broken-corrupt.avi
smash dvd.vob broken-corrupt.vob
smash broadcast.ts broken-corrupt.ts
smash whole.mkv broken-corrupt.mkv
smash whole.mp4 broken-corrupt.mp4
head -c 2000000 /dev/urandom > broken-garbage.avi
: > broken-empty.avi
ls -la
