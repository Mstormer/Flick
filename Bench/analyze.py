"""Summarise bench runs: python3 analyze.py Results/raw/*.json > Results/summary.json

Every metric comes from what was actually on screen (barcode frame numbers captured at display refresh)
against the moment the HID event was posted. Nothing is self-reported by the players.
"""
import json, statistics, subprocess, sys, functools, os
from collections import defaultdict

@functools.lru_cache(None)
def keyframes(video):
    """Presentation-order indices of keyframes (barcode value == presentation index)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts,flags",
                          "-of", "csv=p=0", video], capture_output=True, text=True).stdout.split()
    pk = sorted((int(a), "K" in b) for a, b in (l.split(",")[:2] for l in out if "," in l))
    return {i for i, (_, k) in enumerate(pk) if k}

@functools.lru_cache(None)
def frame_count(video):
    return int(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-count_packets", "-show_entries",
                               "stream=nb_read_packets", "-of", "csv=p=0", video], capture_output=True, text=True).stdout.strip())

def changes(frames, t0, t1):
    """Picture changes inside [t0, t1]: list of (t, frame)."""
    out, last = [], None
    for t, f in frames:
        if f < 0: continue
        if last is not None and f != last and t0 <= t <= t1: out.append((t, f))
        last = f
    return out

def last_valid_before(frames, t):
    v = None
    for ft, f in frames:
        if ft > t: break
        if f >= 0: v = f
    return v

def gaps(ts, t0, t1):
    pts = [t0] + ts + [t1]
    return max(b - a for a, b in zip(pts, pts[1:])) if len(pts) > 1 else t1 - t0

def depth(kf, f):
    if f is None: return None
    return f - max((k for k in kf if k <= f), default=0)

def summarise(run):
    ins = run["inputs"]
    base = os.path.basename(run["video"])
    media = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Media")
    if "/runs/" in run["video"] or "/FlickBench/" in run["video"]:   # per-run APFS clone -> original file
        base = max((n for n in os.listdir(media) if base.endswith(n)), key=len)
    run["video"] = os.path.join(media, base)
    kf = keyframes(run["video"])
    nframes = frame_count(run["video"])
    # a value past the end of the file can only be a corrupted picture (wrong-reference decode): unreadable
    fr = sorted((t, f if f < nframes else -1) for t, f in run["frames"])
    sc = run["scenario"]
    r = {"player": run["player"], "video": os.path.basename(run["video"]), "scenario": sc}
    tstart = [e["t"] for e in ins if e["kind"] == "start"][0]
    ev = lambda k: [e["t"] for e in ins if e["kind"] == k and e["t"] >= tstart]
    if sc == "hold":
        hk = run.get("holdKey", 124)
        t0 = [e["t"] for e in ins if e["kind"] == "keyDown" and e.get("code") == hk][0]
        t1 = [e["t"] for e in ins if e["kind"] == "keyUp" and e.get("code") == hk][0]; tend = ev("end")[0]
        ch = changes(fr, t0, t1)
        after = changes(fr, t1, tend)
        rep0 = min([e["t"] for e in ins if e["kind"] == "keyRepeat" and e["t"] > t0] or [t0])
        start = last_valid_before(fr, t0); final = last_valid_before(fr, tend)
        r.update(updates_per_s=len(ch) / (t1 - t0), distinct=len({f for _, f in ch}),
                 first_response_ms=((ch[0][0] - t0) * 1000) if ch else None,
                 # until the first auto-repeat (~0.27 s, like a real keyboard) the target doesn't move, so
                 # there is nothing new to show: count freezes from the first repeat on
                 max_freeze_ms=gaps([t for t, _ in ch if t >= rep0], rep0, t1) * 1000,
                 max_freeze_incl_initial_ms=gaps([t for t, _ in ch], t0, t1) * 1000,
                 settle_ms=((after[-1][0] - t1) * 1000) if after else 0.0,
                 keyframe_share=(sum(f in kf for _, f in ch) / len(ch)) if ch else None,
                 advanced_s=((final - start) / 29.97) if final is not None and start is not None else None,
                 final_is_keyframe=final in kf)
    elif sc == "drag":
        t0 = ev("down")[0]; t1 = ev("up")[0]; tend = ev("end")[0]
        ch = changes(fr, t0, t1)
        after = changes(fr, t1, tend)
        rest = ev("dragRest")[0]
        # pointer is moving during [down, rest] and [rest + 0.5 s, up]; the 0.5 s pause is not a freeze
        segs = [(t0, rest), (rest + 0.5, t1)]
        moving_time = sum(b - a for a, b in segs)
        ch_moving = [c for c in ch if any(a <= c[0] <= b for a, b in segs)]
        r.update(updates_per_s=len(ch_moving) / moving_time, distinct=len({f for _, f in ch}),
                 first_response_ms=((ch[0][0] - t0) * 1000) if ch else None,
                 max_freeze_ms=max(gaps([t for t, _ in ch if a <= t <= b], a, b) for a, b in segs) * 1000,
                 settle_ms=((after[-1][0] - t1) * 1000) if after else 0.0,
                 keyframe_share=(sum(f in kf for _, f in ch) / len(ch)) if ch else None,
                 final_is_keyframe=last_valid_before(fr, tend) in kf,
                 # frames between the previous keyframe and where the drag was released: the decoding any
                 # player must do to show that exact frame, so release times are only comparable at similar depth
                 final_depth=depth(kf, last_valid_before(fr, tend)))
    elif sc.startswith("play"):
        pb = run.get("playback", {})
        rate = pb.get("rate", 1)
        t0 = ev("measureStart")[0]; t1 = ev("measureEnd")[0]
        fps = 30000 / 1001
        ch = changes(fr, t0, t1)
        first = last_valid_before(fr, t0); last = last_valid_before(fr, t1)
        expected = min((t1 - t0) * fps * rate, (t1 - t0) * 120)       # the display can't show more than 120/s
        shown = len(ch)
        gap = 1 / min(fps * rate, 120)
        ts = [t for t, _ in ch]
        jank = sum(1 for a, b in zip(ts, ts[1:]) if b - a > gap * 1.5)
        # a skipped frame is a gap in the frame numbers that reached the screen (counting shown vs expected
        # instead would charge a player for where the 10 s window happened to cut its frame changes)
        fs = [f for _, f in ch]
        skipped = sum(max(0, b - a - 1) for a, b in zip(fs, fs[1:]))
        span = (fs[-1] - fs[0]) if len(fs) > 1 else 0
        r.update(rate=rate, shown_per_s=shown / (t1 - t0), expected_per_s=expected / (t1 - t0),
                 skipped=skipped, dropped_pct=(skipped / span * 100) if span else None,
                 speed_ratio=((last - first) / ((t1 - t0) * fps) / rate) if first is not None and last is not None else None,
                 jank_per_s=jank / (t1 - t0),
                 cpu_s_per_10s=(pb.get("appCPU", 0) + pb.get("vtCPU", 0)) / pb.get("seconds", 10) * 10,
                 cpu_pct=(pb.get("appCPU", 0) + pb.get("vtCPU", 0)) / pb.get("seconds", 10) * 100,
                 energy_j_per_10s=(pb.get("appJoules", 0) + pb.get("vtJoules", 0)) / pb.get("seconds", 10) * 10)
    elif sc == "click":
        downs = ev("down"); tend = ev("end")[0]
        first, final, kfl, depths = [], [], [], []
        for i, d in enumerate(downs):
            nxt = downs[i + 1] - 0.15 if i + 1 < len(downs) else tend
            ch = changes(fr, d, nxt)
            if not ch: continue
            first.append((ch[0][0] - d) * 1000); final.append((ch[-1][0] - d) * 1000)
            kfl.append(ch[-1][1] in kf)
            depths.append(depth(kf, ch[-1][1]))
        r.update(clicks=len(downs), responded=len(first),
                 first_picture_ms=statistics.median(first) if first else None,
                 final_picture_ms=statistics.median(final) if final else None,
                 final_p90_ms=sorted(final)[int(len(final) * 0.9) - 1] if final else None,
                 lands_on_keyframe=(sum(kfl) / len(kfl)) if kfl else None,
                 mean_depth=(sum(depths) / len(depths)) if depths else None)
    return r

if __name__ == "__main__":
    rows = [summarise(json.load(open(p))) for p in sys.argv[1:]]
    agg = defaultdict(list)
    for r in rows: agg[(r["video"], r["scenario"], r["player"])].append(r)
    out = []
    for (v, s, p), rs in sorted(agg.items()):
        m = {"video": v, "scenario": s, "player": p, "runs": len(rs)}
        for k in rs[0]:
            if k in ("player", "video", "scenario"): continue
            vals = [r[k] for r in rs if isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool) or isinstance(r.get(k), bool)]
            vals = [float(x) for x in vals if x is not None]
            if vals: m[k] = round(statistics.median(vals), 3)
        out.append(m)
    json.dump({"runs": rows, "summary": out}, sys.stdout, indent=1)
