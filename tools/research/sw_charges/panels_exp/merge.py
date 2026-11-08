"""SWC-12: сбор out/panels2d/cases/*.json → points.{json,csv} (SW7), sens.json, tables.md (stdout-таблицы для вывода), PNG."""
import csv
import datetime
import glob
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

PRIMARY = ["C1", "C2", "C4", "PERD_NE", "PERD_SW", "LW_H3", "LW_MD", "LW_UCD", "LW_H5", "LW_GI", "LW_H8"]
KEYS = ["case", "variant", "point", "x", "z_agl", "ref_kind", "ref_source", "ref_reliability", "u_ref", "w_ref", "u_pan",
        "w_pan", "units", "err", "within_tol", "ds_min", "t_solve_ms", "t_query_us"]
EXTRA = ["shed", "t_step_ms", "n_vortices", "drift_u"]


def load(name):
    return json.load(open(os.path.join(C.CASES_DIR, name + ".json")))


def main():
    rows, rotor, info = [], [], {}
    for c in PRIMARY:
        d = load(c)
        rows += d["rows"]
        rotor += d["rotor"]
        info[c] = dict(info=d["info"], summary={v: {k: x for k, x in s.items() if k != "rotor_line"} for v, s in d["summary"].items()},
                       wall_s=d["wall_s"], ds_min=d["ds_min"])
    out = dict(format="sw-panels2d", version=1, git=C.git_rev(), created=datetime.datetime.now().isoformat(timespec="seconds"),
               tol_picard=C.TOL, rows=rows, rotor=rotor)
    with open(os.path.join(C.OUT, "points.json"), "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=0)
    with open(os.path.join(C.OUT, "points.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=KEYS + EXTRA, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(C.OUT, "info.json"), "w") as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    L = []
    # ---- Пикар
    L.append("### Пикар: доля within_tol (±15 %)")
    L.append("| случай | вариант | всего | в допуске | z=10 | z=50 | z=300 | upstream | windward | crest | lee | foot |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for c in ("C1", "C2", "C4"):
        for v in ("potential", "vortex"):
            r = [x for x in rows if x["case"] == c and x["variant"] == v]
            ok = lambda s: f"{sum(x['within_tol'] for x in s)}/{len(s)}"
            L.append(f"| {c} | {v} | {len(r)} | {ok(r)} | " + " | ".join(ok([x for x in r if x['z_agl'] == z]) for z in (10, 50, 300)) + " | " +
                     " | ".join(ok([x for x in r if x['point'] == p]) for p in ("upstream", "windward", "crest", "lee", "foot")) + " |")
    L.append("\n### Пикар: u_pan / u_ref по точкам (м/с)")
    for c in ("C1", "C2", "C4"):
        L.append(f"\n{c}: " )
        L.append("| точка | z | u_P | pot | vortex |")
        L.append("|---|---|---|---|---|")
        for p in ("upstream", "windward", "crest", "lee", "foot"):
            for z in (10, 50, 300):
                a = [x for x in rows if x["case"] == c and x["point"] == p and x["z_agl"] == z]
                g = {x["variant"]: x for x in a}
                L.append(f"| {p} | {z} | {g['potential']['u_ref']:.2f} | {g['potential']['u_pan']:.2f} | {g['vortex']['u_pan']:.2f} |")
    # ---- LW
    L.append("\n### Lubitz–White: dS на гребне и на склоне")
    L.append("| модель | точка | z_agl, м | dS_труба | dS pot | dS vortex | shed |")
    L.append("|---|---|---|---|---|---|---|")
    for c in PRIMARY[5:]:
        for p in ("crest", "windward", "foot"):
            a = {x["variant"]: x for x in rows if x["case"] == c and x["point"] == p}
            if a:
                L.append(f"| {c} | {p} | {a['potential']['z_agl']:.0f} | {a['potential']['u_ref']:.2f} | {a['potential']['u_pan']:.2f} | {a['vortex']['u_pan']:.2f} | {a['vortex']['shed']} |")
    # ---- Perdigão
    L.append("\n### Perdigão: мачты (u_∥, м/с; пан. нормирован на U100 опорной мачты)")
    for c in ("PERD_NE", "PERD_SW"):
        for v in ("potential", "vortex"):
            r = [x for x in rows if x["case"] == c and x["variant"] == v]
            e = np.array([x["err"] for x in r])
            ur = np.array([x["u_ref"] for x in r]); up = np.array([x["u_pan"] for x in r])
            rev = ur < 0
            sg = np.sign(ur) == np.sign(up)
            L.append(f"- {c} {v}: n={len(r)}, RMSE {np.sqrt(np.mean(e**2)):.2f}, bias {e.mean():+.2f}, r={np.corrcoef(ur,up)[0,1]:.2f}, "
                     f"знак совпал {sg.sum()}/{len(r)}, мачт с обратным u_∥ в данных {rev.sum()}, из них модель даёт обратный {(up[rev]<0).sum()}; "
                     f"RMSE на гребнях {np.sqrt(np.mean([x['err']**2 for x in r if x['point']=='crest']) ):.2f}")
        L.append("| точка | мачта, z | u_∥ данные | pot | vortex | ")
        L.append("|---|---|---|---|---|")
        pr = {(x["x"], x["z_agl"], x["variant"]): x for x in rows if x["case"] == c}
        for x in [x for x in rows if x["case"] == c and x["variant"] == "potential"]:
            vx = pr[(x["x"], x["z_agl"], "vortex")]
            L.append(f"| {x['point']} | {x['ref_source'].split(' ')[2]} {x['z_agl']:.0f} | {x['u_ref']:.2f} | {x['u_pan']:.2f} | {vx['u_pan']:.2f} |")

    # ---- паритет на Perdigão: панели против модели игры (air3d, b1 nom) на тех же мачтах (u_∥/S_ref)
    L.append("\n### Perdigão: паритет с моделью игры (b1 nom, u_∥/S_ref)")
    b1 = {}
    for ln in open(os.path.join(C.REPO, "tools/research/cases/b1/out/ctl_table.md"), encoding="utf-8"):
        if ln.startswith("| ne |") or ln.startswith("| sw |"):
            p = [q.strip() for q in ln.strip().strip("|").split("|")]
            nm, z = p[1].split()
            b1[(p[0], nm, int(z))] = (float(p[6]), float(p[7]))
    par = {}
    for c, sub in (("PERD_NE", "ne"), ("PERD_SW", "sw")):
        u100 = [x for x in rows if x["case"] == c][0]
        import re
        for v in ("potential", "vortex"):
            e_p, e_b, n_ = [], [], 0
            for x in [x for x in rows if x["case"] == c and x["variant"] == v]:
                nm = x["ref_source"].split(" ")[2]
                key = (sub, nm, int(x["z_agl"]))
                if key not in b1:
                    continue
                d_, m_ = b1[key]
                # u_ref = d*u100: нормировка опорной u100 из info
                U = info[c]["info"]["u100"]
                e_p.append(x["u_pan"] / U - d_); e_b.append(m_ - d_)
            e_p, e_b = np.array(e_p), np.array(e_b)
            par[(c, v)] = dict(n=len(e_p), rmse_pan=float(np.sqrt(np.mean(e_p**2))), rmse_air=float(np.sqrt(np.mean(e_b**2))),
                               bias_pan=float(e_p.mean()), bias_air=float(e_b.mean()),
                               within15_pan=int((np.abs(e_p) <= 0.15).sum()), within15_air=int((np.abs(e_b) <= 0.15).sum()))
            q = par[(c, v)]
            L.append(f"- {c} {v}: n={q['n']}, RMSE(u_∥/S_ref): панели {q['rmse_pan']:.2f}, игра {q['rmse_air']:.2f}; смещение {q['bias_pan']:+.2f} / {q['bias_air']:+.2f}; в ±0,15 абс.: панели {q['within15_pan']}/{q['n']}, игра {q['within15_air']}/{q['n']}")
    json.dump({f"{k[0]}|{k[1]}": v for k, v in par.items()}, open(os.path.join(C.OUT, "parity_perdigao.json"), "w"), indent=1)
    L.append("\n### Ротор")
    L.append("| случай | вариант | есть (панели) | L_pan, м | есть (эталон) | L_ref, м |")
    L.append("|---|---|---|---|---|---|")
    for r in rotor:
        L.append(f"| {r['case']} | {r['variant']} | {r['rotor_pan']} | {r['L_pan']:.0f} | {r['rotor_ref']} | {r['L_ref']} |")
    L.append("\n### Время")
    L.append("| случай | N панелей | solve, мс (pot) | запрос, мкс/точку | шаг, мс | вихрей (ср.) | шагов | dt, с | t модели, с | дрейф u, м/с | wall, с |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for c in PRIMARY:
        s = info[c]["summary"]; p, v = s["potential"], s["vortex"]
        f = lambda x, n=1: "—" if x is None else f"{x:.{n}f}"
        L.append(f"| {c} | {p['n_panels']:.0f} | {f(p['t_solve_ms'])} | {f(p['t_query_us'])} | {f(v.get('t_step_ms'))} | {f(v.get('n_vortices'),0)} | {f(v.get('n_steps'),0)} | {f(v.get('dt'),2)} | {f(v.get('t_model'),0)} | {f(v.get('drift_u'),2)} | {info[c]['wall_s']:.0f} |")
    # ---- чувствительность
    L.append("\n### Чувствительность")
    sens = {}
    for fn in sorted(glob.glob(os.path.join(C.CASES_DIR, "*_*.json"))):
        nm = os.path.basename(fn)[:-5]
        if nm in PRIMARY or not any(t in nm for t in ("_ds", "_sm")):
            continue
        d = json.load(open(fn))
        base = nm.split("_ds")[0].split("_sm")[0]
        sens[nm] = d
    for nm, d in sens.items():
        base = nm.split("_ds")[0].split("_sm")[0]
        b = load(base)
        L.append(f"\n{nm} против {base} (ds_min {d['ds_min']} vs {b['ds_min']}):")
        L.append("| вариант | точка | z | u база | u чувств. |")
        L.append("|---|---|---|---|---|")
        bm = {(x["variant"], x["point"], x["z_agl"], x["x"]): x for x in b["rows"]}
        for x in d["rows"]:
            y = bm.get((x["variant"], x["point"], x["z_agl"], x["x"]))
            if y and x["point"] in ("crest", "lee", "valley", "windward"):
                L.append(f"| {x['variant']} | {x['point']} | {x['z_agl']:.0f} | {y['u_pan']:.2f} | {x['u_pan']:.2f} |")
        for r, r0 in zip(d["rotor"], b["rotor"]):
            L.append(f"- ротор {r['variant']}: L {r['L_pan']:.0f} (база {r0['L_pan']:.0f})")
        sv = d["summary"].get("vortex", {}); sb = b["summary"].get("vortex", {})
        L.append(f"- шаг, мс: {sv.get('t_step_ms')} (база {sb.get('t_step_ms')}); solve мс {d['summary']['potential']['t_solve_ms']:.1f} (база {b['summary']['potential']['t_solve_ms']:.1f})")
    open(os.path.join(C.OUT, "tables.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))
    # ---- рисунки
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 3, figsize=(13, 4))
    for a, cs, ttl in ((ax[0], ["C1", "C2", "C4"], "Пикар, м/с"), (ax[1], ["PERD_NE", "PERD_SW"], "мачты Perdigão, м/с")):
        for v, mk in (("potential", "o"), ("vortex", "^")):
            r = [x for x in rows if x["case"] in cs and x["variant"] == v]
            a.scatter([x["u_ref"] for x in r], [x["u_pan"] for x in r], marker=mk, s=18, label=v)
        lim = a.get_xlim(); a.plot(lim, lim, "k-", lw=.5); a.set_xlabel("эталон"); a.set_ylabel("панели"); a.set_title(ttl); a.legend()
    for v, mk in (("potential", "o"), ("vortex", "^")):
        r = [x for x in rows if x["case"].startswith("LW_") and x["point"] == "crest" and x["variant"] == v]
        ax[2].scatter([x["u_ref"] for x in r], [x["u_pan"] for x in r], marker=mk, label=v)
    ax[2].plot([0, 1.1], [0, 1.1], "k-", lw=.5); ax[2].set_xlabel("dS труба"); ax[2].set_ylabel("dS панели"); ax[2].set_title("Lubitz–White, гребень"); ax[2].legend()
    fig.tight_layout(); fig.savefig(os.path.join(C.OUT, "scatter.png"), dpi=110); plt.close(fig)
    fig, ax = plt.subplots(1, 5, figsize=(18, 3.2))
    for a, c in zip(ax, ["C1", "C2", "C4", "PERD_NE", "PERD_SW"]):
        d = load(c)
        for v, s in d["summary"].items():
            a.plot(s["rotor_line"]["x"], [np.nan if u is None else u for u in s["rotor_line"]["u"]], label=v)
        a.axhline(C.ROTOR_U, c="k", lw=.5); a.set_title(c + " u на z_agl 15 м"); a.legend()
    fig.tight_layout(); fig.savefig(os.path.join(C.OUT, "rotor_lines.png"), dpi=100); plt.close(fig)


if __name__ == "__main__":
    main()
