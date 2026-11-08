"""SWD-17: вариант chain_jh (chain3d, SWD9 v5: звено по геометрии, state по S) в постановке основного набора SWD-5.

  ./py compare/chain_cmp.py run [CASE ...]    # расчёт случаев (кеш out/compare/_cache/<case>_chain.json)
  ./py compare/chain_cmp.py merge             # дописать chain_jh в out/compare/points.json (version 7) + csv + раздел tables.md
Постановка та же, что у potential_jh: σ = 40 м, ds_min = 25 м, логарифмический фон, z0 — медиана растра, фокус панелей в
точках сравнения. Поле chain_jh = velocity_chain (при state "нет" цепочки нет — поле равно potential_jh побитно). Дополнительно,
как диагностика (не основной набор): тот же расчёт с apply_state=False (поле ротора добавлено, несмотря на S) — diag `chain_forced_*`.
"""
from __future__ import annotations

import csv
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import core as C  # noqa: E402
import run_compare as RC  # noqa: E402
import chain3d  # noqa: E402


def cache_file(case):
    return C.CACHE / f"{case}_chain.json"


def _seg_dist(p, a, b):
    a, b, p = np.asarray(a, float), np.asarray(b, float), np.asarray(p, float)
    d = b - a
    t = np.clip(((p - a) @ d) / max(d @ d, 1e-12), 0.0, 1.0)
    return float(np.linalg.norm(p - (a + t * d)))


def rotor_of_transect(rotors, tr):
    """Ротор, ближайший к середине разреза (по оси ротора); None — роторов нет."""
    if not rotors:
        return None
    mid = (0.5 * (tr["x0"] + tr["x1"]), 0.5 * (tr["y0"] + tr["y1"]))
    d = [_seg_dist(mid, r["axis_from"], r["axis_to"]) for r in rotors]
    return rotors[int(np.argmin(d))], float(min(d))


def one_field(run, refs, ch, sig, tag):
    run.chain, run.sigma_chain = ch, sig
    f, tq = run.field("chain_jh")
    return f, tq


def rotor_rows(run, refs, f, rotors, case, variant="chain_jh"):
    nkey, Ud = RC.norm_info(case, refs)
    sn = C.hspeed(f, nkey)
    rr = [r for r in refs["rotor"] if r["case"] == case]
    out = []
    for tr in [t for t in refs["transects"] if t["case"] == case]:
        present, L, depth = C.rotor_scan(run, "chain_jh", tr, Ud / sn)
        men = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "menke2019"]
        pic = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "picard_nom"]
        ref = (men or pic or [None])[0]
        near = rotor_of_transect(rotors, tr)
        st, S, dist, umin = ("нет", None, None, None) if near is None else (near[0]["state"], near[0]["S"], near[1],
                                                                          near[0].get("u_min_over_U"))
        out.append(dict(case=case, transect=tr["name"], variant=variant, present=bool(present), L_m=float(L), depth_m=float(depth),
                        L_ref=ref["L_m"] if ref else None,
                        ref_source=(ref["source"] + ": " + (ref["ref_source"] or "")[:120]) if ref else "нет эталона",
                        state=st, S=RC.fnum(S), rotor_dist_m=dist, u_min_over_U=RC.fnum(umin),
                        L_menke=men[0]["L_m"] if men else None, L_picard=pic[0]["L_m"] if pic else None))
    return out


def rotors_json(info):
    out = []
    for r in info["rotors"]:
        d = {k: (list(v) if isinstance(v, tuple) else v) for k, v in r.items()}
        out.append(d)
    return out


def run_case(case):
    cf = cache_file(case)
    refs = C.load_refs()
    t_all = time.time()
    run = C.Run(case, refs=refs)
    nkey, Ud = RC.norm_info(case, refs)
    # основной: state по S
    t0 = time.time()
    ch, sig, info = chain3d.chain_rotor(run.panels, run.bg, run.z0, run.infl, {})
    t_chain = time.time() - t0
    f, tq = one_field(run, refs, ch, sig, "main")
    t_q_all = tq * len(run.keys) * 1e-6
    rows = RC.make_rows(run, "chain_jh", f, refs)
    rotors = rotors_json(info)
    rot = rotor_rows(run, refs, f, rotors, case)
    # потенциальный контроль: тот же запрос без цепочки (для разницы по точкам)
    fj, _ = run.field("potential_jh")
    rows_j = RC.make_rows(run, "potential_jh", fj, refs)
    dv = [abs(a["s_pan"] - b["s_pan"]) / abs(b["s_pan"]) for a, b in zip(rows, rows_j) if a["s_pan"] is not None and b["s_pan"]]
    t_run = run.t_mesh + run.info["t_assemble_s"] + run.info["t_solve_s"] + t_chain + t_q_all
    timing = dict(case=case, variant="chain_jh", N=int(run.N), t_assemble_s=float(run.info["t_assemble_s"]),
                  t_solve_s=float(run.info["t_solve_s"]), t_query_us=float(tq), t_run_s=float(t_run), backend=run.info["backend"])
    extra = dict(t_mesh_s=run.t_mesh, t_chain_rotor_s=t_chain, n_solves=info["n_solves"], t_wall_s=time.time() - t_all,
                 n_rotors=len(rotors), n_links=len(info["links"]), mass_balance=info["mass_balance"],
                 dv_median=float(np.median(dv)) if dv else None, dv_max=float(np.max(dv)) if dv else None,
                 n_applied_fil_seg=int(len(ch["fil"].seg)))
    # диагностика: поле ротора добавлено вопреки state
    t0 = time.time()
    chF, sigF, infoF = chain3d.chain_rotor(run.panels, run.bg, run.z0, run.infl, dict(apply_state=False))
    t_chainF = time.time() - t0
    fF, tqF = one_field(run, refs, chF, sigF, "forced")
    rotF = rotor_rows(run, refs, fF, rotors_json(infoF), case, "chain_jh")
    rowsF = RC.make_rows(run, "chain_jh", fF, refs)
    forced = dict(rotor=rotF, metrics={k: RC.fnum(v) for k, v in RC.metrics(rowsF).items()}, rotors=rotors_json(infoF),
                  t_chain_rotor_s=t_chainF, n_solves=infoF["n_solves"], links=infoF["links"] and [
                      {k: (list(v) if isinstance(v, tuple) else v) for k, v in l.items()} for l in infoF["links"]])
    out = dict(case=case, rows=rows, rotor=rot, timing=timing, rotors=rotors, extra=extra, forced=forced,
               metrics={k: RC.fnum(v) for k, v in RC.metrics(rows).items()},
               metrics_jh={k: RC.fnum(v) for k, v in RC.metrics(rows_j).items()},
               links=[{k: (list(v) if isinstance(v, tuple) else v) for k, v in l.items()} for l in info["links"]])
    C.CACHE.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(cf, "w"), allow_nan=False, ensure_ascii=False, default=lambda o: float(o) if isinstance(o, np.floating) else bool(o) if isinstance(o, np.bool_) else int(o))
    run.free()
    return out


def merge():
    doc = json.load(open(C.OUT / "points.json"))
    doc["rows"] = [r for r in doc["rows"] if r["variant"] != "chain_jh"]
    doc["rotor"] = [r for r in doc["rotor"] if r["variant"] != "chain_jh"]
    doc["timing"] = [r for r in doc["timing"] if r["variant"] != "chain_jh"]
    doc["diag"] = [d for d in doc["diag"] if not d["item"].startswith("chain_")]
    for r in doc["rotor"]:
        r.setdefault("state", None)
        r.setdefault("S", None)
    res = {c: json.load(open(cache_file(c))) for c in C.CASES}
    for c in C.CASES:
        m = res[c]
        doc["rows"] += m["rows"]
        for r in m["rotor"]:
            doc["rotor"].append({k: v for k, v in r.items() if k not in ("rotor_dist_m", "u_min_over_U", "L_menke", "L_picard")})
            doc["diag"].append(dict(case=c, item=f"chain_rotor_{r['transect']}", value=RC.fnum(r["u_min_over_U"]),
                                    note=f"chain_jh: u_min/U на 10 м между x_c и x_r ближайшего ротора (info['rotors'][].u_min_over_U); state {r['state']}, "
                                         f"S {r['S']}, расстояние разреза до оси ротора {r['rotor_dist_m']} м; поле ротора: "
                                         f"{'добавлено' if r['state'] in ('есть', 'дышит') else 'не добавлено (state нет или роторов нет)'}"))
        doc["timing"].append(m["timing"])
        x = m["extra"]
        for k, note in (("t_mesh_s", "сетка панелей, с"), ("t_chain_rotor_s", "chain_rotor (хребты, звенья, 1–2 решения панелей), с"),
                        ("n_solves", "решений панелей сверх фона (контракт ≤ 2)"), ("n_rotors", "роторов найдено"), ("n_links", "звеньев в применённой цепочке"),
                        ("n_applied_fil_seg", "отрезков нитей в применённой цепочке (0 — state нет)"),
                        ("dv_median", "медиана |s_chain_jh − s_potential_jh|/s_potential_jh по точкам rows"), ("dv_max", "максимум того же")):
            doc["diag"].append(dict(case=c, item=f"chain_{k}", value=RC.fnum(x[k]), note=f"chain_jh: {note}"))
        for i, r in enumerate(m["rotors"]):
            doc["diag"].append(dict(case=c, item=f"chain_rotor{i}_S", value=RC.fnum(r["S"]),
                                    note=f"chain_jh: ротор {i}: длина {r['length_m']:.0f} м, звеньев {r['n_links']}, state {r['state']}, "
                                         f"S_c {r['S_c_range']}, Γ/q {r['Gamma_over_q']}, u_min/U на 10 м {r.get('u_min_over_U')}"))
        fo = m["forced"]
        for r in fo["rotor"]:
            doc["diag"].append(dict(case=c, item=f"chain_forced_{r['transect']}", value=RC.fnum(r["L_m"]),
                                    note=f"chain_jh с apply_state=False (поле ротора добавлено, диагностика): present {r['present']}, L {r['L_m']:.0f} м, "
                                         f"глубина {r['depth_m']:.0f} м, u_min/U на 10 м ближайшего ротора {r['u_min_over_U']}"))
        for k, v in fo["metrics"].items():
            doc["diag"].append(dict(case=c, item=f"chain_forced_{k}", value=RC.fnum(v), note="chain_jh с apply_state=False: метрика rows"))
    doc["version"] = 7
    doc["git"], doc["created"] = RC.git_rev(), time.strftime("%Y-%m-%dT%H:%M:%S%z")
    json.dump(doc, open(C.OUT / "points.json", "w"), ensure_ascii=False, indent=1, allow_nan=False)
    with open(C.OUT / "points.csv", "w", newline="") as f:
        w = csv.DictWriter(f, list(doc["rows"][0]))
        w.writeheader()
        w.writerows(doc["rows"])
    tb = tables(res)
    tf = C.OUT / "tables.md"
    old = tf.read_text() if tf.exists() else ""
    mark = "\n## chain_jh (SWD-17)"
    if mark in old:
        old = old[:old.index(mark)]
    tf.write_text(old.rstrip("\n") + "\n" + mark + "\n" + tb)
    (C.OUT / "chain_table.md").write_text("# chain_jh (SWD-17)\n" + tb)
    print("merged: rows", len(doc["rows"]), "rotor", len(doc["rotor"]), "timing", len(doc["timing"]))


def tables(res):
    L = ["", "### Ротор: state, S, режим против Menke 2019 и Пикара (разрезы Menke; L, м; present: u∥ < −0,5 м/с на 15 м)", "",
         "| случай | разрез | state | S | chain_jh present / L | Menke L | Пикар nom L | u_min/U на 10 м | с полем ротора вопреки state: present / L |",
         "|---|---|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        fo = {r["transect"]: r for r in res[c]["forced"]["rotor"]}
        for r in res[c]["rotor"]:
            f = fo[r["transect"]]
            S = "—" if r["S"] is None else f"{r['S']:.2f}"
            um = "—" if r["u_min_over_U"] is None else f"{r['u_min_over_U']:+.2f}"
            L.append(f"| {c} | {r['transect']} | {r['state']} | {S} | {'да' if r['present'] else 'нет'} / {r['L_m']:.0f} | "
                     f"{r['L_menke'] if r['L_menke'] is not None else '—'} | {r['L_picard'] if r['L_picard'] is not None else '—'} | {um} | "
                     f"{'да' if f['present'] else 'нет'} / {f['L_m']:.0f} |")
    L += ["", "### Поток в мачтах и время", "",
          "| случай | RMSE s мачты potential_jh | RMSE s мачты chain_jh | доля мачт в допуске (max 0,15; ref_err) jh / chain | "
          "доля nom ≥ 50 м в ±15 % jh / chain | N | t_run chain_jh, с | chain_rotor, с | решений | t запроса, мкс/точка |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        m, j, t, x = res[c]["metrics"], res[c]["metrics_jh"], res[c]["timing"], res[c]["extra"]
        L.append(f"| {c} | {j['rmse_s_mast']:.3f} | {m['rmse_s_mast']:.3f} | {j['frac_tol_ref_mast']:.2f} / {m['frac_tol_ref_mast']:.2f} | "
                 f"{j['frac_tol_picard_ge50']:.2f} / {m['frac_tol_picard_ge50']:.2f} | {t['N']} | {t['t_run_s']:.1f} | "
                 f"{x['t_chain_rotor_s']:.1f} | {x['n_solves']} | {t['t_query_us']:.0f} |")
    L += ["", "### Роторы, найденные chain3d", "", "| случай | № | длина, м | звеньев | S | Γ/q | state | u_min/U на 10 м |", "|---|---|---|---|---|---|---|---|"]
    for c in C.CASES:
        if not res[c]["rotors"]:
            L.append(f"| {c} | — | роторов нет (подветренный уклон ≤ 0,27) | | | | | |")
        for i, r in enumerate(res[c]["rotors"]):
            S = "—" if r["S"] is None else f"{r['S']:.2f}"
            gq = "—" if r["Gamma_over_q"] is None else f"{r['Gamma_over_q']:.1f}"
            um = "—" if r.get("u_min_over_U") is None else f"{r['u_min_over_U']:+.2f}"
            L.append(f"| {c} | {i} | {r['length_m']:.0f} | {r['n_links']} | {S} | {gq} | {r['state']} | {um} |")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "run":
        for c in (sys.argv[2:] or C.CASES):
            t0 = time.time()
            r = run_case(c)
            print(c, "done", f"{time.time() - t0:.0f} с", "роторов", r["extra"]["n_rotors"], "решений", r["extra"]["n_solves"], flush=True)
    elif cmd == "merge":
        merge()
