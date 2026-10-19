# Exact-seek latency of mpv's engine (what IINA runs on) over its JSON IPC.
# Time = command sent -> "playback-restart" event (first frame after the seek is decoded and queued).
import json, socket, subprocess, sys, time, os
video, targets = sys.argv[1], [float(x) for x in open(sys.argv[2]).read().split()]
mode = sys.argv[3] if len(sys.argv) > 3 else "absolute+exact"
sock = f"/tmp/mpvbench-{os.getpid()}.sock"
p = subprocess.Popen(["mpv", "--no-config", "--pause", "--vo=null", "--ao=null", "--hwdec=videotoolbox",
                      f"--input-ipc-server={sock}", "--keep-open=yes", video],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if os.path.exists(sock): break
    time.sleep(0.05)
s = socket.socket(socket.AF_UNIX); s.connect(sock); f = s.makefile("rb")
def send(cmd): s.sendall((json.dumps({"command": cmd}) + "\n").encode())
def wait(ev, timeout=10):
    s.settimeout(timeout)
    while True:
        m = json.loads(f.readline())
        if m.get("event") == ev: return
time.sleep(1.0)
send(["seek", 1, "absolute+exact"]); wait("playback-restart")
lat = []
for t in targets:
    t0 = time.perf_counter(); send(["seek", t, mode]); wait("playback-restart")
    lat.append((time.perf_counter() - t0) * 1000)
p.terminate()
print("RAW " + ",".join(f"{x:.1f}" for x in lat))
l = sorted(lat); print(f"mpv {mode} ms: median {l[len(l)//2]:.1f} p90 {l[len(l)*9//10]:.1f} max {l[-1]:.1f}")
