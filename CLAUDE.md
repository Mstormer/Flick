# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Flick is a macOS 14+ (Apple silicon) video player in Swift and AppKit (no SwiftUI, no Xcode project, no package manager). README.md is the feature list and must stay true to the code.

## Commands

```bash
./make-app.sh                       # builds build/Flick.app (runs Tools/build-ffmpeg.sh first if Vendor/ffmpeg is missing)
```

Type-check without building (fast, writes nothing):

```bash
swiftc -typecheck -swift-version 5 -target arm64-apple-macos14 Player/*.swift -I Player/CFFmpeg -Xcc -IVendor/ffmpeg/include
```

There is no unit-test target. Tests are small command-line harnesses in `Bench/<name>/main.swift`, each compiled together with all of `Player/*.swift` except `Player/main.swift`. Build one (replace `opentest` with `colortest`; both need `Bench/Park.swift`):

```bash
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o Bench/opentest/opentest $(print -l Player/*.swift | grep -v /main.swift) Bench/Park.swift Bench/opentest/main.swift -I Player/CFFmpeg -Xcc -IVendor/ffmpeg/include -L Vendor/ffmpeg/lib -Xlinker -rpath -Xlinker $PWD/Vendor/ffmpeg/lib
```

- `Bench/make-formats.sh` generates the test clips in `Media/formats` (FFmpeg-only formats, sound-only files, and `broken-*` truncated/corrupt/garbage files). `Bench/make-fftest.sh` and `Bench/make-media.sh` make the other corpora. `Media/`, `Results/`, `Vendor/` and `build/` are not in git.
- `Bench/opentest/opentest file…` opens each file as the app would and checks that the clock and the picture move, before and after a seek; one file is a single test. A `broken-*` file that reports "can't open" counts as a pass. Exits 1 on any failure. Two sample files are known failures, not regressions: `Test_1440x576_WVC1_6Mbps.wmv` and `VC1_interlaced_1080i60_with_artifacts_crashes.mkv`.
- `Bench/colortest/colortest Media/color/*` compares a grey ramp with mpv's values (expected: FFmpeg path max diff 1, native path mean 1).
- `Bench/suite.sh` is the seek/memory benchmark against other players. It drives the real keyboard and mouse, so run it only when asked.

Diagnostics: `FLICK_TRACE=/path/to/log` (or the `trace` user default) turns on `Trace.log`; `FLICK_NO_ENGINE=1` disables the scrub engine.

## Rules for test harnesses

- A harness that opens a window must keep it off the screen the mouse is on and never take focus: use `Bench/Park.swift` (`adopt`, `park`, `spin`, `capture`). The window is borderless, transparent except during a capture, with only a 2×2-pt corner on another screen. ScreenCaptureKit cannot capture a window that is fully off screen. The older harnesses (`captest`, `uitest`, `settingstest`) do not park their windows.
- Set `PlayerView.startMuted = true` so nothing is heard.
- `Bench/Park.swift` holds declarations only: globals outside `main.swift` initialise lazily, so each tool's process setup (activation policy, `beginActivity`) stays in its own `main.swift`.

## Architecture

All app code is in `Player/`. A file is played by one of four backends behind the `Playback` protocol (`Playback.swift`); `PlayerView.load` in `App.swift` picks one, in this order:

1. **AVFoundation can open it** (and it is not an MPEG program/transport stream with video): `NativePlayback` if `MediaIndex` can be built and VideoToolbox decodes it, else `AVPlayerPlayback` (HDR, rotation, several audio tracks, embedded captions, sound-only files).
2. **Matroska/WebM**: the built-in EBML parser (`MKV.swift`) feeds the same `NativePlayback`.
3. **`FFPlayback`** (`FFmpeg.swift`): software video through the bundled FFmpeg (AVI, VOB, TS, FLV, WMV, VC-1…).
4. **`FFAudioPlayback`**: sound only, when FFmpeg finds no video it can decode.
5. Otherwise `openFailed` is set and the window says it can't open the file.

Things that span files:

- **Every file gets a new `PlayerView`.** `load` runs once per view, in a main-actor `Task` with many `await`s; `teardown()` sets `tornDown`, and anything that resumes after an `await` must check it before starting playback. `adopt(_:)` is the one place a backend is installed.
- **`MediaIndex` (`Engine.swift`)** is the sample table over an mmap of the file. It hands byte ranges straight to VideoToolbox, so it is only valid where a sample is one contiguous frame: MP4/MOV/3GP (`readsSamplesDirectly`) and Matroska. Samples past the end of a truncated file are trimmed.
- **Two decoders share one video.** `NativePlayback` plays; `ScrubEngine` (`Engine.swift`) decodes exact frames for seeking, stepping and previews onto a separate scrub layer. `PlayerView` hands the screen between them (`target`, `settle`, `pendingTrim`), and the backend's pending seeks are cancelled first because both use the hardware decoder.
- **Clock and sound.** Native and FFmpeg backends show pictures on an `AVSampleBufferDisplayLayer` driven by an `AVSampleBufferRenderSynchronizer`; audio goes through `SyncedAudio` (`AudioOut.swift`) from an `AudioSource` (`MKVAudio`, `FFAudio`, …). Each backend has its own serial queue; state crossing between it and main goes through `Locked` or a generation counter (`gen`, `wanted`).
- **Damaged files.** `FFDemux` skips read errors and checks that a seek landed on a keyframe near its target. `FFDecoder` skips decode errors and gives up only after a long run of them. After 3 hardware decode errors in a row, `NativePlayback.onDamaged` makes `PlayerView.decodeDamaged` switch to `FFPlayback` at the same moment.
- **Colour (`DisplayTone` in `Codecs.swift`).** macOS renders BT.709-tagged SDR lighter than mpv/IINA. FFmpeg-decoded pixel buffers are tagged with the sRGB transfer; VideoToolbox format descriptions get gamma 2.2 (each path ignores the other tag). PQ and HLG are left alone. AVPlayer's pictures cannot be retagged, which is why MPEG-PS/TS video is sent to FFmpeg.
- **Untrusted input.** `MKV.swift` and the FFmpeg wrappers parse hostile files: every size, count, timestamp and time base from a file must be bounds-checked or clamped before arithmetic or `Int32(...)` conversions, which trap.

## FFmpeg

`Tools/build-ffmpeg.sh` builds FFmpeg 9.0.2 from the unmodified tarball into `Vendor/ffmpeg`, LGPL only (no `--enable-gpl`, `--enable-version3` or `--enable-nonfree`), limited to an explicit list of demuxers and decoders. Swift calls the C API directly through the `CFFmpeg` module (`Player/CFFmpeg/shim.h`, `module.modulemap`). `make-app.sh` bundles five dylibs separately in `Contents/Frameworks` so users can replace them.

Adding a format touches several places that must agree: the `--enable-demuxer`/`--enable-decoder` lists in `Tools/build-ffmpeg.sh`, `Playlist.extraExtensions`, the document types and imported UTIs in the Info.plist inside `make-app.sh`, and the lists in `README.md`, `Player/Licenses.txt` and the Help text in `Menus.swift`. A new library also needs `shim.h`, `module.modulemap` and the dylib loop in `make-app.sh`.

## Conventions

- Only public, non-deprecated Apple APIs.
- The code is deliberately dense: long lines, short names, and comments that say why in plain words. Keep that style; don't reformat.
- Every command must be reachable from the menu bar (`Menus.swift`); user shortcuts are the table in `Settings.swift`.
- The version and build number are in the Info.plist inside `make-app.sh`.
- Commit messages are past tense ("Added X"), and commits are made only when asked.
