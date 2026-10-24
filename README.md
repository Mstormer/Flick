# Flick

A fast 4K video player for macOS (Apple silicon), built to out-seek Leah, IINA and mpv.

- `./make-app.sh` → `build/Flick.app`
- Keys: ←/→ 5 s (Shift 1 s, Option 30 s), `,`/`.` frame step, space play/pause, `[`/`]` speed steps, `\` 1×, 1–4 set speed, ↑/↓ volume, m mute, f full screen.
- Captions: embedded MP4/MOV tracks (AVPlayer), Matroska text tracks (SRT/ASS/WebVTT), and .srt/.vtt/.ass files next to the video or added with File › Add Subtitle File… (⇧⌘O). View › Subtitles picks the track. Styled by System Settings › Accessibility › Captions; on automatically when that setting prefers captions.
- Control bar: hover over, click or drag the seek bar for a preview picture and time above it (nearest keyframe); speaker button mutes/unmutes and the volume slider sits beside it on the right.
- Menus follow the HIG: every command is in the menu bar (Playback menu lists all seek/frame/speed/volume keys plus your Settings shortcuts); File › Open Recent (with Clear Menu), ⌥R opens the most recent video; Window and Help menus; Help › Flick Help lists every shortcut.
- Settings (⌘,): configurable shortcut table (action, key, value). Defaults: V show/hide controller, A −0.1×, S +0.2×, Z −10 s, X +10 s, D reset speed (toggles 1× and back), R preferred speed 2× (toggles). Add/remove rows; saved in UserDefaults.
  `[`/`]` speed steps, s/a ±0.2×, r ×2, d or `\` 1×, 1–4 set speed, ↑/↓ volume, m mute, f full screen.
- MP4/MOV/M4V via AVPlayer; MKV/WebM read natively (built-in EBML parser + sample-buffer renderers) with H.264, HEVC, AV1 and VP9 video (VP9 through VideoToolbox's hardware decoder). Audio the system can't decode (DTS, TrueHD, Vorbis) is decoded by the bundled FFmpeg.
- WMV/ASF (WMV1/2/3, VC-1, MS-MPEG4; WMA, WMA Pro, WMA Lossless) and VP9 the hardware refuses (4:4:4) play through the bundled FFmpeg libraries, decoded in software: frame-exact seeking, frame stepping, seek-bar previews, interlaced VC-1 blended. No remuxing, nothing written to disk.
- FFmpeg: libavformat/libavcodec/libavutil 9.0.2, LGPL 2.1+, trimmed to these decoders by `Tools/build-ffmpeg.sh` (run automatically by `make-app.sh` on first build; adds 3.8 MB). Shipped as separate dylibs in Contents/Frameworks; notice in Help › Open-Source Licenses.

## Benchmark
- `Bench/make-media.sh` builds the barcoded 4K test files in `Media/`.
- `Bench/run_all.sh 3 Flick Leah IINA mpv` drives every player with real input and records the screen (needs Screen Recording + Accessibility, and nobody using the Mac).
- `Bench/analyze.py Results/raw/*.json > Results/summary.json`, then `Bench/report.py` → `Results/report.html`.
