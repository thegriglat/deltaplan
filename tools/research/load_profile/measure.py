#!/usr/bin/env python3
"""measure.py <тег> — собрать logs/<тег>_<место>_<i>.log в <тег>.json (FL-К3 v1). --selftest — проверка разбора на logs/*_warm.log."""
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent


def load_avg(line):
    m = re.search(r"load average:\s*(\d+(?:[.,]\d+)?)", line)
    return float(m[1].replace(",", ".")) if m else None


def parse_log(text):
    """Один лог зонда → запись run (без place/run)."""
    stages, gaps, r = {}, [], {"exit": None, "cold": False}
    header_none = False
    from_cache = False
    first_la = last_la = None
    for line in text.splitlines():
        m = re.match(r"load_probe: этап (\S+)\s+([\d.]+) с", line)
        if m:
            stages[m[1]] = round(stages.get(m[1], 0.0) + float(m[2]), 3)
        m = re.match(r"\[gap\] ([\d.]+) с: (\d+) мс", line)
        if m:
            gaps.append((float(m[1]), int(m[2])))
        m = re.match(r"\[lpfly\] FLYING @[\d.]+ \(от нажатия ([\d.]+) с\)", line)
        if m:
            r["to_flying_s"] = float(m[1])
        m = re.match(r"Terrain: место \S+ загружено за ([\d.]+) с", line)
        if m:
            r["terrain_loaded_s"] = float(m[1])
        m = re.match(r"exit=(\d+)", line)
        if m:
            r["exit"] = int(m[1])
        if "air_model: поле из кеша" in line:
            from_cache = True
        if line.startswith("air_cache: none"):
            header_none = True
        m = re.match(r"commit: (\S+)", line)
        if m:
            r["commit"] = m[1]
        if line.startswith("cold: 1"):
            r["cold"] = True
        if line.startswith("uptime:"):
            first_la = load_avg(line)
        if line.startswith("uptime_end:"):
            last_la = load_avg(line)
    # метка кеша — по факту из лога (не по заголовку): попадание = поле взято из кеша; без кеша (off) = none
    r["air_cache"] = "hit" if from_cache else ("none" if header_none else "miss")
    fly = r.get("to_flying_s", 0.0)
    # интервалы, начавшиеся до полёта (t — начало интервала от нажатия «Лететь»)
    g = [d for t, d in gaps if t < fly] if fly else []
    r["stages"] = stages
    r["load_max_gap_ms"] = max(g) if g else 0
    r["load_gaps_over_1s"] = sum(1 for d in g if d > 1000)
    r["_la"] = (first_la, last_la)
    return r


def med(vals):
    return round(statistics.median(vals), 3) if vals else None


def summarize(runs):
    groups = {}
    for r in runs:
        if r["exit"] == 0 and not r.get("cold") and r.get("to_flying_s", 0) > 0:
            groups.setdefault(f"{r['place']}/{r['air_cache']}", []).append(r)
    out = {}
    for k, rs in groups.items():
        names = sorted({s for r in rs for s in r["stages"]})
        out[k] = {
            "n": len(rs),
            "to_flying_s": med([r["to_flying_s"] for r in rs]),
            "load_max_gap_ms": med([r["load_max_gap_ms"] for r in rs]),
            "stages": {s: med([r["stages"][s] for r in rs if s in r["stages"]]) for s in names},
        }
    return out


def collect(tag):
    runs, las = [], []
    # имя <тег>_<место>_<i>.log: тег может содержать «_», поэтому разбираем с конца
    files = [p for p in (here / "logs").glob(f"{tag}_*_*.log") if p.stem.rsplit("_", 2)[0] == tag]
    for p in sorted(files, key=lambda p: (p.stem.rsplit("_", 2)[1], int(p.stem.rsplit("_", 2)[2]))):
        _, place, i = p.stem.rsplit("_", 2)
        r = parse_log(p.read_text(errors="replace"))
        las.append(r.pop("_la"))
        r.update({"place": place, "run": int(i)})
        runs.append(r)
    return runs, las


def main():
    tag = sys.argv[1]
    runs, las = collect(tag)
    if not runs:
        sys.exit(f"нет логов {tag}_*_*.log")
    commits = sorted({r.pop("commit") for r in runs if "commit" in r})
    starts = [a for a, _ in las if a is not None]
    ends = [b for _, b in las if b is not None]
    try:
        date = subprocess.run(["date", "-Iseconds"], capture_output=True, text=True).stdout.strip()
    except OSError:
        date = ""
    data = {
        "version": 1, "tag": tag, "commit": ",".join(commits), "date": date,
        "machine": {"load_avg_start": starts[0] if starts else None, "load_avg_end": ends[-1] if ends else None,
                    "load_avg_max": max(starts + ends) if starts + ends else None},
        "runs": runs, "median": summarize(runs),
    }
    (here / f"{tag}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    for k, v in data["median"].items():
        print(f"{k}: n={v['n']} to_flying_s={v['to_flying_s']} gap_ms={v['load_max_gap_ms']} stages={v['stages']}")


def selftest():
    for name, lo, hi in (("ong_warm", 15, 60), ("pt_warm", 20, 80)):
        r = parse_log((here / "logs" / f"{name}.log").read_text(errors="replace"))
        assert r["exit"] == 0, (name, r["exit"])
        assert lo < r["to_flying_s"] < hi, (name, r["to_flying_s"])
        for s in ("objects", "wind", "glider"):
            assert r["stages"].get(s, 0) > 0, (name, s)
        assert r["load_max_gap_ms"] > 1000 and r["load_gaps_over_1s"] >= 1, (name, r["load_max_gap_ms"])
    r = parse_log("uptime: x load average: 1,50, 2,00, 3,00\n[lpfly] FLYING @1.0 (от нажатия 5.00 с)\n[gap] 1.00 с: 2500 мс\n"
                  "[gap] 9.00 с: 3000 мс\nload_probe: этап wind 2.00 с\nload_probe: этап wind 1.00 с\nexit=0\n")
    assert r["load_max_gap_ms"] == 2500 and r["stages"]["wind"] == 3.0 and r["_la"][0] == 1.5
    print("selftest ok")


if __name__ == "__main__":
    selftest() if sys.argv[1:2] == ["--selftest"] else main()
