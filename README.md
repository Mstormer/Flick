# Flick

A fast video player for macOS 14 or later (Apple silicon), built for quick seeking and smooth speed changes. It plays nearly any video or sound file.

## Install

Download the latest `Flick-x.y.z.zip` from [Releases](../../releases), unzip it, open the disk image and drag Flick to Applications. Releases are signed with a Developer ID and notarized by Apple (see [SECURITY.md](SECURITY.md)).

To build it yourself:

```bash
./make-app.sh    # builds build/Flick.app (builds the bundled FFmpeg first on a fresh checkout)
```

## Features

- **Formats:** MP4, MOV, M4V and 3GP natively; MKV/WebM through a built-in parser; AVI, VOB/MPG, TS/M2TS, FLV, WMV/ASF, RealMedia, Ogg, MXF and more through the bundled FFmpeg. Sound-only files (MP3, AAC, FLAC, Opus, Vorbis, APE, WavPack, DTS, AC-3…) play with a waveform in place of the picture.
- **Seeking:** exact frames, frame stepping, and a preview picture on the seek bar.
- **Speed:** change it while playing with no pause or mute and pitch kept. The right-hand time can show the time left at the current speed.
- **Captions:** embedded tracks, Matroska text tracks (SRT/ASS/WebVTT), and `.srt`/`.vtt`/`.ass` files next to the video or added with File › Add Subtitle File… (⇧⌘O). They follow System Settings › Accessibility › Captions.
- **Playlists:** open or drop several files or a folder. They play in one window with a list on the left.
- **Resume:** every video reopens where you left it. Playback › Clear Playback Cache forgets them all.
- **File info (I):** container, codecs, resolution, frame rate, HDR, channels, bitrate, language and which decoder is playing.
- **Colour:** SDR video matches IINA and mpv instead of macOS's lighter default.
- **Damaged files:** a cut-short file plays up to where its data stops, broken stretches are skipped, and unreadable files say so at once.
- **Gestures and menus:** pinch to resize the window. Every command is in the menu bar, and Help › Flick Help lists the shortcuts.

## Keys

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Seek 5 s (Shift 1 s, Option 30 s) |
| `,` / `.` | Step one frame back / forward |
| `[` / `]` | Slower / faster; ⌫ resets to 1×; 1–4 set the speed |
| ↑ / ↓ | Volume (past 100% raises the Mac's own volume); M mutes |
| F | Full screen |
| I | File info |
| `\` or L | Show / hide the playlist (↑/↓ switch videos while it shows, ⌥↑/⌥↓ set the volume) |
| ⌥R | Open the most recent video |

Settings (⌘,) holds a shortcut table you can edit. Defaults: V controller, A −0.1×, S +0.2×, Z −10 s, X +10 s, D reset speed, R 2×.

## How it plays

Each file is played by one of four backends, chosen when it opens:

1. **AVFoundation:** MP4/MOV/M4V. Flick's own player is used when it can; AVPlayer takes over for HDR, rotated video, several audio tracks, embedded captions and sound-only files.
2. **Matroska/WebM:** read by a built-in parser, with H.264, HEVC, AV1 and VP9 decoded by the system.
3. **FFmpeg:** software decoding for the rest (AVI, VOB, TS, FLV, WMV, VC-1…), with exact seeking and previews.
4. **FFmpeg audio:** sound-only files.

Sound goes through AVAudioEngine with a time-pitch unit and the picture follows the audio being heard, which is what keeps speed changes smooth. AVPlayer files are the exception and can hitch briefly when the speed changes.

## Development

Tests are small command-line harnesses in `Bench/`. `CLAUDE.md` has the build commands and conventions.

```bash
Bench/make-formats.sh                    # test clips, including truncated and corrupt ones
Bench/opentest/opentest file…            # opens each file off screen and checks clock and picture move, before and after a seek
Bench/colortest/colortest Media/color/*  # compares colour with mpv
```

## License

Flick is free software, copyright © 2026 Mstormer, under the [GNU General Public License v3](LICENSE) or any later version. It comes with no warranty.

## Third-party software

Flick bundles [FFmpeg](https://ffmpeg.org) 9.0.2 (libavformat, libavcodec, libavutil, libswscale, libswresample), unmodified, under the [LGPL v2.1 or later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). It is built without any GPL, version-3 or nonfree parts by `Tools/build-ffmpeg.sh`, limited to the demuxers and decoders Flick needs, and shipped as separate dynamic libraries. Each release attaches the exact FFmpeg source tarball. The license text, build configuration and notice are in Help › Open-Source Licenses and the About box. FFmpeg is a trademark of Fabrice Bellard.
