# exit 1 if a run looks broken (player never responded or barcode unreadable most of the time)
import json, sys, analyze
d = json.load(open(sys.argv[1]))
fr = d["frames"]
valid = sum(1 for _, f in fr if f >= 0) / max(1, len(fr))
r = analyze.summarise(d)
resp = r.get("updates_per_s") or r.get("responded") or r.get("shown_per_s") or 0
print(f"  check: valid={valid:.2f} response={resp}")
sys.exit(0 if valid > 0.3 and resp > 0 else 1)
