#!/usr/bin/env python3
"""LT-12: пачка разрезов LTS двумя стендами на одном поле (срезанные клетки уже в обоих).
run.py <old|new> <dp-stand> <корень копии с configs> [--only <случай>]
Случаи Perdigão/Askervein: линии из out/lines.json (lines.py), как LT-8; Онгудай strong: 6 гребней ../stand/ridges.json (как run_baseline.sh).
Пишет ~/data/lee_turb/lts_verify/<old|new>_<случай>[_Lxx].lts.csv, times_<code>.csv, *.stderr. Кеш полей — ~/data/lee_turb/verify_cache/<code>/ (вне git)."""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LT = os.path.abspath(os.path.join(HERE, ".."))
code, binp, repo = sys.argv[1], sys.argv[2], sys.argv[3]
only = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--only" else None
OUT = os.path.expanduser("~/data/lee_turb/lts_verify")
CACHE = os.path.expanduser("~/data/lee_turb/verify_cache/" + code)
os.makedirs(OUT, exist_ok=True); os.makedirs(CACHE, exist_ok=True)
PL = os.path.expanduser("~/data/lee_turb/places")


def fix_l(text):
    """Старый стенд печатает l_u, l_w с точностью 0,1 м: в спокойном воздухе выходит 0.0, а LTS v1 требует l > 0. 0.0 -> 0.05 (только такие значения)."""
    out = []
    for i, ln in enumerate(text.split("\n")):
        if i >= 2 and ln.count(",") == 17:
            f = ln.split(",")
            for k in (15, 16):
                if f[k] == "0.0":
                    f[k] = "0.05"
            ln = ",".join(f)
        out.append(ln)
    return "\n".join(out)


tl = open(os.path.join(OUT, "times_%s.csv" % code), "a")


def go(name, args):
    path = os.path.join(OUT, name + ".lts.csv")
    if os.path.exists(path):
        return
    t0 = time.time()
    r = subprocess.run([binp, "lee", "--model", "formula", "--time", "0", "--step", "10", "--configs", os.path.join(repo, "configs")] + args,
                       capture_output=True, text=True)
    dt = time.time() - t0
    if r.returncode != 0:
        print("FAIL", name, r.stderr[-500:], file=sys.stderr, flush=True); return
    open(path + ".tmp", "w").write(fix_l(r.stdout)); os.replace(path + ".tmp", path)
    open(os.path.join(OUT, name + ".stderr"), "w").write(r.stderr)
    tl.write("%s,%.1f\n" % (name, dt)); tl.flush()
    print(name, round(dt, 1), flush=True)


L = json.load(open(os.path.join(HERE, "out", "lines.json")))
for cj, v in L.items():
    if only and cj != only:
        continue
    site = cj.split("_")[0]
    for ln in v["lines"]:
        main = v["crest"] in ln["members"]
        name = "%s_%s%s" % (code, cj, "" if main else "_" + ln["name"].split("_")[-1])
        go(name, ["--case", os.path.join(LT, "places", "cases", cj + ".json"), "--place", os.path.join(PL, site + ".json"),
                  "--from=%g,%g" % tuple(ln["from"]), "--to=%g,%g" % tuple(ln["to"]), "--ys=%g,%g" % (v["y0"], v["y1"]),
                  "--timeout", "1800", "--cache", CACHE])
if not only or only == "ongudai_strong":
    for r in json.load(open(os.path.join(LT, "stand", "ridges.json"))):
        go("%s_ongudai_strong_%s" % (code, r["name"]),
           ["--case", os.path.join(repo, "tests/fixtures/wind/cases/ongudai_strong.json"), "--from=%g,%g" % tuple(r["frm"]),
            "--to=%g,%g" % tuple(r["to"]), "--ys=%g,%g" % tuple(r["ys"]), "--timeout", "900"])
