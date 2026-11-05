#!/usr/bin/env python3
"""Перегенерация нарушителей: check --full -> gen_full --only <нарушители> --attempt N (до 3 раз) -> итоговый check.
python fix_loop.py --config C --dir D --stats stats_full.json   (запускать venv-python'ом)"""
import argparse, json, os, re, subprocess, sys
H = os.path.dirname(os.path.abspath(__file__)); py = sys.executable
ap = argparse.ArgumentParser(); ap.add_argument("--config", required=True); ap.add_argument("--dir", required=True)
ap.add_argument("--stats", required=True); ap.add_argument("--tries", type=int, default=3); ap.add_argument("--start", type=int, default=1); a = ap.parse_args()
chk = [py, os.path.join(H, "check_voice.py"), "--config", a.config, "--dir", a.dir, "--full", "--stats", a.stats]
for n in range(a.start, a.start + a.tries + 1):
    r = subprocess.run(chk, capture_output=True, text=True); print(r.stdout.splitlines()[-1], flush=True)
    bad = sorted({m.group(1) for l in r.stdout.splitlines() if (m := re.match(r"VIOLATION (\w+/\w+/\w+):", l))})
    if not bad or n >= a.start + a.tries: break
    print(f"attempt {n}: {len(bad)} lines", flush=True)
    subprocess.run([py, os.path.join(H, "gen_full.py"), "lines", "--config", a.config, "--out", a.dir, "--only", ",".join(bad),
                    "--attempt", str(n), "--stats", os.path.join(H, "gen_stats.json")], check=True)
print("remaining:", json.load(open(a.stats))["violations"])
