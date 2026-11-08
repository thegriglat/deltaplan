"""SWC-19: сбор SW7 v3: 4 прежних варианта (potential, vortex, potential_bl, vortex_bl) — переносом из points.json v2 (SWC-17),
potential_jh / vortex_jh — из cases/<case>_jh.json (run_jh.py). Пишет points.{json,csv} (version 3), info.json, tables.md, parity.json,
problems.json. Прежняя версия (SWC-17, v2) — prev_swc17/ (points_v2.json.gz, чтобы контрактный тест не проверял её как текущую)."""
import csv, datetime, gzip, json, os, shutil, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from merge import KEYS

EXTRA = ["shed", "t_step_ms", "n_vortices", "drift_u"]
CASES = ["C1", "C2", "C4", "PERD_NE", "PERD_SW"] + [f"LW_{m}" for m in ("H3", "MD", "UCD", "H5", "GI", "H8")]
OLDV = ("potential", "vortex", "potential_bl", "vortex_bl")
NEWV = ("potential_jh", "vortex_jh")
VARS = OLDV + NEWV
REF_K = 1.5
HGRP = ["нижняя клетка", "k0+1", "~50 м", "~300 м"]


def main():
    out_dir = C.OUT
    prev = os.path.join(out_dir, "prev_swc17")
    pj = os.path.join(out_dir, "points.json")
    if not os.path.isdir(prev):
        os.makedirs(prev)
        for f in ("points.csv", "info.json", "tables.md", "parity.json", "parity_perdigao.json"):
            if os.path.exists(os.path.join(out_dir, f)): shutil.copy(os.path.join(out_dir, f), os.path.join(prev, f))
        with open(pj, "rb") as fi, gzip.open(os.path.join(prev, "points_v2.json.gz"), "wb") as fo:
            fo.write(fi.read())
    old = json.load(gzip.open(os.path.join(prev, "points_v2.json.gz")))
    oinfo = json.load(open(os.path.join(prev, "info.json")))
    perr = json.load(open(os.path.join(out_dir, "tunnel", "picard_err.json")))
    rows, rotor, info = [], [], {}
    for c in CASES:
        new = json.load(open(os.path.join(C.CASES_DIR, c + "_jh.json")))
        for var in VARS:
            if var in OLDV:
                blk = [r for r in old["rows"] if r["case"] == c and r["variant"] == var]
            else:
                blk = [r for r in new["rows"] if r["variant"] == var]
                for n, r in enumerate(blk):
                    r["ref_err"] = None; r["within_tol_ref"] = None
                    if c in perr:
                        p = perr[c]["points"][n]
                        assert abs(p["zagl"] - r["z_agl"]) < 1e-6, (c, n)
                        if p["rel"] is not None:
                            r["ref_err"] = REF_K * p["rel"]
                            r["within_tol_ref"] = bool(r["err"] is not None and abs(r["err"]) <= max(C.TOL, r["ref_err"]) * abs(r["u_ref"]))
                        else:
                            r["within_tol_ref"] = r["within_tol"]
            rows += blk
        rotor += [r for r in old["rotor"] if r["case"] == c and r["variant"] in OLDV]
        rotor += [r for r in new["rotor"] if r["variant"] in NEWV]
        info[c] = dict(old=oinfo.get(c), jh=dict(info=new["info"], summary={v: {k: x for k, x in s.items() if k != "rotor_line"} for v, s in new["summary"].items() if v in NEWV}, wall_s=new["wall_s"]))
    out = dict(format="sw-panels2d", version=3, git=C.git_rev(), created=datetime.datetime.now().isoformat(timespec="seconds"),
               tol_picard=C.TOL, rows=rows, rotor=rotor)
    json.dump(out, open(os.path.join(out_dir, "points.json"), "w"), ensure_ascii=False, indent=0)
    with open(os.path.join(out_dir, "points.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KEYS + ["ref_err", "within_tol_ref"] + EXTRA, extrasaction="ignore"); w.writeheader(); w.writerows(rows)
    json.dump(info, open(os.path.join(out_dir, "info.json"), "w"), ensure_ascii=False, indent=1)

    L, PR = [], {}
    sel = lambda **k: [r for r in rows if all(r[a] == b for a, b in k.items())]
    frac = lambda s, key: f"{sum(bool(x[key]) for x in s)}/{len(s)}"
    def groups(c, v):
        byx = {}
        for x in sel(case=c, variant=v): byx.setdefault(x["point"], []).append(x)
        gs = [[], [], [], []]
        for lst in byx.values():
            for j, q in enumerate(sorted(lst, key=lambda q: q["z_agl"])): gs[j].append(q)
        return gs
    # A. Пикар
    L.append("### A. Пикар (центры клеток P50): within_tol_ref по высотам (15 точек C1+C2+C4; по случаю — 5)")
    L.append("| случай | вариант | всего | " + " | ".join(HGRP) + " |\n|---|---|---|---|---|---|---|")
    pool = {v: [[], [], [], []] for v in VARS}
    for c in ("C1", "C2", "C4"):
        for v in VARS:
            gs = groups(c, v)
            for j in range(4): pool[v][j] += gs[j]
            L.append(f"| {c} | {v} | {frac(sel(case=c, variant=v),'within_tol_ref')} | " + " | ".join(frac(g, 'within_tol_ref') for g in gs) + " |")
    PR["picard"] = {}
    for v in VARS:
        allr = [x for g in pool[v] for x in g]
        L.append(f"| C1+C2+C4 | {v} | {frac(allr,'within_tol_ref')} | " + " | ".join(frac(g, 'within_tol_ref') for g in pool[v]) + " |")
        PR["picard"][v] = {HGRP[j]: dict(n=len(g), tol=sum(bool(x["within_tol"]) for x in g), tol_ref=sum(bool(x["within_tol_ref"]) for x in g)) for j, g in enumerate(pool[v])}
    L.append("\nu по точкам (м/с), + / − = в допуске tol_ref:")
    for c in ("C1", "C2", "C4"):
        L.append(f"\n{c}:\n| точка | x | z_agl | u_P | " + " | ".join(VARS) + " |\n|---|---|---|---|" + "---|" * len(VARS))
        idx = {v: sel(case=c, variant=v) for v in VARS}
        for n, x in enumerate(idx["potential"]):
            cells = [f"{idx[v][n]['u_pan']:.2f} ({'+' if idx[v][n]['within_tol_ref'] else '-'})" for v in VARS]
            L.append(f"| {x['point']} | {x['x']:.0f} | {x['z_agl']:.1f} | {x['u_ref']:.2f} | " + " | ".join(cells) + " |")
    # B. Труба
    L.append("\n### B. Lubitz–White: ΔS (труба; potential — однородный фон SWC-16; *_bl — SWC-17; *_jh — SWC-19)")
    L.append("| модель | точка | z/H | труба | potential | potential_bl | vortex_bl | potential_jh | vortex_jh |\n|---|---|---|---|---|---|---|---|---|")
    PR["tunnel"] = []
    for c in [k for k in CASES if k.startswith("LW_")]:
        H = info[c]["jh"]["info"]["H"]
        for p in ("crest", "windward", "foot"):
            a = {x["variant"]: x for x in sel(case=c, point=p)}
            if not a: continue
            L.append(f"| {c} | {p} | {a['potential_jh']['z_agl']/H:.2f} | {a['potential']['u_ref']:.2f} | " + " | ".join(f"{a[v]['u_pan']:.2f}" for v in ("potential", "potential_bl", "vortex_bl", "potential_jh", "vortex_jh")) + " |")
            PR["tunnel"].append(dict(case=c, point=p, ref=a['potential']['u_ref'], **{v: a[v]['u_pan'] for v in VARS}))
    # C. Perdigão
    b1 = {}
    for ln in open(os.path.join(C.REPO, "tools/research/cases/b1/out/ctl_table.md"), encoding="utf-8"):
        if ln.startswith("| ne |") or ln.startswith("| sw |"):
            p = [q.strip() for q in ln.strip().strip("|").split("|")]
            nm, z = p[1].split(); b1[(p[0], nm, int(z))] = (float(p[6]), float(p[7]))
    L.append("\n### C. Perdigão: u∥/S_ref, RMSE против данных; модель игры b1 nom")
    L.append("| случай | вариант | n | RMSE пан. | RMSE игра | отношение | смещение | в ±0,15: пан. / игра | обратное u∥: данные / модель |\n|---|---|---|---|---|---|---|---|---|")
    PR["perdigao"] = {}
    for c, sub in (("PERD_NE", "ne"), ("PERD_SW", "sw")):
        U = info[c]["old"]["info"]["u100"]
        for v in VARS:
            e_p, e_b, rev, revm = [], [], 0, 0
            for x in sel(case=c, variant=v):
                nm = x["ref_source"].split(" ")[2]; key = (sub, nm, int(x["z_agl"]))
                if key not in b1: continue
                d_, m_ = b1[key]
                e_p.append(x["u_pan"] / U - d_); e_b.append(m_ - d_)
                if d_ < 0: rev += 1; revm += x["u_pan"] < 0
            e_p, e_b = np.array(e_p), np.array(e_b)
            rp, rb = float(np.sqrt(np.mean(e_p ** 2))), float(np.sqrt(np.mean(e_b ** 2)))
            PR["perdigao"][f"{c}|{v}"] = q = dict(n=len(e_p), rmse_pan=rp, rmse_air=rb, ratio=rp / rb, bias_pan=float(e_p.mean()),
                                                  within15_pan=int((abs(e_p) <= .15).sum()), within15_air=int((abs(e_b) <= .15).sum()), rev_data=rev, rev_model=int(revm))
            L.append(f"| {c} | {v} | {q['n']} | {rp:.3f} | {rb:.3f} | {rp/rb:.2f} | {q['bias_pan']:+.3f} | {q['within15_pan']} / {q['within15_air']} | {rev} / {revm} |")
    json.dump(PR, open(os.path.join(out_dir, "parity.json"), "w"), indent=1, ensure_ascii=False)
    # D. Ротор
    L.append("\n### D. Ротор (u < −0,5 м/с на 15 м, > 50 м)")
    L.append("| случай | вариант | есть (пан.) | L_pan, м | есть (эталон) | L_ref, м |\n|---|---|---|---|---|---|")
    for r in rotor:
        if r["case"].startswith("LW_") and r["variant"] not in ("potential",): continue
        L.append(f"| {r['case']} | {r['variant']} | {r['rotor_pan']} | {r['L_pan']:.0f} | {r['rotor_ref']} | {r['L_ref']} |")
    # E. Отрыв
    L.append("\n### E. Отрыв Хеда с lee_only (potential_jh — по потенциальному решению; vortex_jh — на конец счёта; ср. число отрывов за окно)")
    L.append("| случай | отрыв pot_jh (x, м; H) | отрыв vortex_jh (x, м; H) | ср. число за окно | вихрей |\n|---|---|---|---|---|")
    for c in CASES:
        s = info[c]["jh"]["summary"]
        f = lambda b: ", ".join(f"{q['x']:.0f} (H {q['H']:.1f})" for q in b["sep"]) or "нет"
        L.append(f"| {c} | {f(s['potential_jh']['sep'])} | {f(s['vortex_jh']['sep'])} | {s['vortex_jh'].get('sep_n_mean') or 0:.1f} | {s['vortex_jh'].get('n_vortices') or 0:.0f} |")
    # F. Время
    L.append("\n### F. Время (CPU, 1 поток; 3 процесса делили одно ядро под замком cpu)")
    L.append("| случай | N | solve, мс | запрос pot, мкс | запрос pot_jh, мкс | запрос vortex_jh, мкс | шаг vortex_jh, мс | шагов | дрейф u, м/с | wall, с |\n|---|---|---|---|---|---|---|---|---|---|")
    g = lambda x, n=1: "—" if x is None else f"{x:.{n}f}"
    for c in CASES:
        s = info[c]["jh"]["summary"]; p, pj_, vj = info[c]["old"]["summary"]["potential"], s["potential_jh"], s["vortex_jh"]
        L.append(f"| {c} | {g(p['n_panels'],0)} | {g(p['t_solve_ms'])} | {g(p['t_query_us'])} | {g(pj_['t_query_us'])} | {g(vj['t_query_us'])} | {g(vj.get('t_step_ms'))} | {g(vj.get('n_steps'),0)} | {g(vj.get('drift_u'),2)} | {info[c]['jh']['wall_s']:.0f} |")
    open(os.path.join(out_dir, "tables.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
