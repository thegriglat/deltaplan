#!/usr/bin/env python3
"""PB-2: опыты с VG (pendulum/vg.py) на прототипе маятника — одна пачка, сводка PB-К2.

Варианты: base (VG 0, как в игре), vg0 (= base), vg05, vg1. Крылья: training, laminar, sport (обязательные)
+ безмачтовые/мачтовые с паспортным Vmax VG 100 % (EXTRA_WINGS). Сценарии (постановка — как pd21_lateral.py /
export_reference.py, импортом, без правок): трим и поляра по положениям трапеции (−1, −½, 0, +½, +1), производные
(trim.lateral_derivatives), голландский шаг (Прони), ровный вираж 30°, перекладка 45→45 и 30→30, опыт Ochi,
болтанка σ 1 м/с (11 полей × шаги 1/120, 1/60, 1/30 = 33 прогона на крыло, только training/laminar/sport).

  $PY tools/research/pendulum/pb2_run.py run [--jobs 12] [--only laminar/vg1]   → out/pb2/results.jsonl (продолжает с места)
  $PY tools/research/pendulum/pb2_run.py report                                → out/pb2/summary.json (PB-К2), tables.md, fig/
"""
from __future__ import annotations

import argparse
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
import pd21_lateral as PD21  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run, settle  # noqa: E402
from pendulum.vg import apply_vg, has_vg  # noqa: E402

OUT = HERE / "out" / "pb2"
D, RAD = math.degrees, math.radians
MAIN_WINGS = ["training", "laminar", "sport"]
EXTRA_WINGS = ["aeros_combat_c", "moyes_gecko", "moyes_litespeed_rx", "ww_t2c"]
VARIANTS = {"base": 0.0, "vg05": 0.5, "vg1": 1.0}  # vg0 = base (копия в сводке)
PITCH_U = (-1.0, -0.5, 0.0, 0.5, 1.0)
TURB_DTS = (1 / 120, 1 / 60, 1 / 30)
CAPSIZE_DEG = 60.0


def make(wing: str, vg: float, m_pilot=None, dt=1 / 120):
    blk = E.wing_cfg(wing)["pendulum"]
    p = E.params(wing, m_pilot).with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    p = apply_vg(p, vg)
    s = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt))
    s.cd_scale = blk["cd_scale"] * p.extra.get("vg_cd_factor", 1.0)
    a, st = trim.solve_trim(s)
    if st is None:
        raise RuntimeError(f"{wing} vg={vg}: трим не найден")
    s.reset_air(st)
    s.trim_state = st
    return s


def turb_fields():
    ref = json.loads((HERE.parents[2] / "tests/flight/pendulum/reference.json").read_text())["turbulence"]
    p8 = json.loads((HERE / "out/pd8_plan.json").read_text())["turbulence"]
    f = {"ref": ref}
    f.update({k: p8[k] for k in list(p8)[:10]})
    return f


# ----------------------------------------------------------------------------- сценарии
def sc_trim_polar(wing, vg):
    s = make(wing, vg)
    st = s.trim_state
    p = s.p
    out = {"trim_kmh": st["V"] * 3.6, "sink_ms": st["V"] * math.sin(st["gamma"]), "alpha_trim_deg": D(st["alpha"]),
           "ld_trim": 1 / math.tan(st["gamma"]), "Kn": trim.static_margin(s, st["alpha"], st["V"]),
           "washout_deg": D(p.washout), "sweep_deg": D(p.sweep), "span_m": p.span, "sail_flex": p.sail_flex,
           "cd_scale": s.cd_scale, "dcm0": p.dcm0, "cl_trim": st["cl_total"], "polar": []}
    for u in PITCH_U:
        s = make(wing, vg)
        r = run(s, lambda t, o: Control(pitch=u), 25.0)
        m = r["t"] > 15
        blow = "blowup" in r
        pt = {"u": u, "V_kmh": float(r["V"][m].mean() * 3.6) if m.any() else float("nan"),
              "sink_ms": float(-r["vz"][m].mean()) if m.any() else float("nan"),
              "fx_N": float(r["fh_x"][m].mean()) if m.any() else float("nan"),
              "rel_x": float(r["rel_x"][m].mean()) if m.any() else float("nan"),
              "V_std_kmh": float(r["V"][m].std() * 3.6) if m.any() else float("nan"),
              "alpha_deg": float(D(r["alpha"][m].mean())) if m.any() else float("nan"),
              "stall_max": float(r["stall_frac"][m].max()) if m.any() else float("nan"), "blowup": blow}
        pt["ld"] = pt["V_kmh"] / 3.6 / pt["sink_ms"] if pt["sink_ms"] and math.isfinite(pt["sink_ms"]) else float("nan")
        out["polar"].append(pt)
        if u == -1.0:
            out["full_pull_kmh"] = pt["V_kmh"]
            out["full_pull_fx_N"] = pt["fx_N"]
            out["full_pull_rel_x"] = pt["rel_x"]
            out["full_pull_sink_ms"] = pt["sink_ms"]
    return out


def sc_derivs(wing, vg):
    s = make(wing, vg)
    d = trim.lateral_derivatives(s, s.trim_state)
    return {"clp": d["Cl_p"], "cnp": d["Cn_p"], "cn_beta": d["Cn_beta"], "cl_beta": d["Cl_beta"], "cy_beta": d["CY_beta"],
            "cnr": d["Cn_r"], "clr": d["Cl_r"], "spiral_E": d["spiral_E"], "Ixx": float(s.I_b[0, 0]), "Izz": float(s.I_b[2, 2])}


def sc_dutch(wing, vg):
    s = make(wing, vg)
    settle(s, 3.0)
    s.w = s.w + s.R @ np.array([0.0, 0.0, 0.15])
    r = run(s, lambda t, o: Control(), 16.0, every=12)
    t, b = r["t"], r["beta"]
    m = t >= 0.3
    poles = PD21.prony(t[m], b[m] - np.median(b[-30:]))
    if not poles:
        return {"dutch_omega_rad_s": float("nan"), "dutch_zeta": float("nan")}
    sg, w, _ = poles[0]
    wn = math.hypot(sg, w)
    return {"dutch_omega_rad_s": wn, "dutch_zeta": -sg / wn, "dutch_beta_max_deg": float(D(np.abs(b).max()))}


def sc_turn30(wing, vg, bank=30.0):
    s = make(wing, vg)
    bh = BankHold(RAD(bank), kp=1.5, kd=0.8, ki=0.3)
    r = run(s, bh, 45.0, every=4)
    m = r["t"] > 40.0
    V, beta, rr = r["V"][m].mean(), r["beta"][m].mean(), r["r"][m].mean()
    return {"turn30_phi_deg": float(D(r["phi"][m].mean())), "turn30_beta_cg_deg": float(D(beta)),
            "turn30_ribbon_deg": float(D(beta + math.atan(rr * PD21.X_NODE / V))), "turn30_V_kmh": float(V * 3.6),
            "turn30_hold_N": float(r["fh_y"][m].mean()), "turn30_u": float(r["u_roll"][m].mean())}


def sc_reversal(wing, vg, bank):
    s = make(wing, vg)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    run(s, bh, 14.0)
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=1)
    t = r["t"]
    tm = first_cross(t, r["phi"], RAD(-bank))
    m = t <= (tm if math.isfinite(tm) else t[-1])
    k = int(bank)
    return {f"reversal_{k}_s": tm, f"reversal_{k}_t0_s": first_cross(t, r["phi"], 0.0),
            f"reversal_{k}_phi_start_deg": float(D(r["phi"][0])),
            f"reversal_{k}_beta_max_deg": float(D(np.abs(r["beta"][m]).max())),
            f"reversal_{k}_fy_peak_N": float(np.abs(r["fh_y"]).max())}


def sc_ochi(wing, vg, force=30.0, t_on=8.5, m_pilot=72.6):
    s = make(wing, vg, m_pilot=m_pilot)
    settle(s, 2.0)
    r = run(s, lambda t, o: Control(force_y=force if t < t_on else None), 12.0, every=1)
    return {"ochi_bank_7s_deg": float(D(np.interp(7.0, r["t"], r["phi"]))), "ochi_bank_max_deg": float(D(r["phi"].max()))}


def sc_turb(wing, vg, field, modes, dt, T=40.0):
    s = make(wing, vg, dt=dt)
    s.air_fn = E.turbulence_fn(modes)
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    n = int(round(T / dt))
    phi, V = [], []
    o = s.observe()
    blow = False
    for _ in range(n):
        s.step(hold(0.0, o))
        o = s.observe()
        if not np.isfinite(o["phi"]) or o["V"] > 80:
            blow = True
            break
        if o["t"] > 10.0:
            phi.append(o["phi"]); V.append(o["V"])
    mx = float(D(np.max(np.abs(phi)))) if phi else float("nan")
    return {"field": field, "dt": dt, "blowup": blow, "max_abs_phi_deg": mx, "std_phi_deg": float(D(np.std(phi))) if phi else float("nan"),
            "V_mean_kmh": float(np.mean(V) * 3.6) if V else float("nan"), "capsize": bool(blow or mx >= CAPSIZE_DEG),
            "max_stretch_m": float(s.max_stretch)}


SCENARIOS = {"trim": sc_trim_polar, "derivs": sc_derivs, "dutch": sc_dutch, "turn30": sc_turn30,
             "rev45": lambda w, v: sc_reversal(w, v, 45.0), "rev30": lambda w, v: sc_reversal(w, v, 30.0), "ochi": sc_ochi}


def job(a):
    wing, var, sc, extra = a
    vg = VARIANTS[var]
    t0 = time.time()
    try:
        if sc == "turb":
            r, err = sc_turb(wing, vg, extra["field"], extra["modes"], extra["dt"]), None
        else:
            r, err = SCENARIOS[sc](wing, vg), None
    except Exception:
        r, err = {}, traceback.format_exc()
    key = f"{wing}/{var}/{sc}" + (f"/{extra['field']}/{round(1 / extra['dt'])}" if sc == "turb" else "")
    return {"key": key, "wing": wing, "var": var, "sc": sc, "vg": vg, "err": err, "sec": round(time.time() - t0, 1), **r}


def plan(only: str = ""):
    fields = turb_fields()
    jobs = []
    for wing in MAIN_WINGS + EXTRA_WINGS:
        for var in VARIANTS:
            if var != "base" and not has_vg(wing):
                continue  # без VG: vg05/vg1 = base (копия в сводке)
            for sc in SCENARIOS:
                jobs.append((wing, var, sc, {}))
            if wing in MAIN_WINGS:
                for f, modes in fields.items():
                    for dt in TURB_DTS:
                        jobs.append((wing, var, "turb", {"field": f, "modes": modes, "dt": dt}))
    if only:
        jobs = [j for j in jobs if only in f"{j[0]}/{j[1]}/{j[2]}"]
    return jobs


def cmd_run(args):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "results.jsonl"
    done = set()
    if out.exists():
        for ln in out.read_text().splitlines():
            if ln.strip():
                done.add(json.loads(ln)["key"])
    jobs = plan(args.only)
    jobs = [j for j in jobs if (f"{j[0]}/{j[1]}/{j[2]}" + (f"/{j[3]['field']}/{round(1 / j[3]['dt'])}" if j[2] == "turb" else "")) not in done]
    # долгие (болтанка 1/120, вираж) — первыми
    jobs.sort(key=lambda j: 0 if j[2] in ("turb", "turn30") else 1)
    print(f"план: {len(jobs)} запусков (сделано {len(done)})", flush=True)
    with ProcessPoolExecutor(args.jobs) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in jobs]
        for i, fu in enumerate(as_completed(futs)):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
            f.flush()
            if r["err"] or i % 20 == 0:
                print(i, r["key"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
                if r["err"]:
                    print(r["err"].splitlines()[-1], flush=True)


# ----------------------------------------------------------------------------- сводка
METRICS = ("clp", "cnp", "cn_beta", "cl_beta", "cy_beta", "cnr", "clr", "dutch_omega_rad_s", "dutch_zeta",
           "reversal_45_s", "reversal_30_s", "reversal_beta_max_deg", "turn30_beta_cg_deg", "turn30_ribbon_deg",
           "ochi_bank_7s_deg", "turb_capsize_n", "turb_runs_n", "trim_kmh", "sink_ms", "full_pull_kmh")
EXTRA_KEYS = ("full_pull_fx_N", "full_pull_rel_x", "full_pull_sink_ms", "Kn", "alpha_trim_deg", "ld_trim", "washout_deg",
              "sweep_deg", "span_m", "sail_flex", "cd_scale", "dcm0", "dutch_beta_max_deg", "reversal_45_t0_s",
              "reversal_30_t0_s", "reversal_30_beta_max_deg", "reversal_45_fy_peak_N", "turn30_V_kmh", "turn30_hold_N",
              "ochi_bank_max_deg", "spiral_E", "turb_blowup_n", "turb_max_abs_phi_deg", "polar", "turb")


def _num(x):
    return x if isinstance(x, (int, float)) and math.isfinite(x) else None


def collect(rows):
    """rows → {wing: {var: {метрики}}}."""
    acc = {}
    for r in rows:
        if r.get("err"):
            continue
        w = acc.setdefault(r["wing"], {}).setdefault(r["var"], {"turb": []})
        if r["sc"] == "turb":
            w["turb"].append({k: r[k] for k in ("field", "dt", "blowup", "max_abs_phi_deg", "std_phi_deg", "V_mean_kmh", "capsize")})
        else:
            w.update({k: v for k, v in r.items() if k not in ("key", "wing", "var", "sc", "vg", "err", "sec")})
    for w, vs in acc.items():
        for v, m in vs.items():
            if m["turb"]:
                m["turb_runs_n"] = len(m["turb"])
                m["turb_capsize_n"] = sum(1 for t in m["turb"] if t["capsize"])
                m["turb_blowup_n"] = sum(1 for t in m["turb"] if t["blowup"])
                m["turb_max_abs_phi_deg"] = max(t["max_abs_phi_deg"] for t in m["turb"] if math.isfinite(t["max_abs_phi_deg"]))
            if "reversal_45_beta_max_deg" in m:
                m["reversal_beta_max_deg"] = m["reversal_45_beta_max_deg"]
    return acc


def cmd_report(args):
    rows = [json.loads(ln) for ln in (OUT / "results.jsonl").read_text().splitlines() if ln.strip()]
    acc = collect(rows)
    passport = json.loads((OUT / "passport.json").read_text(encoding="utf-8"))
    errs = [r["key"] for r in rows if r.get("err")]
    wings_all = [w for w in MAIN_WINGS + EXTRA_WINGS if w in acc]
    notes = {}
    variants = {}
    desc = {"base": "прототип в конфигурации игры (PD-К2 v3 блоки крыльев), VG 0", "vg0": "= base (VG отпущен)",
            "vg05": "VG ½ хода (pendulum/vg.py: крутка −6°·⅔ = −4°, гибкость паруса ×0,65, сопротивление полос ×0,94; нос не меняется)",
            "vg1": "VG затянут (крутка −6°, не ниже 2°; гибкость ×0,3; сопротивление ×0,88; нос не меняется)"}
    for var in ("base", "vg0", "vg05", "vg1"):
        src = "base" if var == "vg0" else var
        wings = {}
        for w in wings_all:
            m = acc[w].get(src)
            if m is None and not has_vg(w):
                m = acc[w].get("base")
                notes[f"{var}/{w}"] = "крыло без VG: значения = base"
            if m is None:
                m = {}
                notes[f"{var}/{w}"] = "не считалось"
            row = {k: _num(m.get(k)) for k in METRICS}
            for k in EXTRA_KEYS:
                if k in m:
                    row[k] = m[k]
            if w not in MAIN_WINGS and row["turb_runs_n"] is None:
                notes.setdefault("turb_capsize_n", "болтанка считалась только для training/laminar/sport (11 полей × 3 шага = 33 прогона на крыло)")
                notes.setdefault("turb_runs_n", notes["turb_capsize_n"])
            wings[w] = row
        variants[var] = {"desc": desc[var], "wings": wings}
    pp = {}
    for w in wings_all:
        r = passport.get(w, {})
        pp[w] = {"vmax_vg0_kmh": r.get("vmax_vg0_kmh"), "vmax_vg100_kmh": r.get("vmax_vg100_kmh"),
                 "vmax_vg100_censored": r.get("vmax_vg100_censored"), "game_full_pull_kmh": r.get("game_full_pull_kmh"),
                 "has_vg": r.get("has_vg"), "source": r.get("source") or r.get("has_vg_source") or "паспорта нет (обобщённое крыло класса)"}
        if r.get("vmax_vg100_censored"):
            pp[w]["note"] = "DHV разгоняет не выше 90 км/ч: «>90» — нижняя граница"
    summary = {
        "contract": "PB-К2 v1", "task": "PB-2",
        "variants": variants,
        "notes": notes,
        "passport": pp,
        "errors": errs,
        "sources": [
            {"what": "T2C: VG — угол носа 127–132°, трим 34 → 40–47 км/ч к ¾ хода, min усилие на Vmax при VG 100 % 0,5–1 кг/рука, Vmax 85–120 км/ч при полном «на себя» (штанга у бёдер), за ½ хода крен тяжелее",
             "ref": "Wills Wing, Betriebsanweisung T2 / T2C 136–154 (DHV, 2008/2012)", "url": "https://service.dhv.de/dbfiles/tmo/betriebsanweisungen/B_01-0472-13.pdf"},
            {"what": "Litespeed: угол носа 130–132°, к ½ хода «большая часть крутки снята», full tight «quite difficult to control», max качество не меняется от ¾ к 1, 9–10 на 80 км/ч, 15 на 47 км/ч",
             "ref": "Moyes, Litespeed Owners Manual", "url": "https://www.delta-club-82.com/bible/manuels/litespeed.pdf"},
            {"what": "натяжение паруса снижает сопротивление на малых α (рис. 45–46), крутка увеличивает CDmin и K (рис. 44), Cm(α) нелинеен из-за деформации паруса (рис. 25), luff lines Cm0 +0,1…+0,2, киль-карман ≈ 2° обратного V",
             "ref": "Kroo I. M., 1981, Aerodynamics, aeroelasticity, and stability of hang gliders, NASA TM-81269", "url": "https://ntrs.nasa.gov/citations/19810015490"},
            {"what": "угол носа Combat L 129–131°", "ref": "Aeros, Combat 2 / Combat L owner's manual", "url": "https://delta-club-82.com/bible/manuels/combat2-combatL.pdf"},
            {"what": "паспорта DHV: Vmax VG 0 / VG 100 % (цензура «>90»)", "ref": "tools/research/data/wing_passports/wings_merged.json (из out/haiku_dhv/*.json)", "url": "https://www.dhv.de/db3/muster/"},
            {"what": "качество с VG +10–15 % на 55–80 км/ч [О], крен туже ½ хода «заметно тяжелее и медленнее»", "ref": "docs/archive/plan/wings-lineup.md, §5 (по руководствам WW T2C и Aeros Combat)", "url": ""},
        ],
        "reproduce": "PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python; python3 tools/research/pendulum/pb2_passport.py; "
                     "$PY tools/research/pendulum/pb2_calib.py --jobs 12; $PY tools/research/pendulum/pb2_run.py run --jobs 12; "
                     "$PY tools/research/pendulum/pb2_run.py report",
    }
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    tmp.replace(OUT / "summary.json")
    write_tables(summary)
    try:
        write_figs(summary)
    except Exception as e:  # графики — не часть приёмки
        print("графики:", e)
    print("ошибок", len(errs), *errs[:10], sep="\n")


def _f(x, fmt="{:.2f}"):
    return "—" if x is None or (isinstance(x, float) and not math.isfinite(x)) else fmt.format(x)


def write_tables(s):
    L = ["# PB-2: VG на прототипе — таблицы\n"]
    pp = s["passport"]
    L.append("## Vmax «на себя» (км/ч): модель против паспорта DHV\n")
    L.append("| крыло | паспорт VG 0 | паспорт VG 100 | игра (конфиг) | модель VG 0 | VG ½ | VG 1 | ΔVG1−VG0 модель | ΔVG паспорт | VG1/паспорт VG100 |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for w, p in pp.items():
        v0 = s["variants"]["base"]["wings"][w]["full_pull_kmh"]
        v5 = s["variants"]["vg05"]["wings"][w]["full_pull_kmh"]
        v1 = s["variants"]["vg1"]["wings"][w]["full_pull_kmh"]
        p0, p1 = p["vmax_vg0_kmh"], p["vmax_vg100_kmh"]
        dp = "—" if p0 is None or p1 is None else ("≥ " if p["vmax_vg100_censored"] else "") + f"{p1 - p0:+.0f}"
        ratio = "—" if p1 is None or v1 is None else ("≥ " if False else "") + f"{v1 / p1:.2f}" + (" (паспорт ≥)" if p["vmax_vg100_censored"] else "")
        L.append(f"| {w} | {_f(p0, '{:.0f}')} | {('>' if p['vmax_vg100_censored'] else '') + _f(p1, '{:.0f}')} | {_f(p['game_full_pull_kmh'], '{:.1f}')} | "
                 f"{_f(v0, '{:.1f}')} | {_f(v5, '{:.1f}')} | {_f(v1, '{:.1f}')} | {_f(None if v0 is None or v1 is None else v1 - v0, '{:+.1f}')} | {dp} | {ratio} |")
    L.append("\n## Метрики PB-К2 по вариантам\n")
    keys = ["trim_kmh", "sink_ms", "full_pull_kmh", "full_pull_fx_N", "Kn", "ld_trim", "clp", "cnp", "cn_beta", "cl_beta", "cnr", "clr",
            "dutch_omega_rad_s", "dutch_zeta", "reversal_45_s", "reversal_30_s", "reversal_beta_max_deg", "turn30_beta_cg_deg",
            "turn30_ribbon_deg", "ochi_bank_7s_deg", "turb_capsize_n", "turb_runs_n"]
    L.append("| крыло | вариант | " + " | ".join(keys) + " |")
    L.append("|" + "---|" * (len(keys) + 2))
    for var, v in s["variants"].items():
        if var == "vg0":
            continue
        for w, m in v["wings"].items():
            L.append(f"| {w} | {var} | " + " | ".join(_f(m.get(k), "{:.0f}" if k.startswith("turb") else "{:.3f}") for k in keys) + " |")
    L.append("\n## Поляра по положениям трапеции (u = −1 «на себя» … +1 «от себя»): V км/ч / снижение м/с / качество / усилие рук Н\n")
    for var, v in s["variants"].items():
        if var == "vg0":
            continue
        for w, m in v["wings"].items():
            pol = m.get("polar")
            if not pol:
                continue
            L.append(f"- {w} {var}: " + "; ".join(f"u {pt['u']:+.1f}: {_f(pt['V_kmh'], '{:.1f}')} / {_f(pt['sink_ms'])} / {_f(pt['ld'], '{:.1f}')} / {_f(pt['fx_N'], '{:.0f}')}" for pt in pol))
    L.append("\n## Параметры крыла по вариантам\n")
    L.append("| крыло | вариант | крутка, ° | стреловидность, ° | размах, м | гибкость | cd_scale |")
    L.append("|---|---|---|---|---|---|---|")
    for var, v in s["variants"].items():
        if var == "vg0":
            continue
        for w, m in v["wings"].items():
            L.append(f"| {w} | {var} | {_f(m.get('washout_deg'), '{:.1f}')} | {_f(m.get('sweep_deg'), '{:.1f}')} | {_f(m.get('span_m'), '{:.2f}')} | "
                     f"{_f(m.get('sail_flex'))} | {_f(m.get('cd_scale'), '{:.3f}')} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n", encoding="utf-8")


def write_figs(s):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig_dir = OUT / "fig"
    fig_dir.mkdir(exist_ok=True)
    cols = {"base": "#4C72B0", "vg05": "#DD8452", "vg1": "#C44E52"}
    wings = [w for w in s["variants"]["base"]["wings"] if s["variants"]["base"]["wings"][w].get("polar")]
    fig, axes = plt.subplots(1, len(wings), figsize=(3.4 * len(wings), 3.4), sharey=True)
    for ax, w in zip(np.atleast_1d(axes), wings):
        for var in ("base", "vg05", "vg1"):
            pol = s["variants"][var]["wings"][w].get("polar") or []
            pts = [(pt["V_kmh"], pt["sink_ms"]) for pt in pol if pt.get("V_kmh") and math.isfinite(pt["V_kmh"])]
            if pts:
                pts.sort()
                ax.plot([q[0] for q in pts], [q[1] for q in pts], "o-", color=cols[var], label={"base": "VG 0", "vg05": "VG ½", "vg1": "VG 1"}[var])
        p = s["passport"][w]
        if p.get("vmax_vg0_kmh"):
            ax.axvline(p["vmax_vg0_kmh"], color="#888", ls="--", lw=1)
        if p.get("vmax_vg100_kmh"):
            ax.axvline(p["vmax_vg100_kmh"], color="#444", ls=":", lw=1)
        ax.set_title(w)
        ax.set_xlabel("V, км/ч")
        ax.invert_yaxis()
        ax.grid(alpha=0.3)
    np.atleast_1d(axes)[0].set_ylabel("снижение, м/с")
    np.atleast_1d(axes)[0].legend(fontsize=8)
    fig.suptitle("Поляра по положениям трапеции при VG 0 / ½ / 1 (пунктир — паспорт DHV Vmax VG 0 / VG 100)", fontsize=9)
    fig.tight_layout()
    fig.savefig(fig_dir / "polar_vg.png", dpi=130)
    plt.close(fig)
    fig, ax = plt.subplots(figsize=(7, 3.6))
    x = np.arange(len(wings))
    for i, var in enumerate(("base", "vg05", "vg1")):
        ax.bar(x + (i - 1) * 0.2, [s["variants"][var]["wings"][w].get("full_pull_kmh") or 0 for w in wings], 0.2, color=cols[var], label=f"модель {var}")
    ax.plot(x, [s["passport"][w].get("vmax_vg0_kmh") or np.nan for w in wings], "kv", label="паспорт VG 0")
    ax.plot(x, [s["passport"][w].get("vmax_vg100_kmh") or np.nan for w in wings], "k^", label="паспорт VG 100 (≥ при >90)")
    ax.set_xticks(x, wings, rotation=20, fontsize=8)
    ax.set_ylabel("Vmax «на себя», км/ч")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(fig_dir / "vmax_vg.png", dpi=130)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("run")
    a.add_argument("--jobs", type=int, default=12)
    a.add_argument("--only", default="")
    sp.add_parser("report")
    args = ap.parse_args()
    cmd_run(args) if args.cmd == "run" else cmd_report(args)


if __name__ == "__main__":
    main()
