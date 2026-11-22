#!/usr/bin/env python3
"""Per-phase main-thread cost from a volunteer.sh or edit-storm.sh run folder.

Exports the Time Profiler table, keeps the main thread's samples, groups
them into busy runs (samples less than 3 ms apart), and prints per phase:
busy ms, runs over 9 / 17 / 33 ms (a dropped frame at 120 / 60 / 30 Hz),
the worst run, and the heaviest app and SwiftUI frames.
  volunteer-analyze.py <run folder> [--top N] [--phase NAME [--under SYMBOL | --over SYMBOL]]
"""
import collections, datetime, json, os, re, subprocess, sys
import xml.etree.ElementTree as ET

out = sys.argv[1]
TOP = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 0
trace = os.path.join(out, "t.trace")
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"],
                     capture_output=True, text=True, env=env).stdout
start = re.search(r"<start-date>([^<]+)</start-date>", toc).group(1)
t0 = datetime.datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()

xml = os.path.join(out, "tp.xml")
if not os.path.exists(xml):
    subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--output", xml, "--xpath",
                    '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                   check=True, capture_output=True, env=env)

ids = {}
def resolve(el):
    r = el.get("ref")
    return ids.get(r, el) if r else el

samples = []  # (t seconds abs, weight ms, [frame names leaf first])
for ev, el in ET.iterparse(xml, events=("end",)):
    i = el.get("id")
    if i: ids[i] = el
    if el.tag != "row": continue
    t = th = w = bt = None
    for c in el:
        c = resolve(c)
        if c.tag == "sample-time": t = int(c.text) / 1e9
        elif c.tag == "thread": th = c.get("fmt", "")
        elif c.tag == "weight": w = int(c.text) / 1e6
        elif c.tag == "backtrace": bt = c
        elif c.tag == "tagged-backtrace":
            inner = c.find("backtrace")
            bt = resolve(inner) if inner is not None else c
    if th is None or "Main Thread" not in th or bt is None: continue
    frames = [resolve(f).get("name", "?") for f in bt if resolve(f).tag == "frame"]
    samples.append((t0 + t, w or 1.0, frames))

phases = []
for line in open(os.path.join(out, "phases.txt")):
    ts, name = line.split()
    phases.append((float(ts), name))

IDLE = ("mach_msg2_trap", "mach_msg_trap", "__psynch_cvwait", "kevent")
def busy(s):
    return not (s[2] and s[2][0] in IDLE)

res = {}
print(f"{'phase':8} {'secs':>5} {'busy ms':>8} {'busy%':>6} {'>9ms':>5} {'>17ms':>6} {'>33ms':>6} {'worst':>6}")
for (a, name), (b, _) in zip(phases, phases[1:]):
    if name == "start": continue
    ph = [s for s in samples if a <= s[0] < b and busy(s)]
    runs = []
    cur = None
    for s in ph:
        if cur and s[0] - cur[1] <= 0.003:
            cur[1] = s[0]; cur[2] += s[1]
        else:
            if cur: runs.append(cur)
            cur = [s[0], s[0], s[1]]
    if cur: runs.append(cur)
    lens = [r[2] for r in runs]
    tot = sum(s[1] for s in ph)
    secs = b - a
    r = dict(secs=round(secs, 1), busy=round(tot), pct=round(100 * tot / (secs * 1000), 1),
             o9=sum(l > 9 for l in lens), o17=sum(l > 17 for l in lens), o33=sum(l > 33 for l in lens),
             worst=round(max(lens) if lens else 0))
    res[name] = r
    print(f"{name:8} {r['secs']:5} {r['busy']:8} {r['pct']:6} {r['o9']:5} {r['o17']:6} {r['o33']:6} {r['worst']:6}")
    if TOP:
        inc = collections.Counter()
        for s in ph:
            for f in set(s[2]):
                inc[f] += s[1]
        app = [(f, c) for f, c in inc.most_common(400)
               if not f.startswith(("0x", "?", "main", "start", "NSApplication", "-[NSApplication", "_DPS", "RunCurrent", "ReceiveNext", "_BlockUntil", "__CFRun", "_CFRun", "CFRunLoop"))]
        for f, c in app[:TOP]:
            print(f"      {c:7.0f}  {f[:150]}")
json.dump(res, open(os.path.join(out, "vol.json"), "w"), indent=1)

if "--phase" in sys.argv:
    want = sys.argv[sys.argv.index("--phase") + 1]
    a, b = next((x[0], y[0]) for x, y in zip(phases, phases[1:]) if x[1] == want)
    ph = [s for s in samples if a <= s[0] < b and busy(s)]
    skip = re.compile(r"^(runApp|static App|static MxUSlides|specialized runApp|<deduplicated|UC::|CA::Transaction|stepTransaction|__CFRUNLOOP|NSDisplayCycle|_NSDisplay|__NSWindowGetDisplay|NSPerformVisually|-\[NSView _layout|__36-\[NSView|__56-\[NSView|-\[NSWindow|_NSViewLayout|___NSViewLayout|\+\[NSAnimationContext|closure #1 in NSHostingView.layout|NSHostingView.layout|@objc NSHostingView.layout|-\[NSApplication|_DPS|RunCurrent|ReceiveNext|_BlockUntil|__CFRun|_CFRun|main$|start$|thunk for|partial apply|specialized thunk|0x)")
    inc = collections.Counter(); leaf = collections.Counter()
    for s in ph:
        seen = set()
        for f in s[2]:
            if f not in seen: inc[f] += s[1]; seen.add(f)
        leaf[s[2][0]] += s[1]
    print(f"== {want}: inclusive (busy {sum(s[1] for s in ph):.0f} ms)")
    for f, c in inc.most_common(3000):
        if not skip.match(f): print(f"  {c:6.0f}  {f[:160]}")
        if c < 25: break
    print("== leaf")
    for f, c in leaf.most_common(25): print(f"  {c:6.0f}  {f[:160]}")

if "--under" in sys.argv:
    want = sys.argv[sys.argv.index("--phase") + 1]
    key = sys.argv[sys.argv.index("--under") + 1]
    a, b = next((x[0], y[0]) for x, y in zip(phases, phases[1:]) if x[1] == want)
    inc = collections.Counter(); n = 0
    for s in samples:
        if not (a <= s[0] < b and busy(s)): continue
        idx = next((i for i, f in enumerate(s[2]) if key in f), None)
        if idx is None: continue
        n += s[1]
        for f in set(s[2][:idx]): inc[f] += s[1]
    print(f"== under {key}: {n:.0f} ms")
    for f, c in inc.most_common(45): print(f"  {c:6.0f}  {f[:170]}")

if "--over" in sys.argv:
    want = sys.argv[sys.argv.index("--phase") + 1]
    key = sys.argv[sys.argv.index("--over") + 1]
    a, b = next((x[0], y[0]) for x, y in zip(phases, phases[1:]) if x[1] == want)
    inc = collections.Counter(); n = 0
    for s in samples:
        if not (a <= s[0] < b and busy(s)): continue
        idx = next((i for i, f in enumerate(s[2]) if key in f), None)
        if idx is None: continue
        n += s[1]
        for f in set(s[2][idx+1:idx+14]): inc[f] += s[1]
    print(f"== callers of {key}: {n:.0f} ms")
    for f, c in inc.most_common(40): print(f"  {c:6.0f}  {f[:170]}")
