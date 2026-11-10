#!/usr/bin/env python3
"""LT-8: пачка разрезов LTS полем а или б. run.py <a|b> <dp-stand> <repo с configs и случаями> [--only perdigao_sw]
Пишет ~/data/lee_turb/lts_fieldcheck/<поле>_<случай>[_Lxx].lts.csv (линия опорной станции - без суффикса), times_<поле>.csv, stderr-журналы.
Кеш полей: ~/data/lee_turb/fieldcheck_cache/<поле>/ (вне git)."""
import json, os, subprocess, sys, time


def fix_l(text):
    """Стенд печатает l_u, l_w с точностью 0,1 м: в спокойном воздухе высоко над землёй (σ ~ 0,001 м/с) выходит 0.0, а LTS v1 требует l > 0.
    Заменяем 0.0 на 0.05 (верхняя граница округления); затронуто только такое «0.0» (src mech, agl > 100 м)."""
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

HERE = os.path.dirname(os.path.abspath(__file__))
LT = os.path.abspath(os.path.join(HERE, ".."))
fld, binp, repo = sys.argv[1], sys.argv[2], sys.argv[3]
only = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--only" else None
OUT = os.path.expanduser("~/data/lee_turb/lts_fieldcheck")
CACHE = os.path.expanduser("~/data/lee_turb/fieldcheck_cache/" + fld)
os.makedirs(OUT, exist_ok=True); os.makedirs(CACHE, exist_ok=True)
L = json.load(open(os.path.join(HERE, "out", "lines.json")))
PL = os.path.expanduser("~/data/lee_turb/places")
tl = open(os.path.join(OUT, "times_%s.csv" % fld), "a")
for cj, v in L.items():
    if only and cj != only:
        continue
    site = cj.split("_")[0]
    for ln in v["lines"]:
        main = v["crest"] in ln["members"]
        name = "%s_%s%s" % (fld, cj, "" if main else "_" + ln["name"].split("_")[-1])
        path = os.path.join(OUT, name + ".lts.csv")
        if os.path.exists(path):
            continue
        cmd = [binp, "lee", "--case", os.path.join(LT, "places", "cases", cj + ".json"), "--place", os.path.join(PL, site + ".json"),
               "--model", "formula", "--time", "0", "--from=%g,%g" % tuple(ln["from"]), "--to=%g,%g" % tuple(ln["to"]),
               "--ys=%g,%g" % (v["y0"], v["y1"]), "--step", "10", "--timeout", "1800", "--cache", CACHE,
               "--configs", os.path.join(repo, "configs")]
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True)
        dt = time.time() - t0
        if r.returncode != 0:
            print("FAIL", name, r.stderr[-500:], file=sys.stderr); continue
        open(path + ".tmp", "w").write(fix_l(r.stdout)); os.replace(path + ".tmp", path)
        open(os.path.join(OUT, name + ".stderr"), "w").write(r.stderr)
        tl.write("%s,%s,%.1f\n" % (name, "main" if main else "side", dt)); tl.flush()
        print(name, round(dt, 1), flush=True)
