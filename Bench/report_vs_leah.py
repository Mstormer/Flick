"""Flick vs Leah report from one suite run:  python3 report_vs_leah.py <run-name>
Reads Results/<run>/raw/*.json and memory.tsv; writes Results/<run>/report.html and summary.json."""
import csv, glob, html, json, os, statistics, sys
from collections import defaultdict
import analyze

RUN = sys.argv[1]
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Results", RUN)
runs = [analyze.summarise(json.load(open(p))) for p in sorted(glob.glob(os.path.join(R, "raw", "*.json")))]

agg = defaultdict(list)
for r in runs: agg[(r["video"], r["scenario"], r["player"])].append(r)
S = {}
for k, rs in agg.items():
    m = {"runs": len(rs)}
    for key in rs[0]:
        vals = [float(x[key]) for x in rs if isinstance(x.get(key), (int, float)) and x.get(key) is not None]
        if vals: m[key] = statistics.median(vals)
    S[k] = m
json.dump({"runs": runs, "summary": {"|".join(k): v for k, v in S.items()}}, open(os.path.join(R, "summary.json"), "w"), indent=1)

def get(v, sc, p, key): return S.get((v, sc, p), {}).get(key)

VIDEOS = [("A-hevc-4k30-gop300-long.mp4", "MP4", "HEVC 4K30, 10 s keyframe spacing (drone footage)"),
          ("A-hevc-4k30-gop300-long.mkv", "MKV", "HEVC 4K30, 10 s keyframe spacing + AAC"),
          ("B-h264-4k30-gop250-long.mp4", "MP4", "H.264 4K30, x264 with B-frames"),
          ("B-h264-4k30-gop250-long.mkv", "MKV", "H.264 4K30, x264 with B-frames + AAC")]
VIDEOS = [v for v in VIDEOS if any(k[0] == v[0] for k in S)]

METRICS = [  # scenario, key, label, unit, higher is better[, absolute difference that still counts as a tie]
    ("play1", "dropped_pct", "Play at 1×: frames skipped", "%", False),
    ("play1", "jank_per_s", "Play at 1×: uneven frame gaps per second", "/s", False, 0.2),
    ("play1", "cpu_pct", "Play at 1×: CPU, app + its video decoder", "%", False),
    ("play1", "energy_j_per_10s", "Play at 1×: CPU energy per 10 s", "J", False),
    ("hold", "updates_per_s", "Hold the skip key: new pictures per second", "/s", True),
    ("hold", "first_response_ms", "Hold the skip key: first new picture", "ms", False),
    ("hold", "max_freeze_ms", "Hold the skip key: longest freeze once repeating", "ms", False),
    ("drag", "updates_per_s", "Drag the seek bar: new pictures per second", "/s", True),
    ("drag", "drop_pct", "Drag the seek bar: dropped refreshes (of 120 Hz)", "%", False),
    ("drag", "first_response_ms", "Drag the seek bar: first new picture", "ms", False),
    ("drag", "max_freeze_ms", "Drag the seek bar: longest freeze while moving", "ms", False),
    ("drag", "settle_ms", "Drag the seek bar: release to exact frame (median of 4 releases)", "ms", False),
    ("click", "first_picture_ms", "Click the seek bar: first new picture", "ms", False),
    ("click", "final_picture_ms", "Click the seek bar: exact frame on screen", "ms", False),
]
METRICS = [m if len(m) == 6 else m + (0.0,) for m in METRICS]
for k, m in S.items():
    if k[1] == "drag" and "updates_per_s" in m: m["drop_pct"] = max(0.0, 120 - m["updates_per_s"]) / 120 * 100

def fmt(v, unit):
    if v is None: return "—"
    if abs(v) >= 10 or unit == "ms": s = f"{v:.0f}"
    elif unit == "J" and abs(v) < 1: s = f"{v:.2f}"
    else: s = f"{v:.1f}"
    return s + ("" if unit == "/s" else "%" if unit == "%" else " " + unit)

def verdict(f, l, hib, tol=0.0):
    if f is None or l is None: return "", ""
    if abs(f - l) <= tol or abs(f - l) / max(abs(f), abs(l), 1e-9) < 0.05: return "tie", "Tie"
    fw = f > l if hib else f < l
    num, den = (f, l) if hib == fw else (l, f)
    who = "Flick" if fw else "Leah"
    return ("good" if fw else "bad"), (f"{who} {num / den:.1f}×" if den > 0 else f"{who} ahead")

# memory
mem = {}
mp = os.path.join(R, "memory.tsv")
if os.path.exists(mp):
    for row in csv.DictReader(open(mp), delimiter="\t"):
        try: mem[(row["player"], row["video"], row["phase"])] = (int(row["busy_app"]) + int(row["busy_vt"]), int(row["settled_app"]) + int(row["settled_vt"]))
        except (ValueError, KeyError): pass

score = {"Flick": 0, "Leah": 0, "tie": 0}
sections = []
for v, kind, desc in VIDEOS:
    rows = []
    for sc, key, label, unit, hib, tol in METRICS:
        f, l = get(v, sc, "Flick", key), get(v, sc, "Leah", key)
        cls, txt = verdict(f, l, hib, tol)
        if cls: score["Flick" if cls == "good" else "Leah" if cls == "bad" else "tie"] += 1
        top = max([x for x in (f, l) if x is not None] or [1]) or 1
        bar = lambda x, who: f'<span class="bar {who}" style="width:{max(1.5, 100 * (x or 0) / top):.1f}%"></span>'
        extra = ""
        if key == "settle_ms":
            fd, ld = get(v, sc, "Flick", "final_depth"), get(v, sc, "Leah", "final_depth")
            if fd is not None and ld is not None:
                extra = f" · releases averaged {fd:.0f} (Flick) and {ld:.0f} (Leah) frames past a keyframe"
        rows.append(f'''<tr><th scope="row">{html.escape(label)}<small>{"higher is better" if hib else "lower is better"}{extra}</small></th>
<td><div class="pair"><span class="who">Flick</span>{bar(f, "flick")}<span class="num">{fmt(f, unit)}</span></div>
<div class="pair"><span class="who">Leah</span>{bar(l, "leah")}<span class="num">{fmt(l, unit)}</span></div></td>
<td><span class="tag {cls}">{txt}</span></td></tr>''')
    sections.append(f'''<section class="file"><h3><span class="kind">{kind}</span>{html.escape(desc)}</h3>
<div class="scroll"><table><tbody>{"".join(rows)}</tbody></table></div></section>''')

mem_rows = []
for v in [x[0] for x in VIDEOS if x[0].startswith("A-")]:
    for ph, name in [("none", "Opened, paused"), ("play1", "Playing at 1×"), ("hold", "After holding skip"), ("drag", "After a drag")]:
        f, l = mem.get(("Flick", v, ph)), mem.get(("Leah", v, ph))
        if not (f or l): continue
        cells = "".join(f"<td>{x[i]:,} MB</td>" if x else "<td>—</td>" for x in (f, l) for i in (1,))
        busy = "".join(f"<td class='muted'>{x[0]:,} MB</td>" if x else "<td>—</td>" for x in (f, l))
        mem_rows.append(f"<tr><th scope='row'>{v.split('.')[-1].upper()} · {name}</th>{cells}{busy}</tr>")

ahead = []
for v, kind, desc in VIDEOS:
    for sc, key, label, unit, hib, tol in METRICS:
        f, l = get(v, sc, "Flick", key), get(v, sc, "Leah", key)
        cls, txt = verdict(f, l, hib, tol)
        if cls != "bad": continue
        note = ""
        if key == "settle_ms":
            fd, ld = get(v, sc, "Flick", "final_depth"), get(v, sc, "Leah", "final_depth")
            if fd is not None and ld is not None and fd > ld * 1.5:
                note = (f" The same bar positions landed on different frames: Flick's averaged {fd:.0f} frames past a keyframe,"
                        f" Leah's {ld:.0f}, so Flick had {fd / max(ld, 1):.1f}× as much to decode.")
        ahead.append(f"<li>{html.escape(label)} on {kind} {html.escape(desc.split(',')[0])}: Leah {fmt(l, unit)}, Flick {fmt(f, unit)}.{html.escape(note)}</li>")
for (p, v, ph), (busy, settled) in mem.items():
    if p == "Leah" and ("Flick", v, ph) in mem and settled < mem[("Flick", v, ph)][1] * 0.95:
        ahead.append(f"<li>Memory, {v.split('.')[-1].upper()} {dict(none='paused', play1='playing').get(ph, 'after ' + ph)}: Leah {settled:,} MB, Flick {mem[('Flick', v, ph)][1]:,} MB.</li>")

fast_rows = []
for v, kind, desc in VIDEOS:
    for sc, rate in (("play1", "1×"), ("play2", "2×"), ("play4", "4×")):
        m = S.get((v, sc, "Flick"))
        if not m or sc == "play1" and not any((v, x, "Flick") in S for x in ("play2", "play4")): continue
        fast_rows.append(f"<tr><th scope='row'>{kind} {html.escape(desc.split(',')[0])} · {rate}</th>"
                         f"<td>{fmt(m.get('shown_per_s'), '/s')}</td><td>{fmt(m.get('dropped_pct'), '%')}</td>"
                         f"<td>{fmt(m.get('jank_per_s'), '/s')}</td><td>{fmt((m.get('speed_ratio') or 0) * 100, '%')}</td>"
                         f"<td>{fmt(m.get('cpu_pct'), '%')}</td><td>{fmt(m.get('energy_j_per_10s'), 'J')}</td></tr>")

def card(v, sc, key, unit, label):
    f, l = get(v, sc, "Flick", key), get(v, sc, "Leah", key)
    return f'<div class="card"><b>{fmt(f, unit)} <i>vs</i> {fmt(l, unit)}</b><span>{label}</span></div>'

log = open(os.path.join(R, "suite.log")).read() if os.path.exists(os.path.join(R, "suite.log")) else ""
nruns = len(runs)
page = f'''<title>Flick vs Leah</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:wght@400;600;800&family=JetBrains+Mono:wght@400;600&display=swap">
<style>
/* Layout: one report column; per file a two-row (Flick/Leah) bar table, then memory and method. */
:root {{
  --bg: #f3f3f6; --surface: #ffffff; --ink: #18171e; --muted: #64616f; --line: #dcdae4; --rest: #ebeaf1;
  --flick: #5b34e8; --leah: #d96a12; --good: #1d8550; --bad: #c03f2b;
  --display: "Schibsted Grotesk", "Helvetica Neue", Arial, sans-serif; --mono: "JetBrains Mono", ui-monospace, Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #111017; --surface: #1a1922; --ink: #ecebf3; --muted: #a19eae; --line: #2d2b38; --rest: #24222e;
  --flick: #9478ff; --leah: #f39a4f; --good: #4cc483; --bad: #f07a63; color-scheme: dark }} }}
:root[data-theme="dark"] {{
  --bg: #111017; --surface: #1a1922; --ink: #ecebf3; --muted: #a19eae; --line: #2d2b38; --rest: #24222e;
  --flick: #9478ff; --leah: #f39a4f; --good: #4cc483; --bad: #f07a63; color-scheme: dark }}
* {{ box-sizing: border-box }}
body {{ background: var(--bg); color: var(--ink); font: 15px/1.55 var(--display);
  padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); padding-block: 32px 64px }}
main {{ max-width: 980px; margin: 0 auto; display: flex; flex-direction: column; gap: 36px }}
h1 {{ font-size: clamp(30px, 5vw, 44px); line-height: 1.05; margin: 0; font-weight: 800; letter-spacing: -0.02em; text-wrap: balance }}
h2 {{ font-size: 21px; margin: 0 0 12px }}
h3 {{ font-size: 15px; margin: 0 0 10px; font-weight: 600; display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap }}
p, li {{ max-width: 68ch }}
.kicker {{ font-family: var(--mono); font-size: 12px; text-transform: uppercase; letter-spacing: 0.12em; color: var(--flick) }}
.lede {{ display: flex; flex-direction: column; gap: 12px }} .lede p {{ margin: 0; color: var(--muted); font-size: 17px }}
.score {{ font-family: var(--mono); font-size: 14px }}
.cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px }}
.card {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px }}
.card b {{ display: block; font-family: var(--mono); font-size: 20px; white-space: nowrap; font-variant-numeric: tabular-nums }}
.card b i {{ font-style: normal; color: var(--muted); font-size: 15px }}
.card span {{ color: var(--muted); font-size: 13px }}
.kind {{ font-family: var(--mono); font-size: 11px; padding: 2px 7px; border-radius: 4px; background: var(--rest); color: var(--muted) }}
.scroll {{ overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 10px }}
table {{ width: 100%; border-collapse: collapse; min-width: 560px }}
th, td {{ text-align: left; padding: 10px 14px; border-top: 1px solid var(--line); vertical-align: middle }}
tr:first-child th, tr:first-child td {{ border-top: 0 }}
th {{ font-weight: 600; font-size: 14px; width: 38% }} th small {{ display: block; font-weight: 400; color: var(--muted); font-size: 12px }}
td:last-child {{ width: 110px; text-align: right }}
.pair {{ display: grid; grid-template-columns: 44px 1fr 72px; gap: 8px; align-items: center; margin: 3px 0 }}
.who {{ font-family: var(--mono); font-size: 12px; color: var(--muted) }}
.bar {{ display: block; height: 10px; border-radius: 3px }} .bar.flick {{ background: var(--flick) }} .bar.leah {{ background: var(--leah) }}
.num {{ font-family: var(--mono); font-size: 13px; text-align: right; font-variant-numeric: tabular-nums }}
.tag {{ font-family: var(--mono); font-size: 11px; padding: 2px 8px; border-radius: 99px; border: 1px solid currentColor; white-space: nowrap }}
.tag.good {{ color: var(--good) }} .tag.bad {{ color: var(--bad) }} .tag.tie {{ color: var(--muted) }}
.mem td {{ font-family: var(--mono); font-size: 13px; font-variant-numeric: tabular-nums; text-align: right }}
.mem thead th {{ font-size: 12px; color: var(--muted); font-weight: 600; text-align: right }} .mem thead th:first-child {{ text-align: left }}
.muted {{ color: var(--muted) }}
.cols {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 24px }}
.cols > div {{ min-width: 0 }}
ul {{ margin: 0; padding-left: 18px; display: flex; flex-direction: column; gap: 6px }}
code {{ font-family: var(--mono); font-size: 13px; background: var(--rest); padding: 1px 5px; border-radius: 4px }}
</style>
<main>
<section class="lede">
  <span class="kicker">Black-box benchmark · M1 Max · 120 Hz built-in display · run “{html.escape(RUN)}”</span>
  <h1>Flick vs Leah: 4K playback, seeking and efficiency</h1>
  <p>Both players got the same real keyboard and mouse input, in the same 1600×900 window, on the same 16-minute 4K files as MP4 and as MKV. The screen was recorded at 120 Hz and every frame number was read from a barcode in the video, so every picture figure is what actually appeared on screen. CPU time and energy come from the kernel's own per-process accounting, counting each player plus the system video decoder working for it.</p>
  <p class="score">Of {score["Flick"] + score["Leah"] + score["tie"]} playback and seeking comparisons: Flick ahead in {score["Flick"]}, Leah in {score["Leah"]}, within 5% in {score["tie"]}.</p>
</section>
<section class="cards">
  {card("A-hevc-4k30-gop300-long.mp4", "play1", "energy_j_per_10s", "J", "CPU energy per 10 s of 1× playback (HEVC MP4)")}
  {card("A-hevc-4k30-gop300-long.mp4", "hold", "updates_per_s", "/s", "new pictures per second while holding skip (HEVC MP4)")}
  {card("A-hevc-4k30-gop300-long.mkv", "drag", "updates_per_s", "/s", "new pictures per second dragging the seek bar (HEVC MKV)")}
  {card("A-hevc-4k30-gop300-long.mkv", "drag", "drop_pct", "%", "refreshes dropped while dragging (HEVC MKV)")}
  {card("B-h264-4k30-gop250-long.mp4", "click", "final_picture_ms", "ms", "click to the exact frame (H.264 MP4)")}
</section>
{"".join(sections)}
<section><h2>Fast playback</h2>
<p class="muted" style="margin:0 0 12px">Flick only: Leah 4.1 has no playback-speed control. At 4× the video runs at 120 frames per second, which is also the display's limit. Speed held is how far the video actually advanced against the clock.</p>
<div class="scroll"><table class="mem"><thead><tr><th>File · speed</th><th>Pictures/s</th><th>Skipped</th><th>Uneven gaps/s</th><th>Speed held</th><th>CPU</th><th>Energy/10 s</th></tr></thead>
<tbody>{"".join(fast_rows) or "<tr><td colspan=7>Not measured in this run.</td></tr>"}</tbody></table></div></section>
<section><h2>Memory</h2>
<p class="muted" style="margin:0 0 12px">App plus its share of the system's video decoder services, on the HEVC files. Settled = 6 s after the action; busy = 1.5 s after. Paused for 3 s, Flick releases its playback decoder and keeps the exact frame on screen.</p>
<div class="scroll"><table class="mem"><thead><tr><th>State</th><th>Flick settled</th><th>Leah settled</th><th>Flick busy</th><th>Leah busy</th></tr></thead>
<tbody>{"".join(mem_rows) or "<tr><td colspan=5>Not measured in this run.</td></tr>"}</tbody></table></div></section>
<section class="cols">
  <div><h2>Where Leah is ahead</h2><ul>{"".join(ahead) or "<li>Nowhere in this run.</li>"}</ul></div>
  <div><h2>Method</h2><ul>
    <li>{nruns} runs; each test repeated 3 times with the two players interleaved; medians shown. A run is redone once if the barcode was unreadable most of the time or the player never responded.</li>
    <li>Play: Space to start, 0.8 s to settle, then 10 s measured. A skipped frame is a gap in the frame numbers that reached the screen. An uneven gap is a picture that stayed up more than 1.5× its frame time. CPU energy is the kernel's estimate (<code>ri_energy_nj</code>); it doesn't include GPU or display power.</li>
    <li>Hold: the skip key held 4 s at 30 repeats per second. Drag: seek bar swept from 5% to 95% in 3 s, paused 0.5 s, swept back to 30% in 1.5 s and released; then three 1-second drags released at 47%, 64% and 21%. Click: the same 12 spots on the bar in every run, 1.6 s apart.</li>
    <li>Each run opens a fresh, uniquely named copy of the file, so neither player can resume a remembered position.</li>
    <li>Hold: like a real keyboard, the key starts repeating about 0.27 s after it goes down. Until then the target doesn't move, so the longest freeze is measured from the first repeat. Measured from the first press instead, both players' figures include that wait.</li>
    <li>Drag release time depends on how far past a keyframe the release frame is, since every player has to decode from that keyframe to show the exact frame. Each run releases at the same four bar positions for both players, and the average depth is shown next to each release time.</li>
    <li>A dropped refresh is a 120 Hz screen refresh during the drag that showed no new picture.</li>
    <li>Leah 4.1 from the App Store; Flick built from this repository. Harness: <code>Bench/suite.sh</code>.</li>
    {"".join(f"<li>{html.escape(l.strip())}</li>" for l in open(os.path.join(R, "notes.txt")) if l.strip()) if os.path.exists(os.path.join(R, "notes.txt")) else ""}
  </ul></div>
</section>
</main>
'''
open(os.path.join(R, "report.html"), "w").write(page)
print("wrote", os.path.join(R, "report.html"), "| score", score)
