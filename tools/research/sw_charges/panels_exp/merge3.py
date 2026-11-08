"""SWC-17: сбор SW7 v2: potential / vortex — из SWC-16 (cases/<C>_cc.json, PERD_*.json, LW_*_uni.json), potential_bl / vortex_bl — из
cases/<case>_bl.json (run_bl.py). Добавляет ref_err и within_tol_ref. Пишет points.{json,csv} (version 2), info.json, tables.md,
parity.json. Прежняя версия (SWC-16) — prev_swc16/."""
import csv, datetime, json, os, re, shutil, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from merge import KEYS

EXTRA = ["shed", "t_step_ms", "n_vortices", "drift_u"]
OLD = {"C1": "C1_cc", "C2": "C2_cc", "C4": "C4_cc", "PERD_NE": "PERD_NE", "PERD_SW": "PERD_SW", **{f"LW_{m}": f"LW_{m}_uni" for m in ("H3", "MD", "UCD", "H5", "GI", "H8")}}
CASES = list(OLD)
VARS = ("potential", "vortex", "potential_bl", "vortex_bl")
REF_K = 1.5          # множитель 1/(2^p - 1) при p ≈ 0,6–0,8 (stage2-2d-tunnel.md): ошибка P50 ≈ 1,5·|P100r − P50|
HGRP = ["нижняя клетка", "k0+1", "~50 м", "~300 м"]


def load(n): return json.load(open(os.path.join(C.CASES_DIR, n + ".json")))


def main():
    out_dir = C.OUT
    prev = os.path.join(out_dir, "prev_swc16")
    if not os.path.isdir(prev):
        os.makedirs(prev)
        import gzip
        for f in ("points.csv", "info.json", "tables.md", "parity_perdigao.json"):
            shutil.copy(os.path.join(out_dir, f), os.path.join(prev, f))
        with open(os.path.join(out_dir, "points.json"), "rb") as fi, gzip.open(os.path.join(prev, "points_v1.json.gz"), "wb") as fo:
            fo.write(fi.read())          # gzip: иначе контрактный тест проверяет прежнюю версию v1
    perr = json.load(open(os.path.join(out_dir, "tunnel", "picard_err.json")))
    rows, rotor, info = [], [], {}
    nref_null = {}
    for c in CASES:
        old, new = load(OLD[c]), load(c + "_bl")
        r_old = [r for r in old["rows"] if r["variant"] in ("potential", "vortex")]
        r_new = [r for r in new["rows"] if r["variant"] in ("potential_bl", "vortex_bl")]
        for var in VARS:
            blk = [r for r in r_old + r_new if r["variant"] == var]
            for n, r in enumerate(blk):
                r["ref_err"] = None; r["within_tol_ref"] = None
                if c in perr:
                    p = perr[c]["points"][n]
                    assert abs(p["zagl"] - r["z_agl"]) < 1e-6, (c, n)
                    if p["rel"] is not None:
                        r["ref_err"] = REF_K * p["rel"]
                        r["within_tol_ref"] = bool(r["err"] is not None and abs(r["err"]) <= max(C.TOL, r["ref_err"]) * abs(r["u_ref"]))
                    else:
                        r["within_tol_ref"] = r["within_tol"]          # смешанная клетка: погрешность не оценена, допуск 15 %
                        nref_null[c] = nref_null.get(c, 0) + (var == "potential")
                rows.append(r)
        rotor += [r for r in old["rotor"] if r["variant"] in ("potential", "vortex")]
        rotor += [r for r in new["rotor"] if r["variant"] in ("potential_bl", "vortex_bl")]
        sm = {}
        for v, s in old["summary"].items(): sm[v] = {k: x for k, x in s.items() if k != "rotor_line"}
        for v, s in new["summary"].items():
            if v != "potential": sm[v] = {k: x for k, x in s.items() if k != "rotor_line"}
        info[c] = dict(info=dict(old["info"], bl=new["info"]), summary=sm, wall_s=dict(old=old["wall_s"], bl=new["wall_s"]),
                       ds_min=old["ds_min"], source=[OLD[c], c + "_bl"])
    out = dict(format="sw-panels2d", version=2, git=C.git_rev(), created=datetime.datetime.now().isoformat(timespec="seconds"),
               tol_picard=C.TOL, rows=rows, rotor=rotor)
    json.dump(out, open(os.path.join(out_dir, "points.json"), "w"), ensure_ascii=False, indent=0)
    with open(os.path.join(out_dir, "points.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KEYS + ["ref_err", "within_tol_ref"] + EXTRA, extrasaction="ignore"); w.writeheader(); w.writerows(rows)
    json.dump(info, open(os.path.join(out_dir, "info.json"), "w"), ensure_ascii=False, indent=1)

    L = []
    sel = lambda **k: [r for r in rows if all(r[a] == b for a, b in k.items())]
    frac = lambda s, key: f"{sum(bool(x[key]) for x in s)}/{len(s)}"
    # ---- A. Пикар
    def groups(c, v):
        byx = {}
        for x in sel(case=c, variant=v): byx.setdefault(x["point"], []).append(x)
        gs = [[], [], [], []]
        for lst in byx.values():
            for j, q in enumerate(sorted(lst, key=lambda q: q["z_agl"])): gs[j].append(q)
        return gs
    par = {"picard": {}}
    L.append("### A. Пикар по центрам клеток: within_tol (±15 %) / within_tol_ref (max(15 %, 1,5·|P100r−P50|/u))")
    L.append("| случай | вариант | всего tol | всего tol_ref | " + " | ".join(f"{g} tol / tol_ref" for g in HGRP) + " |")
    L.append("|---|---|---|---|---|---|---|---|")
    pool = {v: [[], [], [], []] for v in VARS}
    for c in ("C1", "C2", "C4"):
        for v in VARS:
            gs = groups(c, v)
            for j in range(4): pool[v][j] += gs[j]
            allr = sel(case=c, variant=v)
            L.append(f"| {c} | {v} | {frac(allr,'within_tol')} | {frac(allr,'within_tol_ref')} | " + " | ".join(f"{frac(g,'within_tol')} / {frac(g,'within_tol_ref')}" for g in gs) + " |")
    for v in VARS:
        allr = [x for g in pool[v] for x in g]
        L.append(f"| C1+C2+C4 | {v} | {frac(allr,'within_tol')} | {frac(allr,'within_tol_ref')} | " + " | ".join(f"{frac(g,'within_tol')} / {frac(g,'within_tol_ref')}" for g in pool[v]) + " |")
        par["picard"][v] = {HGRP[j]: dict(n=len(g), tol=sum(bool(x["within_tol"]) for x in g), tol_ref=sum(bool(x["within_tol_ref"]) for x in g),
                                         parity=bool(len(g) and sum(bool(x["within_tol_ref"]) for x in g) >= 2 / 3 * len(g))) for j, g in enumerate(pool[v])}
    L.append(f"\nКлеток без оценки ref_err (смешанные дети P100): {nref_null}; для них within_tol_ref = within_tol.")
    L.append("\nu по точкам (м/с), знак + / − = в допуске tol_ref:")
    for c in ("C1", "C2", "C4"):
        L.append(f"\n{c}:\n| точка | x | z_agl | u_P | ref_err | " + " | ".join(VARS) + " |\n|---|---|---|---|---|" + "---|" * 4)
        idx = {v: sel(case=c, variant=v) for v in VARS}
        for n, x in enumerate(idx["potential"]):
            cells = [f"{idx[v][n]['u_pan']:.2f} ({'+' if idx[v][n]['within_tol_ref'] else '-'})" for v in VARS]
            re_ = "—" if x["ref_err"] is None else f"{x['ref_err']*100:.0f} %"
            L.append(f"| {x['point']} | {x['x']:.0f} | {x['z_agl']:.1f} | {x['u_ref']:.2f} | {re_} | " + " | ".join(cells) + " |")
    # ---- B. Труба
    L.append("\n### B. Lubitz–White: ΔS у поверхности / на заданной высоте (труба; uni = однородный фон SWC-16; prof = профильный фон без слоя, масштаб SWC-17)")
    L.append("| модель | точка | z/H | труба | potential (uni) | vortex (uni) | potential (prof) | potential_bl | vortex_bl |\n|---|---|---|---|---|---|---|---|---|")
    lw_rows = []
    for c in [k for k in CASES if k.startswith("LW_")]:
        nb = load(c + "_bl")
        prof = {r["point"]: r for r in nb["rows"] if r["variant"] == "potential"}
        for p in ("crest", "windward", "foot"):
            a = {x["variant"]: x for x in sel(case=c, point=p)}
            if not a: continue
            Hh = nb["info"]["H"]
            lw_rows.append((c, p, a, prof[p]))
            L.append(f"| {c} | {p} | {a['potential_bl']['z_agl']/Hh:.2f} | {a['potential']['u_ref']:.2f} | {a['potential']['u_pan']:.2f} | {a['vortex']['u_pan']:.2f} | {prof[p]['u_pan']:.2f} | {a['potential_bl']['u_pan']:.2f} | {a['vortex_bl']['u_pan']:.2f} |")
    L.append("\nЧувствительность к δ0/H (δ0 = 500·z0 = 50 м, z0 = 0,1 м): высота хребта H = 21 м (z0/H трубы, δ0/H = 2,4), 50 м (δ0/H = 1), 150 м (δ0/H = 0,33). ΔS potential_bl / vortex_bl:")
    L.append("| модель | точка | труба | H=21 | H=50 | H=150 |\n|---|---|---|---|---|---|")
    for m in ("LW_H3", "LW_UCD"):
        for p in ("crest",) + (("windward", "foot") if m == "LW_UCD" else ()):
            cells = []
            for tg in ("_bl", "_bl_H50", "_bl_H150"):
                fn = os.path.join(C.CASES_DIR, m + tg + ".json")
                if not os.path.exists(fn): cells.append("—"); continue
                d = json.load(open(fn)); g = {r["variant"]: r for r in d["rows"] if r["point"] == p}
                cells.append(f"{g['potential_bl']['u_pan']:.2f} / {g['vortex_bl']['u_pan']:.2f} (pot prof {g['potential']['u_pan']:.2f})")
            ref = sel(case=m, point=p, variant="potential")[0]["u_ref"]
            L.append(f"| {m} | {p} | {ref:.2f} | " + " | ".join(cells) + " |")
    # ---- C. Perdigão
    L.append("\n### C. Perdigão: u_∥/S_ref, RMSE против данных; модель игры b1 nom")
    b1 = {}
    for ln in open(os.path.join(C.REPO, "tools/research/cases/b1/out/ctl_table.md"), encoding="utf-8"):
        if ln.startswith("| ne |") or ln.startswith("| sw |"):
            p = [q.strip() for q in ln.strip().strip("|").split("|")]
            nm, z = p[1].split(); b1[(p[0], nm, int(z))] = (float(p[6]), float(p[7]))
    par["perdigao"] = {}
    L.append("| случай | вариант | n | RMSE пан. | RMSE игра | отношение | паритет (≤ 1,15) | смещение пан. | в ±0,15: пан. / игра | обратное u∥: данные / модель |\n|---|---|---|---|---|---|---|---|---|---|")
    for c, sub in (("PERD_NE", "ne"), ("PERD_SW", "sw")):
        U = info[c]["info"]["u100"]
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
            par["perdigao"][f"{c}|{v}"] = dict(n=len(e_p), rmse_pan=rp, rmse_air=rb, ratio=rp / rb, parity=bool(rp <= 1.15 * rb),
                                               bias_pan=float(e_p.mean()), within15_pan=int((abs(e_p) <= .15).sum()), within15_air=int((abs(e_b) <= .15).sum()),
                                               rev_data=rev, rev_model=int(revm))
            q = par["perdigao"][f"{c}|{v}"]
            L.append(f"| {c} | {v} | {q['n']} | {rp:.3f} | {rb:.3f} | {rp/rb:.2f} | {'да' if q['parity'] else 'нет'} | {q['bias_pan']:+.3f} | {q['within15_pan']} / {q['within15_air']} | {rev} / {revm} |")
    # чувствительность Perdigão к z0 слоя
    L.append("\nЧувствительность Perdigão к z0 слоя (0,1 м вместо z0_nominal 0,645 м; δ0 = 50 м вместо 322 м): potential_bl / vortex_bl")
    L.append("| случай | вариант | RMSE пан. | отношение к игре | отрывы (x, м) | ротор L, м (эталон) |\n|---|---|---|---|---|---|")
    for c, sub in (("PERD_NE", "ne"), ("PERD_SW", "sw")):
        fn = os.path.join(C.CASES_DIR, c + "_bl_z0_0.1.json")
        if not os.path.exists(fn): continue
        d = json.load(open(fn)); U = d["info"]["u100"]
        for v in ("potential_bl", "vortex_bl"):
            e_p, e_b = [], []
            for x in [x for x in d["rows"] if x["variant"] == v]:
                nm = x["ref_source"].split(" ")[2]; key = (sub, nm, int(x["z_agl"]))
                if key in b1: e_p.append(x["u_pan"] / U - b1[key][0]); e_b.append(b1[key][1] - b1[key][0])
            rp, rb = float(np.sqrt(np.mean(np.square(e_p)))), float(np.sqrt(np.mean(np.square(e_b))))
            sp = d["summary"][v]["sep"]["sep"]; rr = [r for r in d["rotor"] if r["variant"] == v][0]
            par["perdigao"][f"{c}|{v}|z0=0.1"] = dict(rmse_pan=rp, rmse_air=rb, ratio=rp / rb, parity=bool(rp <= 1.15 * rb), L_pan=rr["L_pan"], n_vortices=d["summary"][v].get("n_vortices"))
            L.append(f"| {c} | {v} | {rp:.3f} | {rp/rb:.2f} | " + (", ".join(f"{q['x']:.0f}" for q in sp) or "нет") + f" | {rr['L_pan']:.0f} ({rr['L_ref']:.0f}) |")
    json.dump(par, open(os.path.join(out_dir, "parity.json"), "w"), indent=1, ensure_ascii=False)
    # ---- D. Ротор
    L.append("\n### D. Ротор (u < −0,5 м/с на 15 м, > 50 м)")
    L.append("| случай | вариант | есть (пан.) | L_pan, м | есть (эталон) | L_ref, м |\n|---|---|---|---|---|---|")
    for r in rotor:
        if r["case"].startswith("LW_") and r["variant"].endswith("_bl"): continue
        L.append(f"| {r['case']} | {r['variant']} | {r['rotor_pan']} | {r['L_pan']:.0f} | {r['rotor_ref']} | {r['L_ref']} |")
    # ---- E. Слой и отрыв
    L.append("\n### E. Слой и отрыв Хеда (potential_bl: по потенциальному решению; vortex_bl: на конец счёта; среднее число точек отрыва за окно)")
    L.append("| случай | δ0, м | H max (pot_bl) | отрывы pot_bl (x, м) | отрывы vortex_bl (x, м; H) | ср. число отрывов за окно | вихрей |\n|---|---|---|---|---|---|---|")
    for c in CASES:
        s = info[c]["summary"]
        pb, vb = s["potential_bl"]["sep"], s["vortex_bl"]["sep"]
        f = lambda b: ", ".join(f"{q['x']:.0f} (H {q['H']:.1f})" for q in b["sep"]) or "нет"
        L.append(f"| {c} | {pb['delta0']:.0f} | {pb['Hmax']:.2f} | {f(pb)} | {f(vb)} | {s['vortex_bl'].get('sep_n_mean') or 0:.1f} | {s['vortex_bl'].get('n_vortices') or 0:.0f} |")
    # ---- F. Время
    L.append("\n### F. Время (CPU, 1 поток, под замком cpu — cgroup 100 %, 3 процесса делили ядро)")
    L.append("| случай | N | solve, мс | запрос pot, мкс | запрос pot_bl, мкс | слой (BL+отрыв), мс | шаг vortex_bl, мс | шагов | dt, с | дрейф u, м/с | wall bl, с |\n|---|---|---|---|---|---|---|---|---|---|---|")
    g = lambda x, n=1: "—" if x is None else f"{x:.{n}f}"
    for c in CASES:
        s = info[c]["summary"]; p, pb, vb = s["potential"], s["potential_bl"], s["vortex_bl"]
        L.append(f"| {c} | {g(p['n_panels'],0)} | {g(p['t_solve_ms'])} | {g(p['t_query_us'])} | {g(pb['t_query_us'])} | {g(pb.get('t_bl_ms'))} | {g(vb.get('t_step_ms'))} | {g(vb.get('n_steps'),0)} | {g(vb.get('dt'),2)} | {g(vb.get('drift_u'),2)} | {info[c]['wall_s']['bl']:.0f} |")
    open(os.path.join(out_dir, "tables.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
