"""SWC-16: сбор SW7 после пересчёта: C1/C2/C4 — эталон по центрам клеток (cases/<C>_cc.json), LW — однородный фон
(cases/LW_*_uni.json), Perdigão — без изменений (cases/PERD_*.json, SWC-12). Пишет points.{json,csv}, info.json, tables.md.
Прежние (SWC-12) файлы — prev_swc12/."""
import csv, datetime, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from merge import KEYS, EXTRA

SRC = ["C1_cc", "C2_cc", "C4_cc", "PERD_NE", "PERD_SW", "LW_H3_uni", "LW_MD_uni", "LW_UCD_uni", "LW_H5_uni", "LW_GI_uni", "LW_H8_uni"]


def load(n): return json.load(open(os.path.join(C.CASES_DIR, n + ".json")))


def main():
    rows, rotor, info = [], [], {}
    for n in SRC:
        d = load(n)
        rows += d["rows"]; rotor += d["rotor"]
        info[d["case"]] = dict(info=d["info"], summary={v: {k: x for k, x in s.items() if k != "rotor_line"} for v, s in d["summary"].items()},
                               wall_s=d["wall_s"], ds_min=d["ds_min"], source_file=n)
    out = dict(format="sw-panels2d", version=1, git=C.git_rev(), created=datetime.datetime.now().isoformat(timespec="seconds"), tol_picard=C.TOL, rows=rows, rotor=rotor)
    json.dump(out, open(os.path.join(C.OUT, "points.json"), "w"), ensure_ascii=False, indent=0)
    with open(os.path.join(C.OUT, "points.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KEYS + EXTRA, extrasaction="ignore"); w.writeheader(); w.writerows(rows)
    json.dump(info, open(os.path.join(C.OUT, "info.json"), "w"), ensure_ascii=False, indent=1)
    old = json.load(open(os.path.join(C.OUT, "prev_swc12", "points.json")))["rows"]
    err = json.load(open(os.path.join(C.OUT, "tunnel", "picard_err.json")))
    L = ["### Пикар по центрам клеток (SWC-16): within_tol ±15 %"]
    L.append("| случай | вариант | всего | в допуске | нижняя клетка | k0+1 | ~50 м | ~300 м | upstream | windward | crest | lee | foot | SWC-12 (10/50/300 м, поправка): всего |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    ok = lambda s: f"{sum(bool(x['within_tol']) for x in s)}/{len(s)}"
    grp = {}
    for c in ("C1", "C2", "C4"):
        cells = info[c]["info"]["cells"]
        for v in ("potential", "vortex"):
            r = [x for x in rows if x["case"] == c and x["variant"] == v]
            # группа по порядку внутри точки: 4 высоты на каждую x
            byx = {}
            for x in r: byx.setdefault(x["point"], []).append(x)
            gs = [[], [], [], []]
            for p, lst in byx.items():
                lst = sorted(lst, key=lambda q: q["z_agl"])
                for j, q in enumerate(lst): gs[j].append(q)
            ro = [x for x in old if x["case"] == c and x["variant"] == v]
            L.append(f"| {c} | {v} | {len(r)} | {ok(r)} | " + " | ".join(ok(g) for g in gs) + " | " +
                     " | ".join(ok([x for x in r if x["point"] == p]) for p in ("upstream", "windward", "crest", "lee", "foot")) + f" | {ok(ro)} |")
    L.append("\n### Пикар: u_ref, pot, vortex по точкам (м/с)")
    for c in ("C1", "C2", "C4"):
        L.append(f"\n{c}:\n| точка | x | z_agl | u_P(центр) | pot | vortex |\n|---|---|---|---|---|---|")
        pr = {(x["point"], x["z_agl"], x["variant"]): x for x in rows if x["case"] == c}
        for x in [x for x in rows if x["case"] == c and x["variant"] == "potential"]:
            vx = pr[(x["point"], x["z_agl"], "vortex")]
            L.append(f"| {x['point']} | {x['x']:.0f} | {x['z_agl']:.1f} | {x['u_ref']:.2f} | {x['u_pan']:.2f} ({'+' if x['within_tol'] else '-'}) | {vx['u_pan']:.2f} ({'+' if vx['within_tol'] else '-'}) |")
    L.append("\n### Lubitz–White: dS (однородный фон, потенциальный и вихревой)")
    L.append("| модель | точка | z_agl, м | dS труба | dS pot | dS vortex |\n|---|---|---|---|---|---|")
    for c in [k for k in info if k.startswith("LW_")]:
        for p in ("crest", "windward", "foot"):
            a = {x["variant"]: x for x in rows if x["case"] == c and x["point"] == p}
            if a: L.append(f"| {c} | {p} | {a['potential']['z_agl']:.0f} | {a['potential']['u_ref']:.2f} | {a['potential']['u_pan']:.2f} | {a['vortex']['u_pan']:.2f} |")
    L.append("\n### Ротор")
    L.append("| случай | вариант | есть (панели) | L_pan, м | есть (эталон) | L_ref, м |\n|---|---|---|---|---|---|")
    for r in rotor: L.append(f"| {r['case']} | {r['variant']} | {r['rotor_pan']} | {r['L_pan']:.0f} | {r['rotor_ref']} | {r['L_ref']} |")
    open(os.path.join(C.OUT, "tables.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
