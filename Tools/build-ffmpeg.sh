#!/bin/zsh
# Builds the trimmed FFmpeg libraries Flick bundles: the demuxers for what macOS can't open (AVI, VOB/MPEG-PS,
# MPEG-TS, Ogg/Opus, FLV, RealMedia, WMV/ASF, Matroska…, plus MP4/MOV for damaged files AVFoundation refuses),
# their video and audio decoders, swscale for unusual pixel formats and swresample (Opus needs it). LGPL 2.1: no --enable-gpl,
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
  --disable-everything --disable-avdevice --disable-avfilter \
  --enable-swscale --enable-swresample --enable-zlib \
  --enable-decoder=h264,hevc,mpeg4,h263,h263i,h263p,flv,svq1,svq3,mpeg1video,mpeg2video,mjpeg,mjpegb,dvvideo,theora,vp3,vp5,vp6,vp6a,vp6f,vp7,vp8,vp9,wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3,rv10,rv20,rv30,rv40,cinepak,msvideo1,msrle,mszh,zlib,huffyuv,ffvhuff,ffv1,prores,dnxhd,indeo2,indeo3,indeo4,indeo5,qtrle,rawvideo,png,h261,smc,rpza,eightbps,tscc,tscc2,utvideo,v210,yuv4,asv1,asv2,fraps,lagarith,magicyuv,jpeg2000,vvc,apv \
  --enable-decoder=aac,aac_latm,ac3,eac3,mp1,mp2,mp3,mp1float,mp2float,mp3float,mp3adu,opus,vorbis,flac,alac,dca,truehd,mlp,wmav1,wmav2,wmapro,wmalossless,wmavoice,cook,ra_144,ra_288,atrac1,atrac3,atrac3p,atrac9,sipr,amrnb,amrwb,gsm,gsm_ms,adpcm_ms,adpcm_ima_wav,adpcm_ima_qt,adpcm_swf,adpcm_yamaha,adpcm_g722,adpcm_g726,adpcm_g726le,adpcm_ima_dk3,adpcm_ima_dk4,adpcm_ima_oki,qdm2,qdmc,mace3,mace6,nellymoser,wavpack,ape,tta,speex,dvaudio,mpc7,mpc8,shorten,tak,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,g723_1,g729,ilbc \
  --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s16le_planar,pcm_s16be_planar,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s24daud,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_s64le,pcm_s64be,pcm_f16le,pcm_f24le,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_dvd,pcm_bluray,pcm_lxf,pcm_s8_planar,pcm_s24le_planar,pcm_s32le_planar \
  --enable-parsers \
  --enable-demuxer=avi,mpegps,mpegts,mpegtsraw,mpegvideo,m4v,h264,hevc,vvc,matroska,asf,ogg,flv,live_flv,mov,rm,wav,aiff,au,caf,flac,mp3,aac,ac3,eac3,dts,dtshd,truehd,mlp,ape,wv,tta,amr,amrnb,amrwb,dv,nut,mxf,ivf,vc1,vc1t,w64,voc,mjpeg,nsv,mpc,mpc8,shorten,tak,dsf,avs,xwma,wtv,obu,loas,gsm,g722,g723_1,g729,ilbc,smjpeg,yuv4mpegpipe,apv \
  --enable-protocol=file \
  --enable-bsf=vp9_superframe_split,mpeg4_unpack_bframes
make -j8 >/dev/null
make install DESTDIR="$VENDOR" >/dev/null
cd "$OUT/lib"
# list what was built (make-app.sh copies only the versioned dylibs the app links against), then confirm no GPL/v3/nonfree parts
ls -la *.dylib | grep -v "^l"
grep -h "^#define CONFIG_GPL\|^#define CONFIG_VERSION3\|^#define CONFIG_NONFREE" "$PWD/../../src/ffmpeg-$VER/config.h"
