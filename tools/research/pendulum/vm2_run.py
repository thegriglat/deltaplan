#!/usr/bin/env python3
"""VM-2: нелинейная Cm(α) и добор «на себя» до «штанги у бёдер» на прототипе маятника, 48 крыльев до / после.

Варианты: base — прототип в конфигурации игры (блок pendulum крыла, PD-К2 v3), линейный тангаж, ход 0,45 м;
nl — добавка ΔCm(α) (Params.pitch_nl, pendulum/params.py: pitch_nl_dcm) + добор shift_x_pull_full.
Постановка — как pb2_run.py / export_reference.py (GameSim, рыскание свободно, шаг 1/120 с, эталонная масса, штиль).

Сценарии на крыло и вариант:
  trim     — трим (solve_trim), Kn на триме, фугоида (+3 м/с, 60 с), усилие на штанге 1,15 и 1,3·Vтрим (статика),
             скорость сваливания (полный «от себя» скачком, мин. V за 20 с)
  pull     — полный «на себя» обычный (ход 0,45 м): pitch −1 рампой 6 с, 70 с, среднее за 50–70 с
  pullfull — то же с добором (pull_full) + отпускание штанги с Vmax: ввод 0 скачком, 30 с

  $PY tools/research/pendulum/vm2_run.py geom                       → out/vm2/geom.json (параметры генератора по крылу)
  $PY tools/research/pendulum/vm2_run.py run [--jobs 12] [--only laminar/nl] → out/vm2/results.jsonl (продолжает)
  $PY tools/research/pendulum/vm2_run.py calib --sigmas 0.3,0.4,0.5 → out/vm2/calib.jsonl (только pullfull, для σ)
  $PY tools/research/pendulum/vm2_run.py report                     → out/vm2/summary.json (VM-К2 v2), tables.md, fig/
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import Control, R_from_euler  # noqa: E402
from pendulum.params import G  # noqa: E402
from pendulum.scenarios import run  # noqa: E402

ROOT = HERE.parents[2]
OUT = HERE / "out" / "vm2"
D, RAD = math.degrees, math.radians
CENS = ROOT / "tools/research/pullin_speed/out/passport_censoring.csv"
WINGS = sorted(p.stem for p in (ROOT / "configs/wings").glob("*.json"))

# Параметры VM-2 (обоснование — docs/research/pendulum/pitch-nonlinear.md, «Модель» и «Ход «на себя»»)
NL = {"pnl_sigma": 0.5, "pnl_width_deg": 1.0, "pnl_luff_per_deg": 0.02, "pnl_luff_on_deg": 0.0}
PULL_NORMAL = 0.45  # arms.shift_x_pull_m — не меняется (VM-К2 v2)
PULL_FULL = 0.95  # arms.shift_x_pull_full_m — «штанга у бёдер»
ARMS_FORCE_MAX = 300.0  # arms.force_max_n — не меняется
TUCK_DEG = -60.0


def _cfg_override():
    p = OUT / "params_override.json"
    if p.exists():
        NL.update(json.loads(p.read_text()).get("NL", {}))


_cfg_override()


def base_sim(wing: str, dt=1 / 120):
    blk = E.wing_cfg(wing)["pendulum"]
    p = E.params(wing).with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"], arm_force_max=ARMS_FORCE_MAX,
                             shift_x_pull=PULL_NORMAL)
    s = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    return s


def wing_cl(s, alpha):
    """CL крыла (полосы) при угле атаки киля alpha, поток вдоль x мира (как GameSim.wing_cl_max)."""
    R = R_from_euler(0.0, alpha, 0.0)
    F, _, _ = s.wing_aero(np.zeros(3), np.array([10.0, 0.0, 0.0]), R, np.zeros(3))
    if getattr(s, "_r0", None) is not None:
        s.r_strip_b = s._r0
    return float(-F[2] / (0.5 * s.p.rho * 100.0 * s.p.area))


def geom(wing: str) -> dict:
    """Что выводит генератор (tools/flight/pendulum_params.py) для добавки: Kn_t, α_t, dCL/dα, α нулевой подъёмной."""
    s = base_sim(wing)
    a, st = trim.solve_trim(s)
    kn = trim.static_margin(s, st["alpha"], st["V"])
    da = RAD(0.5)
    cla = (wing_cl(s, a + da) - wing_cl(s, a - da)) / (2 * da)
    lo, hi = a - RAD(25), a
    for _ in range(50):
        mid = 0.5 * (lo + hi)
        if wing_cl(s, mid) > 0:
            hi = mid
        else:
            lo = mid
    azl = 0.5 * (lo + hi)
    return {"wing": wing, "kn_trim": kn, "alpha_trim_deg": D(a), "cl_alpha": cla, "alpha_zl_deg": D(azl),
            "cl_trim": st["cl_total"], "trim_kmh": st["V"] * 3.6, "chord_mean_m": s.p.chord_mean, "area_m2": s.p.area,
            "bar_z_m": float(s.r_bar_b[2] - s.r_hang_b[2]), "hang_len_m": s.p.hang_len, "m_total": s.p.m_total,
            "dcm0": s.p.dcm0}


def load_geom():
    return {g["wing"]: g for g in json.loads((OUT / "geom.json").read_text())}


def make(wing: str, var: str, gm: dict | None = None, nl: dict | None = None, dt=1 / 120):
    s = base_sim(wing, dt)
    if var != "base":
        g = gm or load_geom()[wing]
        nl = dict(nl or NL)
        pf = nl.pop("pull_full", PULL_FULL)
        fm = nl.pop("force_max", ARMS_FORCE_MAX)
        on = nl.pop("pitch_nl", True)
        p = s.p.with_(pitch_nl=on, pnl_kn_trim=g["kn_trim"], pnl_alpha_trim=RAD(g["alpha_trim_deg"]),
                      pnl_cl_alpha=g["cl_alpha"], pnl_alpha_zl=RAD(g["alpha_zl_deg"]), pnl_cl_trim=g["cl_trim"], shift_x_pull_full=pf,
                      arm_force_max=fm, **nl)
        # добавка на триме = 0 по построению (r(0) = 0); dcm0 всё равно пересчитывается под паспортный трим
        # (как блок крыла: trim.solve_dcm0 на Sim), сдвиг от добавки прибавляется к dcm0 блока
        d_nl = trim.solve_dcm0(p, p.x_hang)
        d_b = trim.solve_dcm0(p.with_(pitch_nl=False), p.x_hang)
        p = p.with_(dcm0=p.dcm0 + (d_nl - d_b))
        cd = s.cd_scale
        s = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt))
        s.cd_scale = cd
    a, st = trim.solve_trim(s)
    if st is None:
        raise RuntimeError(f"{wing}/{var}: трим не найден")
    s.reset_air(st)
    s.trim_state = st
    return s


def phugoid(s, dv=3.0, T=60.0):
    s.vel = s.vel * (1 + dv / np.linalg.norm(s.vel))
    s.vn = s.vn + (s.vel - s.vn[-1])
    r = run(s, lambda t, o: Control(), T, every=1)
    t, V = r["t"], r["V"]
    Vm = float(np.median(V[-600:]))
    pk = [i for i in range(1, len(V) - 1) if V[i] > V[i - 1] and V[i] >= V[i + 1] and V[i] > Vm]
    per = float(np.median(np.diff(t[pk]))) if len(pk) >= 2 else float("nan")
    amps = [V[i] - Vm for i in pk]
    ratio = float(amps[1] / amps[0]) if len(amps) >= 2 and amps[0] > 1e-6 else float("nan")
    return {"phug_period_s": per, "phug_amp_ratio": ratio, "phug_peaks": len(pk), "phug_V_end_kmh": float(V[-1] * 3.6),
            "phug_unstable": bool(math.isfinite(ratio) and ratio > 1.0) or "blowup" in r}


def bar_force_static(s, v_target):
    """Усилие на штанге (Н, + — «на себя» тянет пилота вперёд) на установившемся планировании со скоростью v_target:
    момент аэродинамики около подвески (glide_balance) уравновешивают руки на плече штанги."""
    p = s.p
    a_t = s.trim_state["alpha"]
    lo, hi = a_t - RAD(14), a_t
    V_lo = trim.glide_balance(s, lo, v_target)[0]
    if V_lo < v_target:
        return float("nan")
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        V = trim.glide_balance(s, mid, v_target)[0]
        if V > v_target:
            lo = mid
        else:
            hi = mid
    V, gam, M, st = trim.glide_balance(s, 0.5 * (lo + hi), v_target)
    zb = float(s.r_bar_b[2] - s.r_hang_b[2])
    return float(M / zb)


def sc_trim(wing, var):
    s = make(wing, var)
    st = s.trim_state
    out = {"trim_kmh": st["V"] * 3.6, "alpha_trim_deg": D(st["alpha"]), "Kn": trim.static_margin(s, st["alpha"], st["V"]),
           "sink_ms": st["V"] * math.sin(st["gamma"]), "dcm0": s.p.dcm0}
    Vt = st["V"]
    out["bar_1p15_N"] = bar_force_static(s, 1.15 * Vt)
    out["bar_1p3_N"] = bar_force_static(s, 1.3 * Vt)
    out.update(phugoid(make(wing, var)))
    s = make(wing, var)
    r = run(s, lambda t, o: Control(pitch=1.0), 20.0, every=1)
    out["stall_min_kmh"] = float(r["V"].min() * 3.6)
    out["push_steady_kmh"] = float(r["V"][r["t"] > 12].mean() * 3.6)
    out["stall_frac_max"] = float(r["stall_frac"].max())
    return out


def _pull(s, full: bool):
    r = run(s, lambda t, o: Control(pitch=-min(t / 6.0, 1.0), pull_full=full), 70.0, every=6)
    if "blowup" in r:
        return r, {"blowup": True}
    m = r["t"] >= 50.0
    return r, {"V_kmh": float(r["V"][m].mean() * 3.6), "fx_N": float(r["fh_x"][m].mean()),
               "rel_x": float(r["rel_x"][m].mean()), "alpha_deg": float(D(r["alpha"][m].mean())),
               "theta_deg": float(D(r["theta"][m].mean())), "sink_ms": float(-r["vz"][m].mean()),
               "V_std_kmh": float(r["V"][m].std() * 3.6), "fx_max_N": float(np.abs(r["fh_x"]).max()),
               "blowup": False}


def sc_pull(wing, var):
    s = make(wing, var)
    _, o = _pull(s, False)
    return {f"pull_{k}": v for k, v in o.items()}


def _release_ctrl(mode):
    """Отпускание штанги: step — ввод 0 скачком (стик геймпада, постановка VM-К2); ramp1 — возврат клавиатуры
    1/с (configs/controls.json → keyboard.pitch_return_per_s); relaxed — руки отпущены (свободный маятник)."""
    if mode == "ramp1":
        return lambda t, o: Control(pitch=-max(1.0 - t, 0.0), pull_full=True)
    if mode == "relaxed":
        return lambda t, o: Control(arms_relaxed=True)
    return lambda t, o: Control()


def sc_pullfull(wing, var, nl=None):
    nl = dict(nl) if nl else None
    mode = nl.pop("release", "step") if nl else "step"
    s = make(wing, var, nl=nl)
    Vt = s.trim_state["V"]
    _, o = _pull(s, True)
    out = {f"full_{k}": v for k, v in o.items()}
    if o.get("blowup"):
        out["tuck"] = True
        return out
    r = run(s, _release_ctrl(mode), 30.0, every=1)
    blow = "blowup" in r
    th_min = float(D(r["theta"].min())) if len(r.get("theta", [])) else float("nan")
    a_min = float(D(r["alpha"].min())) if len(r.get("alpha", [])) else float("nan")
    tail = r["t"] >= 25.0 if not blow else np.zeros(1, bool)
    v_end = float(r["V"][tail].mean()) if tail.any() else float("nan")
    returned = bool(not blow and math.isfinite(v_end) and abs(v_end - Vt) <= 0.10 * Vt)
    out.update({"rel_theta_min_deg": th_min, "rel_alpha_min_deg": a_min, "rel_V_end_kmh": v_end * 3.6,
                "rel_V_max_kmh": float(r["V"].max() * 3.6), "rel_returned": returned,
                "rel_alpha_max_deg": float(D(r["alpha"].max())),
                "tuck": bool(blow or th_min < TUCK_DEG or not returned)})
    return out


def sc_stall(wing, var):
    """Скорость срыва: «от себя» плавно 0 → +1 за 15 с и 10 с удержания; V в момент, когда срыв (доля полос
    за критическим углом, stall_frac) впервые ≥ 0,3; плюс мин. V (сглаженная 1 с) — до первой точки срыва."""
    s = make(wing, var)
    r = run(s, lambda t, o: Control(pitch=min(t / 15.0, 1.0)), 25.0, every=1)
    t, V, sf = r["t"], r["V"], r["stall_frac"]
    k = np.argmax(sf >= 0.3) if (sf >= 0.3).any() else None
    Vs = np.convolve(V, np.ones(120) / 120, mode="same")
    return {"stall_onset_kmh": float(V[k] * 3.6) if k is not None else float("nan"),
            "stall_onset_t_s": float(t[k]) if k is not None else float("nan"),
            "stall_onset_alpha_deg": float(D(r["alpha"][k])) if k is not None else float("nan"),
            "stall_vmin_smooth_kmh": float(Vs[60:-60].min() * 3.6)}


SCEN = {"trim": sc_trim, "pull": sc_pull, "pullfull": sc_pullfull, "stall": sc_stall}


def job(a):
    wing, var, sc = a[:3]
    t0 = time.time()
    try:
        if sc == "calib":
            nl = a[3]
            r = sc_pullfull(wing, "nl", nl=nl)
            r["nl"] = nl
            key = f"{wing}/{json.dumps(nl, sort_keys=True)}"
        else:
            r = SCEN[sc](wing, var)
            key = f"{wing}/{var}/{sc}"
        err = None
    except Exception:
        r, err = {}, traceback.format_exc()
        key = f"{wing}/{var}/{sc}" if sc != "calib" else f"{wing}/{json.dumps(a[3], sort_keys=True)}"
    return {"key": key, "wing": wing, "var": var, "sc": sc, "err": err, "sec": round(time.time() - t0, 1), **r}


def _pool(jobs, out, n):
    with ProcessPoolExecutor(n) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in jobs]
        for i, fu in enumerate(as_completed(futs)):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
            f.flush()
            if r["err"] or i % 10 == 0:
                print(i, r["key"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
                if r["err"]:
                    print(r["err"].splitlines()[-1], flush=True)


def _done(path):
    done = set()
    if path.exists():
        for ln in path.read_text().splitlines():
            if ln.strip():
                r = json.loads(ln)
                if not r.get("err"):
                    done.add(r["key"])
    return done


def cmd_geom(args):
    OUT.mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(geom, WINGS))
    tmp = OUT / "geom.json.tmp"
    tmp.write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    tmp.replace(OUT / "geom.json")
    print("крыльев", len(rows))


def cmd_run(args):
    out = OUT / "results.jsonl"
    done = _done(out)
    jobs = [(w, v, sc) for w in WINGS for v in ("base", "nl") for sc in SCEN]
    jobs = [j for j in jobs if f"{j[0]}/{j[1]}/{j[2]}" not in done and (not args.only or args.only in f"{j[0]}/{j[1]}/{j[2]}")]
    jobs.sort(key=lambda j: {"pullfull": 0, "trim": 1, "pull": 2, "stall": 3}[j[2]])
    print(f"план: {len(jobs)} (сделано {len(done)})", flush=True)
    _pool(jobs, out, args.jobs)


def cmd_calib(args):
    out = OUT / "calib.jsonl"
    done = _done(out)
    jobs = []
    variants = json.loads(args.variants) if args.variants else [dict(NL, pnl_sigma=float(x)) for x in args.sigmas.split(",")]
    wings = args.wings.split(",") if args.wings else WINGS
    for v in variants:
        nl = dict(NL, **v)
        for w in wings:
            if f"{w}/{json.dumps(nl, sort_keys=True)}" not in done:
                jobs.append((w, "nl", "calib", nl))
    print(f"план: {len(jobs)}", flush=True)
    _pool(jobs, out, args.jobs)


# ----------------------------------------------------------------------------- сводка
def passport():
    """{крыло: (Vmax паспорт VG 0, цензура Vne)}."""
    out = {}
    with CENS.open() as f:
        for r in csv.DictReader(f):
            out[r["wing"]] = (float(r["vmax"]), r["at_vne"].strip() == "True")
    return out


def _ratios(vm, pp):
    return [vm[w] / pp[w][0] for w in vm if w in pp and not pp[w][1] and vm[w] and math.isfinite(vm[w])]


def cmd_calib_report(args):
    pp = passport()
    rows = [json.loads(l) for l in (OUT / "calib.jsonl").read_text().splitlines() if l.strip()]
    by = {}
    for r in rows:
        if r.get("err"):
            continue
        by.setdefault(json.dumps(r["nl"], sort_keys=True), {})[r["wing"]] = r
    res = []
    for k, d in sorted(by.items()):
        vm = {w: r.get("full_V_kmh") for w, r in d.items()}
        q = _ratios(vm, pp)
        res.append({"nl": json.loads(k), "n": len(d), "median": float(np.median(q)) if q else None,
                    "p10": float(np.percentile(q, 10)) if q else None, "tuck": sum(1 for r in d.values() if r.get("tuck")),
                    "fx_max": max((r.get("full_fx_N") or 0) for r in d.values())})
        print(json.dumps(res[-1], ensure_ascii=False))
    (OUT / "calib_summary.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


def collect():
    rows = [json.loads(l) for l in (OUT / "results.jsonl").read_text().splitlines() if l.strip()]
    acc, errs = {}, []
    for r in rows:
        if r.get("err"):
            errs.append(r["key"])
            continue
        acc.setdefault(r["wing"], {}).setdefault(r["var"], {}).update(
            {k: v for k, v in r.items() if k not in ("key", "wing", "var", "sc", "err", "sec")})
    errs = [e for e in errs if e.split("/")[0] not in acc or e.split("/")[1] not in acc[e.split("/")[0]]]
    return acc, errs


def _num(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) else None


def cmd_report(args):
    acc, errs = collect()
    pp = passport()
    gm = load_geom()
    wings = [w for w in WINGS if w in acc and "base" in acc[w] and "nl" in acc[w]]
    ref_trim = {w: E.wing_cfg(w)["trim_speed_kmh"] for w in wings}
    B = {w: acc[w]["base"] for w in wings}
    N = {w: acc[w]["nl"] for w in wings}
    vm_full = {w: N[w].get("full_V_kmh") for w in wings}
    vm_norm = {w: N[w].get("pull_V_kmh") for w in wings}
    vm_base = {w: B[w].get("pull_V_kmh") for w in wings}
    q, qn, qb = _ratios(vm_full, pp), _ratios(vm_norm, pp), _ratios(vm_base, pp)
    game = {}
    try:
        with (ROOT / "tools/research/pullin_speed/out/wings_table.csv").open() as f:
            for r in csv.DictReader(f):
                game[r["wing"]] = float(r["vmax_model"])
    except OSError:
        pass
    proto_vs_game = [vm_base[w] / game[w] for w in wings if w in game and vm_base.get(w)]
    stall_dev = [abs(N[w]["stall_onset_kmh"] - B[w]["stall_onset_kmh"]) for w in wings]
    summary = {
        "contract": "VM-К2 v2", "task": "VM-2",
        "wings": len(wings),
        "vmax_ratio_median": float(np.median(q)), "vmax_ratio_p10": float(np.percentile(q, 10)),
        "vmax_ratio_median_base": float(np.median(qb)), "vmax_ratio_median_normal": float(np.median(qn)),
        "vmax_ratio_n": len(q),
        "trim_dev_max_kmh": float(max(abs(N[w]["trim_kmh"] - ref_trim[w]) for w in wings)),
        "kn_trim_min": float(min(N[w]["Kn"] for w in wings)),
        "phugoid_unstable_count": int(sum(bool(N[w]["phug_unstable"]) for w in wings)),
        "phugoid_unstable_count_base": int(sum(bool(B[w]["phug_unstable"]) for w in wings)),
        "bar_force_vmax_max_n": float(max(abs(N[w]["full_fx_N"]) for w in wings)),
        "arms_force_max_n": ARMS_FORCE_MAX, "pull_full_m": PULL_FULL, "pull_normal_m": PULL_NORMAL,
        "stall_dev_max_kmh": float(max(stall_dev)),
        "tuck_count": int(sum(bool(N[w].get("tuck")) for w in wings)),
        "tuck_count_base": int(sum(bool(B[w].get("tuck")) for w in wings)),
        "vmax_full_mean_kmh": float(np.mean([vm_full[w] for w in wings])),
        "vmax_normal_mean_kmh": float(np.mean([vm_norm[w] for w in wings])),
        "vmax_base_mean_kmh": float(np.mean([vm_base[w] for w in wings])),
        "vmax_base_proto_vs_game_median": float(np.median(proto_vs_game)) if proto_vs_game else None,
        "vmax_base_mean_game_kmh": float(np.mean([game[w] for w in wings if w in game])) if game else None,
        "params": {"NL": NL, "pull_normal_m": PULL_NORMAL, "pull_full_m": PULL_FULL, "arms_force_max_n": ARMS_FORCE_MAX},
        "errors": errs,
        "wing_rows": {w: {"base": B[w], "nl": N[w], "geom": gm.get(w), "passport_vmax_kmh": pp.get(w, (None,))[0],
                          "passport_censored": pp.get(w, (None, None))[1], "game_vmax_kmh": game.get(w)} for w in wings},
    }
    for k in ("vmax_ratio_median", "vmax_ratio_p10", "vmax_ratio_median_base", "vmax_ratio_median_normal"):
        summary[k] = round(summary[k], 4)
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    tmp.replace(OUT / "summary.json")
    write_tables(summary)
    try:
        write_figs(summary)
    except Exception as e:  # графики не входят в приёмку
        print("графики:", e)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("wing_rows", "params")}, ensure_ascii=False, indent=1))


def _f(x, fmt="{:.1f}"):
    x = _num(x) if not isinstance(x, bool) else x
    return "—" if x is None else (("да" if x else "нет") if isinstance(x, bool) else fmt.format(x))


def write_tables(s):
    L = ["# VM-2: нелинейный тангаж и добор «на себя» — таблицы (48 крыльев, до → после)\n",
         f"Параметры: {json.dumps(s['params'], ensure_ascii=False)}\n",
         "Обозначения: «до» — прежняя модель (ход 0,45 м); «после» — с ΔCm(α); Vmax обычный — ход 0,45 м, с добором — "
         f"{s['pull_full_m']} м; усилие на штанге: + — пилот тянет себя вперёд («на себя»); 1,15 / 1,3·Vтрим — статика "
         "(момент около подвески / плечо штанги); срыв — V в начале срыва (доля сорванных полос ≥ 0,3) при «от себя» 0 → +1 за 15 с; отпускание — с Vmax "
         "с добором, ввод 0 скачком, 30 с. Цензура — паспорт усечён Vne (в медиану не входит).\n"]
    L.append("| крыло | трим до/после | паспорт VG 0 | Vmax до | Vmax обычный | Vmax с добором | отн. | Kn до/после | "
             "фугоида T, с до/после | затух. до/после | штанга 1,15 / 1,3·Vт до | после | штанга Vmax до/после | "
             "срыв до/после | отпуск.: мин. θ, мин. α, V через 30 с |")
    L.append("|" + "---|" * 15)
    for w, r in s["wing_rows"].items():
        b, n = r["base"], r["nl"]
        pv = r["passport_vmax_kmh"]
        rat = (n.get("full_V_kmh") or float("nan")) / pv if pv else float("nan")
        L.append(f"| {w} | {_f(b['trim_kmh'])}/{_f(n['trim_kmh'])} | {_f(pv, '{:.0f}')}{' ц' if r['passport_censored'] else ''} | "
                 f"{_f(b.get('pull_V_kmh'))} | {_f(n.get('pull_V_kmh'))} | {_f(n.get('full_V_kmh'))} | {_f(rat, '{:.2f}')} | "
                 f"{_f(b['Kn'], '{:.3f}')}/{_f(n['Kn'], '{:.3f}')} | {_f(b['phug_period_s'])}/{_f(n['phug_period_s'])} | "
                 f"{_f(b['phug_amp_ratio'], '{:.2f}')}/{_f(n['phug_amp_ratio'], '{:.2f}')} | "
                 f"{_f(b['bar_1p15_N'], '{:.0f}')} / {_f(b['bar_1p3_N'], '{:.0f}')} | {_f(n['bar_1p15_N'], '{:.0f}')} / {_f(n['bar_1p3_N'], '{:.0f}')} | "
                 f"{_f(b.get('pull_fx_N'), '{:.0f}')}/{_f(n.get('full_fx_N'), '{:.0f}')} | {_f(b['stall_onset_kmh'])}/{_f(n['stall_onset_kmh'])} | "
                 f"{_f(n.get('rel_theta_min_deg'))}°, {_f(n.get('rel_alpha_min_deg'))}°, {_f(n.get('rel_V_end_kmh'))} |")
    L.append("\n## По классам (медианы)\n")
    L.append("| класс | n | Vmax до | обычный | с добором | паспорт | отн. с добором (без цензуры) |")
    L.append("|---|---|---|---|---|---|---|")
    cls = {}
    for w, r in s["wing_rows"].items():
        g = E.wing_cfg(w).get("group", "?")
        cls.setdefault(g, []).append(r)
    for g, rs in sorted(cls.items()):
        def med(f):
            v = [x for x in (f(r) for r in rs) if x is not None and math.isfinite(x)]
            return float(np.median(v)) if v else None
        L.append(f"| {g} | {len(rs)} | {_f(med(lambda r: r['base'].get('pull_V_kmh')))} | {_f(med(lambda r: r['nl'].get('pull_V_kmh')))} | "
                 f"{_f(med(lambda r: r['nl'].get('full_V_kmh')))} | {_f(med(lambda r: r['passport_vmax_kmh']))} | "
                 f"{_f(med(lambda r: None if r['passport_censored'] or not r['passport_vmax_kmh'] else r['nl'].get('full_V_kmh') / r['passport_vmax_kmh']), '{:.2f}')} |")
    L.append("\n## Параметры генератора по крылу (out/vm2/geom.json)\n")
    L.append("| крыло | Kn_t | α_t, ° | dCL/dα, 1/рад | α_zl, ° | CL_t |")
    L.append("|---|---|---|---|---|---|")
    for w, r in s["wing_rows"].items():
        g = r["geom"]
        L.append(f"| {w} | {g['kn_trim']:.4f} | {g['alpha_trim_deg']:.2f} | {g['cl_alpha']:.3f} | {g['alpha_zl_deg']:.2f} | {g['cl_trim']:.3f} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n", encoding="utf-8")


def write_figs(s):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from pendulum.params import Params  # noqa: F401
    fd = OUT / "fig"
    fd.mkdir(exist_ok=True)
    rows = s["wing_rows"]
    ws = list(rows)
    x = np.arange(len(ws))
    fig, ax = plt.subplots(figsize=(13, 4))
    ax.bar(x - 0.27, [rows[w]["base"].get("pull_V_kmh") or 0 for w in ws], 0.27, label="до (0,45 м)", color="#9aa7b8")
    ax.bar(x, [rows[w]["nl"].get("pull_V_kmh") or 0 for w in ws], 0.27, label="ΔCm(α), ход 0,45 м", color="#4C72B0")
    ax.bar(x + 0.27, [rows[w]["nl"].get("full_V_kmh") or 0 for w in ws], 0.27, label=f"ΔCm(α), добор {s['pull_full_m']} м", color="#C44E52")
    ax.plot(x, [rows[w]["passport_vmax_kmh"] or np.nan for w in ws], "k_", ms=10, mew=2, label="паспорт VG 0")
    ax.set_xticks(x, ws, rotation=75, fontsize=7)
    ax.set_ylabel("Vmax «на себя», км/ч")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(fd / "vmax_48.png", dpi=130)
    plt.close(fig)
    # кривая Cm(α) около подвески для трёх крыльев: до и после (статика glide_balance)
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.4))
    for ax, w in zip(axes, ["training", "laminar", "sport"]):
        for var, col in (("base", "#9aa7b8"), ("nl", "#C44E52")):
            sm = make(w, var)
            Vt = sm.trim_state["V"]
            al = np.radians(np.linspace(-6, 16, 45))
            cm = []
            for a in al:
                R = R_from_euler(0.0, a, 0.0)
                vel = np.array([Vt, 0.0, 0.0])
                Fa, Ma, _ = sm.wing_aero(np.zeros(3), vel, R, np.zeros(3))
                rH = R @ sm.r_hang_b
                M = R.T @ (Ma + np.cross(-rH, Fa))
                cm.append(M[1] / (0.5 * sm.p.rho * Vt * Vt * sm.p.area * sm.p.chord_mean))
            ax.plot(np.degrees(al), cm, color=col, label=var)
        ax.axhline(0, color="#666", lw=0.6)
        ax.set_title(w)
        ax.set_xlabel("α киля, °")
        ax.grid(alpha=0.3)
    axes[0].set_ylabel("Cm крыла около подвески")
    axes[0].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(fd / "cm_alpha.png", dpi=130)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("geom"); a.add_argument("--jobs", type=int, default=12)
    a = sp.add_parser("run"); a.add_argument("--jobs", type=int, default=12); a.add_argument("--only", default="")
    a = sp.add_parser("calib"); a.add_argument("--jobs", type=int, default=12); a.add_argument("--sigmas", default="0.35"); a.add_argument("--variants", default=""); a.add_argument("--wings", default="")
    sp.add_parser("calib-report")
    sp.add_parser("report")
    args = ap.parse_args()
    {"geom": cmd_geom, "run": cmd_run, "calib": cmd_calib, "calib-report": cmd_calib_report, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
