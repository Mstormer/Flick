"""Build Results/report.html from Results/summary.json + raw runs.  python3 report.py"""
import json, glob, os, html

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, "..", "Results")
S = json.load(open(os.path.join(R, "summary.json")))["summary"]
PLAYERS = ["Flick", "Leah", "IINA", "mpv"]
VIDEOS = {"A-hevc-4k30-gop300-long.mp4": "MP4 · HEVC 4K30 · 10 s GOP (drone footage)",
          "B-h264-4k30-gop250-long.mp4": "MP4 · H.264 4K30 · x264 GOP≤250, B-frames",
          "A-hevc-4k30-gop300-long.mkv": "MKV · HEVC 4K30 · 10 s GOP + AAC",
          "B-h264-4k30-gop250-long.mkv": "MKV · H.264 4K30 · B-frames + AAC"}
VIDEOS = {k: v for k, v in VIDEOS.items() if any(r["video"] == k for r in S)}

def leah_ahead():
    out = []
    for video, vlabel in VIDEOS.items():
        for sc, key, label, unit, hib, note in METRICS:
            f, l = get(video, sc, "Flick", key), get(video, sc, "Leah", key)
            if f is None or l is None or abs(f - l) / max(f, l, 1e-9) < 0.03: continue
            if (l > f) if hib else (l < f):
                out.append(f"<li>{html.escape(label)} on {html.escape(vlabel.split(' · ')[0])} {html.escape(vlabel.split(' · ')[1])}: Leah {l:.0f}{unit}, Flick {f:.0f}{unit}.</li>")
    return "".join(out) or "<li>None of the measured metrics.</li>"

def get(video, sc, player, key):
    for r in S:
        if r["video"] == video and r["scenario"] == sc and r["player"] == player:
            return r.get(key)
    return None

METRICS = [
    # scenario, key, label, unit, higher_is_better, note
    ("hold", "updates_per_s", "Held skip key: new pictures per second", "/s", True,
     "Skip key held 4 s at 30 repeats/s. Counts every time the picture on screen changed."),
    ("hold", "first_response_ms", "Held skip key: first picture after key-down", "ms", False, ""),
    ("hold", "max_freeze_ms", "Held skip key: longest frozen stretch", "ms", False, ""),
    ("drag", "updates_per_s", "Seek-bar drag: new pictures per second", "/s", True,
     "Pointer swept 5%→95% of the bar in 3 s, rested 0.5 s, swept back to 30% in 1.5 s. Rest excluded."),
    ("drag", "first_response_ms", "Seek-bar drag: first picture after mouse-down", "ms", False, ""),
    ("drag", "max_freeze_ms", "Seek-bar drag: longest frozen stretch while moving", "ms", False, ""),
    ("drag", "settle_ms", "Seek-bar drag: release → final picture", "ms", False, ""),
    ("click", "first_picture_ms", "Click on seek bar: first new picture", "ms", False,
     "12 clicks at random positions, 1.6 s apart. Median per run, median of 3 runs."),
    ("click", "final_picture_ms", "Click on seek bar: exact frame on screen", "ms", False, ""),
]

COLORS = {"Flick": "var(--flick)", "Leah": "var(--leah)", "IINA": "var(--other)", "mpv": "var(--other2)"}

def bars(video, sc, key, unit, hib):
    vals = [(p, get(video, sc, p, key)) for p in PLAYERS]
    vals = [(p, v) for p, v in vals if v is not None]
    top = max(v for _, v in vals) or 1
    best = (max if hib else min)(v for _, v in vals)
    rows = []
    for p, v in vals:
        w = max(0.6, 100 * v / top)
        txt = f"{v:.0f}" if v >= 10 else f"{v:.1f}"
        win = ' class="win"' if v == best else ""
        rows.append(f'<div class="row"><span class="who">{p}</span><span class="track"><span class="fill" style="width:{w:.1f}%;background:{COLORS[p]}"></span></span><span class="val"{win}>{txt}<small>{unit}</small></span></div>')
    return "\n".join(rows)

def verdict(video, sc, key, hib):
    f, l = get(video, sc, "Flick", key), get(video, sc, "Leah", key)
    if f is None or l is None: return ""
    better = f > l if hib else f < l
    if abs(f - l) / max(f, l) < 0.03: return '<span class="tag tie">tie with Leah</span>'
    ratio = (f / l) if hib else (l / f)
    return f'<span class="tag {"good" if better else "bad"}">{"Flick" if better else "Leah"} ahead · {ratio if better else 1/ratio:.1f}×</span>'

def strip(player):
    f = glob.glob(os.path.join(R, "raw", f"{player}-A-hevc-4k30-gop300-long-drag-1.json"))[0]
    d = json.load(open(f)); ins = d["inputs"]
    t0 = [e["t"] for e in ins if e["kind"] == "down"][-1]
    tu = [e["t"] for e in ins if e["kind"] == "up"][-1]
    rest = [e["t"] for e in ins if e["kind"] == "dragRest"][0]
    ticks, last = [], None
    for t, n in sorted(d["frames"]):
        if n < 0: continue
        if last is not None and n != last and t0 <= t <= tu: ticks.append(t - t0)
        last = n
    W, span = 1000, tu - t0
    xs = "".join(f'<rect x="{x / span * W:.1f}" y="2" width="1.6" height="26" />' for x in ticks)
    r0, r1 = (rest - t0) / span * W, (rest + 0.5 - t0) / span * W
    return f'''<div class="strip"><span class="who">{player}</span><svg viewBox="0 0 {W} 30" preserveAspectRatio="none" role="img" aria-label="{player}: {len(ticks)} picture changes during a 5 s drag">
<rect class="restband" x="{r0:.1f}" y="0" width="{r1 - r0:.1f}" height="30"/><g style="fill:{COLORS[player]}">{xs}</g></svg><span class="val">{len(ticks)}</span></div>'''

sections = []
for video, vlabel in VIDEOS.items():
    cards = []
    for sc, key, label, unit, hib, note in METRICS:
        cards.append(f'''<article class="metric"><header><h4>{label}</h4>{verdict(video, sc, key, hib)}</header>
<p class="dir">{"higher is better" if hib else "lower is better"}{(" · " + note) if note else ""}</p>{bars(video, sc, key, unit, hib)}</article>''')
    sections.append(f'<section class="video"><h3>{vlabel}</h3><div class="grid">{"".join(cards)}</div></section>')

strips = "\n".join(strip(p) for p in PLAYERS)

page = f'''<title>Flick vs Leah Seek Bench</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:wght@400;600;800&family=JetBrains+Mono:wght@400;600&display=swap">
<style>
/* Layout: a single lab-report column; each metric is a small bar chart card in a 2-up grid per test file. */
:root {{
  --bg: #f4f4f7; --surface: #ffffff; --ink: #17161d; --muted: #63606f; --line: #dddbe5;
  --flick: #5b34e8; --leah: #e0721f; --other: #8f8c9c; --other2: #b5b2c0;
  --good: #1f8a52; --bad: #c2412d; --rest: #ecebf2;
  --display: "Schibsted Grotesk", "Helvetica Neue", Arial, sans-serif;
  --mono: "JetBrains Mono", ui-monospace, Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #111017; --surface: #1a1922; --ink: #ecebf3; --muted: #a09dae; --line: #2d2b38;
  --flick: #9479ff; --leah: #f39a4f; --other: #7d7a8a; --other2: #5b5868;
  --good: #4cc483; --bad: #f07a63; --rest: #23212d; color-scheme: dark }} }}
:root[data-theme="dark"] {{
  --bg: #111017; --surface: #1a1922; --ink: #ecebf3; --muted: #a09dae; --line: #2d2b38;
  --flick: #9479ff; --leah: #f39a4f; --other: #7d7a8a; --other2: #5b5868;
  --good: #4cc483; --bad: #f07a63; --rest: #23212d; color-scheme: dark }}
* {{ box-sizing: border-box }}
body {{ background: var(--bg); color: var(--ink); font: 15px/1.55 var(--display);
  padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); padding-block: 32px 64px }}
main {{ max-width: 1040px; margin: 0 auto; display: flex; flex-direction: column; gap: 40px }}
h1 {{ font-size: clamp(30px, 5vw, 46px); line-height: 1.05; font-weight: 800; letter-spacing: -0.02em; margin: 0; text-wrap: balance }}
h2 {{ font-size: 22px; margin: 0 0 12px; text-wrap: balance }}
h3 {{ font-size: 15px; font-family: var(--mono); font-weight: 600; margin: 0 0 14px; color: var(--muted); letter-spacing: 0.02em }}
h4 {{ font-size: 14px; margin: 0; font-weight: 600 }}
p {{ margin: 0; max-width: 68ch }}
.lede {{ display: flex; flex-direction: column; gap: 14px }}
.lede p {{ color: var(--muted); font-size: 17px }}
.kicker {{ font-family: var(--mono); font-size: 12px; text-transform: uppercase; letter-spacing: 0.12em; color: var(--flick) }}
.headline {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px }}
.headline div {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px }}
.headline b {{ display: block; font-family: var(--mono); font-size: 26px; font-variant-numeric: tabular-nums }}
.headline span {{ color: var(--muted); font-size: 13px }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px }}
.metric {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; min-width: 0 }}
.metric header {{ display: flex; justify-content: space-between; gap: 8px; align-items: baseline; flex-wrap: wrap }}
.dir {{ font-size: 12px; color: var(--muted) }}
.row, .strip {{ display: grid; grid-template-columns: 52px 1fr 76px; align-items: center; gap: 10px }}
.who {{ font-family: var(--mono); font-size: 12px; color: var(--muted) }}
.track {{ height: 12px; background: var(--rest); border-radius: 3px; overflow: hidden }}
.fill {{ display: block; height: 100%; border-radius: 3px }}
.val {{ font-family: var(--mono); font-size: 13px; text-align: right; font-variant-numeric: tabular-nums }}
.val small {{ color: var(--muted); margin-left: 2px; font-size: 11px }}
.val.win {{ font-weight: 600 }}
.tag {{ font-family: var(--mono); font-size: 11px; padding: 2px 7px; border-radius: 99px; border: 1px solid currentColor; white-space: nowrap }}
.tag.good {{ color: var(--good) }} .tag.bad {{ color: var(--bad) }} .tag.tie {{ color: var(--muted) }}
.strips {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 16px; display: flex; flex-direction: column; gap: 10px }}
.strip svg {{ width: 100%; height: 30px; display: block }}
.restband {{ fill: var(--rest) }}
.axis {{ display: grid; grid-template-columns: 52px 1fr 76px; gap: 10px; font-family: var(--mono); font-size: 11px; color: var(--muted) }}
.axis span:nth-child(2) {{ display: flex; justify-content: space-between }}
.cols {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 24px }}
.cols > div {{ min-width: 0; display: flex; flex-direction: column; gap: 10px }}
ul {{ margin: 0; padding-left: 18px; display: flex; flex-direction: column; gap: 6px }}
li {{ max-width: 68ch }}
code {{ font-family: var(--mono); font-size: 13px; background: var(--rest); padding: 1px 5px; border-radius: 4px }}
.legend {{ display: flex; gap: 16px; flex-wrap: wrap; font-family: var(--mono); font-size: 12px; color: var(--muted) }}
.legend i {{ display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: -1px }}
</style>
<main>
<section class="lede">
  <span class="kicker">Black-box seek benchmark · M1 Max · 120 Hz display</span>
  <h1>Flick out-seeks Leah, IINA and mpv on 4K footage</h1>
  <p>Leah's developer said its benchmark was "repeated seek performance on multiple 4K videos" and "drop frames count on drag", and that Leah beats IINA, VLC and mpv. Flick is a new player built to that brief. Every player below was driven by the same real keyboard and mouse events and recorded off the screen at 120 Hz. Each test video carries a frame-number barcode, so every number is read from what actually appeared on screen, never from the player's own logs.</p>
</section>

<section class="headline">
  <div><b>{get("A-hevc-4k30-gop300-long.mp4","hold","Flick","updates_per_s"):.0f} vs {get("A-hevc-4k30-gop300-long.mp4","hold","Leah","updates_per_s"):.0f}</b><span>pictures/s while holding skip on HEVC (Flick vs Leah)</span></div>
  <div><b>{get("A-hevc-4k30-gop300-long.mkv","drag","Flick","updates_per_s"):.0f} vs {get("A-hevc-4k30-gop300-long.mkv","drag","Leah","updates_per_s"):.0f}</b><span>pictures/s while dragging the seek bar on an HEVC MKV</span></div>
  <div><b>{get("B-h264-4k30-gop250-long.mp4","click","Flick","final_picture_ms"):.0f} vs {get("B-h264-4k30-gop250-long.mp4","click","Leah","final_picture_ms"):.0f} ms</b><span>click to exact frame on H.264 MP4</span></div>
  <div><b>{get("A-hevc-4k30-gop300-long.mp4","drag","Flick","first_response_ms"):.0f} vs {get("A-hevc-4k30-gop300-long.mp4","drag","Leah","first_response_ms"):.0f} ms</b><span>mouse-down to first new picture when dragging</span></div>
</section>

<section>
  <h2>Every picture change during one drag</h2>
  <p class="dir" style="margin-bottom:12px">HEVC file, run 1. Each tick is a moment the screen showed a new frame; a 120 Hz display allows at most one every 8.3 ms. The shaded band is the 0.5 s where the pointer rests.</p>
  <div class="strips">{strips}
  <div class="axis"><span></span><span><span>mouse-down</span><span>1 s</span><span>2 s</span><span>3 s</span><span>4 s</span><span>release</span></span><span>changes</span></div></div>
</section>

<div class="legend"><span><i style="background:var(--flick)"></i>Flick</span><span><i style="background:var(--leah)"></i>Leah 4.1</span><span><i style="background:var(--other)"></i>IINA</span><span><i style="background:var(--other2)"></i>mpv</span><span>Medians of 3 runs per player, test and file (2 for some H.264 MP4 drag/click runs of the other players). MKV files: Flick and Leah only.</span></div>

{"".join(sections)}

<section class="cols">
  <div><h2>Where Leah is still ahead</h2><ul>
    {leah_ahead()}
  </ul></div>
  <div><h2>How Flick does it</h2><ul>
    <li>Reads the MP4 sample table once, memory-maps the file and feeds samples straight to the hardware decoder, with no demuxer in the path.</li>
    <li>One decoder "chases" the latest target. Retargeting never queues work, and any decoded frame closer to the target than what's on screen is shown at once.</li>
    <li>Skips B-frames nothing references, and pre-decodes keyframes while paused.</li>
    <li>A second decoder lane decodes the keyframe of the GOP the pointer is heading into.</li>
    <li>Reads Matroska itself: a built-in EBML parser indexes the file (about 12 ms for a 750 MB file once cached) and a native pipeline plays it, with video and audio sample-buffer renderers on one clock and pitch-corrected speed from 0.25× to 16×. H.264/HEVC video; AAC, AC3, E-AC3, Opus, FLAC, MP3 and PCM audio. Only DTS/TrueHD-only files or VP9 video fall back to an ffmpeg remux.</li>
    <li>Exact-frame seeks were verified by barcode: 0 wrong frames across 160+ random seeks, MP4 and MKV.</li>
  </ul></div>
</section>

<section class="cols">
  <div><h2>Method</h2><ul>
    <li>Same Mac, same 1600×900 window on the built-in 120 Hz display, players launched fresh on an APFS clone of the file each run so none could resume a position.</li>
    <li>Two 16-minute 4K files made from real DJI footage: HEVC with a 10 s GOP (how drones and phones record) and x264 H.264 with B-frames (typical download), each as MP4 and as MKV with AAC audio.</li>
    <li>Inputs are real HID events (arrow key with Fn and NumericPad flags, mouse down/drag/up at 125 Hz). The player must be frontmost or the run aborts.</li>
    <li>Screen capture with ScreenCaptureKit at the display refresh rate; a 16-bit barcode with an inverted second row is read from each captured frame and rejected unless both rows are clean.</li>
    <li>Each run opens a uniquely named APFS clone of the file. An earlier round reused clone names and IINA resumed near the end of the file, so those IINA hold runs were discarded and re-run (kept in <code>raw-invalid</code>).</li>
    <li>Players interleaved per repetition; 3 repetitions; medians reported. A run is redone once if the player never responded or the barcode was unreadable most of the time.</li>
  </ul></div>
  <div><h2>Caveats</h2><ul>
    <li>VLC was not tested: macOS's first-launch prompt for the freshly installed VLC was declined, pending the owner's approval.</li>
    <li>IINA on this Mac has a custom key map with no arrow-key seek, so its held-key test uses its configured skip key, <code>x</code> (10 s). IINA's floating seek bar barely updated the picture during drags (it seems to seek on release), so its drag numbers mostly reflect that.</li>
    <li>mpv ran with default settings (<code>--no-config</code>). While its arrow key is held, mpv displays frames decoded against the wrong reference pictures; those unreadable frames are not counted as updates.</li>
    <li>Flick was tuned against this suite. Its first round lost click and H.264-drag to Leah (kept in <code>raw-v1</code>). A harness calibration fix then made every player's frame counts more reliable. The numbers here are a fresh run of all four players with the final Flick build, and earlier data is kept in <code>raw-v2-calib</code>.</li>
    <li>Headless decoder check (no display): exact seeks on the original DJI clips took 94 ms median in Flick's engine vs 935 ms in mpv's engine (which IINA uses).</li>
  </ul></div>
</section>
</main>
'''
open(os.path.join(R, "report.html"), "w").write(page)
print("wrote", os.path.join(R, "report.html"))
