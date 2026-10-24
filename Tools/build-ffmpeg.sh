#!/bin/zsh
# Builds the trimmed FFmpeg libraries Flick bundles: only the decoders macOS lacks (WMV/VC-1, WMA,
# VP9 fallback, DTS, TrueHD, Vorbis) and the ASF/Matroska demuxers. LGPL 2.1: no --enable-gpl,
# no --enable-version3, no --enable-nonfree. Shared libraries, so users can swap in their own build.
# Output: Vendor/ffmpeg/{include,lib}. Source: the unmodified release tarball, kept in Vendor/src.
set -e
cd "${0:A:h}/.."
VER=9.0.2
SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
VENDOR=$PWD/Vendor
OUT=$VENDOR/ffmpeg
mkdir -p Vendor/src
cd Vendor/src
[[ -f ffmpeg-$VER.tar.xz ]] || curl -sSfLO https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz
echo "$SHA  ffmpeg-$VER.tar.xz" | shasum -a 256 -c -
[[ -d ffmpeg-$VER ]] || tar xf ffmpeg-$VER.tar.xz
cd ffmpeg-$VER
# a neutral prefix (the libraries embed their configure line), installed into Vendor/ffmpeg via DESTDIR
./configure --prefix=/ffmpeg --install-name-dir=@rpath \
  --arch=arm64 --cc=clang --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
  --enable-shared --disable-static --disable-programs --disable-doc --disable-network --disable-autodetect \
  --disable-everything --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
  --enable-zlib \
  --enable-decoder=wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmav1,wmav2,wmapro,wmalossless,wmavoice \
  --enable-decoder=vp9,dca,truehd,mlp,vorbis \
  --enable-parser=vc1,vp9,dca,mlp \
  --enable-demuxer=asf,matroska \
  --enable-protocol=file \
  --enable-bsf=vp9_superframe_split
make -j8 >/dev/null
make install DESTDIR="$VENDOR" >/dev/null
cd "$OUT/lib"
# keep only the versioned dylibs the app links against
ls -la *.dylib | grep -v "^l"
grep -h "^#define CONFIG_GPL\|^#define CONFIG_VERSION3\|^#define CONFIG_NONFREE" "$PWD/../../src/ffmpeg-$VER/config.h"
