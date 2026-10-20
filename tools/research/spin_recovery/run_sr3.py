#!/usr/bin/env python3
"""SR-3: пачка прогонов spin_run.gd (SR-К1 v2) + reversal_run.gd → out/sr-3/raw/*.json, out/sr-3/reversal.json; затем summary_sr3.py.
Из корня копии: python3 tools/research/spin_recovery/run_sr3.py [-j 8]. 10 вариантов × 3 крыла × 3 режима × 3 шага + переложение 45→45."""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tools/research/spin_recovery/out/sr-3"
RAW = OUT / "raw"
REV = OUT / "rev_raw"
DTS = {"120": 1 / 120, "60": 1 / 60, "30": 1 / 30}
WINGS = ["sport", "laminar", "training"]
MODES = ["release", "standard", "pull_release"]
VARS = ["game", "strips_id", "sprog2_a", "sprog2_b", "sprog3_a", "sprog3_b", "clmax2_10", "clmax2_15", "clmax3_10", "clmax3_15"]
env = dict(os.environ, XDG_DATA_HOME=os.path.expanduser("~/.cache/dp-xdg/" + ROOT.name))


def go(scene, out, args):
    if out.exists():
        return
    r = subprocess.run(["godot", "--headless", "--path", str(ROOT), f"res://tools/research/spin_recovery/{scene}.tscn", "--",
                        *args, f"--out={out}"], env=env, capture_output=True, text=True, timeout=300)
    if not out.exists():
        print("FAIL", scene, args, r.stdout[-500:], r.stderr[-500:], flush=True)


def one(job):
    w, v, m, d = job
    go("spin_run", RAW / f"{w}__{v}__{m}__{d}.json",
       [f"--wing={w}", f"--variant={v}", f"--mode={m}", f"--dt={DTS[d]!r}", "--task=SR-3"])


def rev(job):
    w, v = job
    go("reversal_run", REV / f"{w}__{v}.json", [f"--wing={w}", f"--variant={v}"])


def main():
    j = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 8
    RAW.mkdir(parents=True, exist_ok=True)
    REV.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(j) as ex:
        list(ex.map(rev, [(w, v) for v in VARS if v != "strips_id" for w in WINGS]))
        list(ex.map(one, [(w, v, m, d) for v in VARS for w in WINGS for m in MODES for d in DTS]))
    d = {w: {} for w in WINGS}
    for p in sorted(REV.glob("*.json")):
        r = json.loads(p.read_text())
        d[r["wing"]][r["variant"]] = r["reversal_s"]
    (OUT / "reversal.json.tmp").write_text(json.dumps(d, ensure_ascii=False, indent=1))
    (OUT / "reversal.json.tmp").rename(OUT / "reversal.json")
    print("raw:", len(list(RAW.glob("*.json"))), "rev:", len(list(REV.glob("*.json"))))


main()
