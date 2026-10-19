#!/usr/bin/env python3
"""VM-11 (VM-К8 v1): руки отпускают пилота вдоль киля только при выходе из «на себя» — проект на прототипе, 48 крыльев.

Модель — прототип VM-6 `game` (игра после порта: VM-3 «nl», pull_full_release 0,5 м/с, arm_ff_load) плюс ключ
`Params.arm_release_event` (выключен = нынешнее, руки держат всегда). Сценарии выхода и критерий переворота — VM-К5 (как
vm6_run.py): release_normal, release_smooth, release_1p8. Ограждения «в обычном полёте как сейчас» — сценарии эталонов
игры на `game`-модели: переложение 45→45 (test_reversal_45), крен Очи (test_ochi_side_force), фугоида (test_phugoid),
болтанка σ 1 м/с ×20 (vm6_run.sc_turb). Справочно relturb — болтанка сразу после обычного разгона и выхода.

Варианты (`VARS`, поверх `game`):
  ev        — отпускание по событию: pitch ≤ −0,25, затем 0 → f.x = 0, пока ввод не изменится или амплитуда качания
              пилота у нейтрали не пробудет < 5 см целый период маятника пилота 2π√(L/g) (основной);
  ev_now    — то же, но держат снова в первый же миг амплитуды < 5 см;
  ev_input  — то же, держат снова только по изменению ввода;
  ev_pass   — как ev_now, но во время отпускания пассивная рука 300 Н/м, 30 Н·с/м (вариант (2) внутри события);
  ev_p50, ev_s03, ev_s10 — чувствительность: порог 0,5; амплитуда 3 и 10 см;
  passive   — вариант (2) без события: пассивная рука на любом вводе 0 (VM-6 h_passive).

  $PY tools/research/pendulum/vm11_run.py run --jobs 12 [--wings …] [--vars game,ev] [--scen release,ref,turb,relturb]
  $PY tools/research/pendulum/vm11_run.py report     → out/vm11/summary.json, tables.md, fig/
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
import vm2_run as V2  # noqa: E402
import vm6_run as V6  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run, settle  # noqa: E402

OUT = HERE / "out" / "vm11"
D, RAD = math.degrees, math.radians
WINGS = V6.WINGS
DIAG_WINGS = V6.DIAG_WINGS
REF_WINGS = E.WINGS  # training, laminar, sport — крылья эталонов tests/flight/pendulum/reference.json
TURB_WINGS = ["sport", "laminar", "training"]

EV = dict(V6.GAME, arm_release_event=True, arm_release_pull=0.25, arm_release_settle_m=0.05,
          arm_release_settle_s=float("nan"))
VARS = {
    "game": dict(V6.GAME),
    "ev": dict(EV),  # основной: держат снова, когда амплитуда < 5 см целый период маятника пилота 2π√(L/g)
    "ev_now": dict(EV, arm_release_settle_s=0.0),  # держат снова в первый же миг амплитуды < 5 см
    "ev_input": dict(EV, arm_release_settle_m=0.0),  # держат снова только по изменению ввода
    "ev_pass": dict(EV, arm_release_settle_s=0.0, arm_release_k=300.0, arm_release_b=30.0),  # пассивная рука при отпускании
    "ev_p50": dict(EV, arm_release_pull=0.5),
    "ev_s03": dict(EV, arm_release_settle_m=0.03),
    "ev_s10": dict(EV, arm_release_settle_m=0.10),
    "passive": dict(V6.GAME, arm_neutral_k=300.0, arm_neutral_b=30.0),  # вариант (2) без события (VM-6 h_passive)
}
FIX = "ev"
T_STEADY = 70.0  # с: arm_regrip_t_s — время модели; выход начинается после 70 с установившегося полёта (vm6_run.sc_release)
V6.HYP.update(VARS)  # V6.make берёт ключи варианта из HYP


# ----------------------------------------------------------------------------- выход: метрики отпускания
_release0 = V6.release


def _release(s, ctrl, Vt, every=1):
    r, m = _release0(s, ctrl, Vt, every)
    m["arm_release_count"] = int(getattr(s, "rel_count", 0))
    m["arm_release_time_s"] = float(getattr(s, "rel_time", 0.0))
    m["arm_release_on_end"] = bool(getattr(s, "rel_on", False))
    m["arm_regrip_t_s"] = float(getattr(s, "rel_regrip_t", float("nan")))
    return r, m


V6.release = _release  # sc_release зовёт release() модуля vm6_run


def sc_release(wing, var):
    return V6.sc_release(wing, var)


# ----------------------------------------------------------------------------- ограждения: сценарии эталонов игры
def sc_ref(wing, var):
    """Переложение 45→45, фугоида (+3 м/с), а для laminar — крен Очи (30 Н вбок, пилот 72,6 кг): процедуры
    export_reference.sc_reversal / sc_phugoid / sc_ochi на модели варианта."""
    out = {}
    s = V6.make(wing, var)
    bh = BankHold(RAD(45.0), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 14.0)
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=1)
    out["rev_phi_start"] = float(D(r0["phi"][-1]))
    out["rev_t_to_minus"] = float(first_cross(r["t"], r["phi"], RAD(-45.0)))
    out["rev_t_to_zero"] = float(first_cross(r["t"], r["phi"], 0.0))
    out["rev_release_count"] = int(s.rel_count)
    s = V6.make(wing, var)
    s.vel = s.vel * (1 + 3.0 / np.linalg.norm(s.vel))
    s.vn = s.vn + (s.vel - s.vn[-1])
    r = run(s, lambda t, o: Control(), 60.0, every=1)
    t, V = r["t"], r["V"]
    pk = [i for i in range(1, len(V) - 1) if V[i] > V[i - 1] and V[i] >= V[i + 1]]
    out["phug_period_s"] = float(np.median(np.diff(t[pk]))) if len(pk) >= 2 else float("nan")
    Vm = float(np.median(V[-600:]))
    amps = [V[i] - Vm for i in pk]
    out["phug_amp_ratio"] = float(amps[1] / amps[0]) if len(amps) >= 2 and amps[0] != 0 else float("nan")
    out["phug_release_count"] = int(s.rel_count)
    if wing == "laminar":
        s0 = V6.make(wing, var)
        p = s0.p.with_(m_pilot=72.6)
        s = V6._rebuild(s0, p, s0.dt, {})
        a, st = trim.solve_trim(s)
        s.reset_air(st)
        settle(s, 2.0)
        r = run(s, lambda t, o: Control(force_y=30.0 if t < 8.5 else None), 12.0, every=1)
        out["ochi_phi_7s"] = float(D(np.interp(7.0, r["t"], r["phi"])))
        out["ochi_phi_max"] = float(D(r["phi"].max()))
        out["ochi_release_count"] = int(s.rel_count)
    return out


def sc_relturb(wing, var, seeds=10, T=40.0, p_hold=-0.5, t_hold=30.0):
    """Справочно: обычный разгон (pitch −0,5 без добора, 30 с), плавный выход за 0,5 с, затем болтанка σ 1 м/с 40 с с
    регулятором крена (как sc_turb, тангаж 0). Проверяет, держат ли руки снова после отпускания."""
    rows = []
    for k in range(seeds):
        s = V6.make(wing, var)
        V6.steady(s, V6.ramp(p_hold, False), t_hold, t_hold - 1.0)
        t0 = s.t
        while s.t - t0 < V6.T_HAND + 1e-9:
            s.step(V6.smooth_out()(s.t - t0))
        s.air_fn = E.turbulence_fn(E.turbulence_modes(sigma=1.0, seed=7 + k))
        hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
        o = s.observe()
        ph, th, blow, t_rel = 0.0, [0.0, 0.0], False, 0.0
        for _ in range(int(round(T / s.dt))):
            c = hold(0.0, o)
            s.step(c)
            o = s.observe()
            if not np.isfinite(o["phi"]) or o["V"] > 80:
                blow = True
                break
            ph = max(ph, abs(D(o["phi"])))
            th = [min(th[0], D(o["theta"])), max(th[1], D(o["theta"]))]
        rows.append({"seed": 7 + k, "phi_max_deg": ph, "theta_min_deg": th[0], "theta_max_deg": th[1], "blowup": blow,
                     "upset": bool(blow or ph > 60.0 or th[0] < -60.0), "release_time_s": float(getattr(s, "rel_time", 0.0)),
                     "regrip_t_s": float(getattr(s, "rel_regrip_t", float("nan")) - t0)})
    return {"relturb_upset": int(sum(r["upset"] for r in rows)), "relturb_n": len(rows),
            "relturb_release_time_s_median": float(np.median([r["release_time_s"] for r in rows])),
            "relturb_rows": rows}


SCEN = {"release": sc_release, "ref": sc_ref, "turb": V6.sc_turb, "relturb": sc_relturb}


def job(a):
    wing, var, sc = a
    t0 = time.time()
    try:
        r, err = SCEN[sc](wing, var), None
    except Exception:
        r, err = {}, traceback.format_exc()
    return {"key": f"{wing}/{var}/{sc}", "wing": wing, "var": var, "sc": sc, "err": err, "sec": round(time.time() - t0, 1),
            "res": r}


def cmd_run(args):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "results.jsonl"
    done = V6._done(out)
    wings = args.wings.split(",") if args.wings else WINGS
    jobs = []
    for v in args.vars.split(","):
        for sc in args.scen.split(","):
            ws = {"ref": [w for w in wings if w in REF_WINGS], "turb": [w for w in wings if w in TURB_WINGS],
                  "relturb": [w for w in wings if w in TURB_WINGS]}.get(sc, wings)
            jobs += [(w, v, sc) for w in ws]
    jobs = [j for j in jobs if "/".join(j) not in done]
    # долгие (release, turb) раньше коротких
    jobs.sort(key=lambda j: {"release": 0, "turb": 1, "relturb": 1, "ref": 2}[j[2]])
    print(f"план: {len(jobs)} (сделано {len(done)})", flush=True)
    with ProcessPoolExecutor(args.jobs) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in jobs]
        for i, fu in enumerate(as_completed(futs)):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
            f.flush()
            print(i, r["key"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
            if r["err"]:
                print(r["err"].splitlines()[-1], flush=True)


# ----------------------------------------------------------------------------- сводка
SCS = V6.SCS


def collect():
    acc = {}
    for ln in (OUT / "results.jsonl").read_text().splitlines():
        if ln.strip():
            r = json.loads(ln)
            if not r.get("err"):
                acc.setdefault(r["var"], {}).setdefault(r["wing"], {}).update(r["res"])
    return acc


_tuck = V6._tuck


def _cnt(acc, v, sc, ws):
    return int(sum(_tuck(acc[v][w], sc) for w in ws if w in acc.get(v, {}) and "release_smooth" in acc[v][w]))


def _rel_wings(acc, v):
    return [w for w in WINGS if w in acc.get(v, {}) and "release_smooth" in acc[v][w]]


def _v0(res, k):
    t = res["trim_kmh"]
    if k == "normal":
        return (res.get("normal") or {}).get("V_kmh", float("nan")) / t
    if k == "smooth":
        return (res.get("full") or {}).get("V_kmh", float("nan")) / t
    return (res.get("release_1p8") or {}).get("V_hold_kmh", float("nan")) / t


def cmd_report(args):
    acc = collect()
    G_, F_ = acc["game"], acc[FIX]
    for v in ("game", FIX):
        miss = [w for w in WINGS if w not in acc[v] or "release_smooth" not in acc[v][w]]
        if miss:
            raise SystemExit(f"нет release у {v}: {miss}")
        miss = [w for w in REF_WINGS if "rev_t_to_minus" not in acc[v].get(w, {})]
        miss += [w for w in TURB_WINGS if "turb_upset" not in acc[v].get(w, {})]
        if miss:
            raise SystemExit(f"нет ref/turb у {v}: {miss}")
    pp = V2.passport()
    ref_trim = {w: E.wing_cfg(w)["trim_speed_kmh"] for w in WINGS}
    le2 = [w for w in WINGS if _v0(F_[w], "normal") <= 2.0]
    rev_dev = {w: abs(F_[w]["rev_t_to_minus"] - G_[w]["rev_t_to_minus"]) / G_[w]["rev_t_to_minus"] for w in REF_WINGS}
    phug_dev = {w: abs(F_[w]["phug_period_s"] - G_[w]["phug_period_s"]) / G_[w]["phug_period_s"] for w in REF_WINGS}
    q = V2._ratios({w: (F_[w].get("full") or {}).get("V_kmh") for w in WINGS}, pp)
    qg = V2._ratios({w: (G_[w].get("full") or {}).get("V_kmh") for w in WINGS}, pp)
    variants = []
    for v in VARS:
        if v not in acc:
            continue
        ws = _rel_wings(acc, v)
        row = {"name": v, "keys": {k: x for k, x in VARS[v].items() if V6.GAME.get(k) != x}, "wings": len(ws)}
        if ws:
            row.update({"normal": _cnt(acc, v, "release_normal", ws), "smooth": _cnt(acc, v, "release_smooth", ws),
                        "p1_8": _cnt(acc, v, "release_1p8", ws),
                        "normal_le2": int(sum(_tuck(acc[v][w], "release_normal") for w in ws if _v0(acc[v][w], "normal") <= 2.0)),
                        "game_same_wings": {sc: _cnt(acc, "game", sc, ws) for sc in SCS}})
        tw = [w for w in TURB_WINGS if "turb_upset" in acc[v].get(w, {})]
        if tw:
            row["turb"] = {w: acc[v][w]["turb_upset"] for w in tw}
        tw = [w for w in TURB_WINGS if "relturb_upset" in acc[v].get(w, {})]
        if tw:
            row["relturb"] = {w: acc[v][w]["relturb_upset"] for w in tw}
            row["relturb_release_time_s_median"] = {w: acc[v][w]["relturb_release_time_s_median"] for w in tw}
        rw = [w for w in REF_WINGS if "rev_t_to_minus" in acc[v].get(w, {})]
        if rw:
            row["rev_t_to_minus"] = {w: acc[v][w]["rev_t_to_minus"] for w in rw}
            row["phug_period_s"] = {w: acc[v][w]["phug_period_s"] for w in rw}
            if "ochi_phi_max" in acc[v].get("laminar", {}):
                row["ochi_phi_max"] = acc[v]["laminar"]["ochi_phi_max"]
        variants.append(row)
    rel = [(F_[w].get(sc) or {}) for w in WINGS for sc in SCS]
    s = {
        "contract": "VM-К8 v1", "task": "VM-11", "wings": len(WINGS), "fix": FIX, "fix_keys": VARS[FIX],
        "tuck_1p8_count": _cnt(acc, FIX, "release_1p8", WINGS),
        "tuck_normal_count": _cnt(acc, FIX, "release_normal", WINGS),
        "tuck_normal_le2_count": int(sum(_tuck(F_[w], "release_normal") for w in le2)),
        "tuck_normal_le2_wings_n": len(le2),
        "tuck_smooth_count": _cnt(acc, FIX, "release_smooth", WINGS),
        "tuck_1p8_wings": [w for w in WINGS if _tuck(F_[w], "release_1p8")],
        "tuck_normal_wings": [w for w in WINGS if _tuck(F_[w], "release_normal")],
        "tuck_smooth_wings": [w for w in WINGS if _tuck(F_[w], "release_smooth")],
        "base": {"tuck_1p8_count": _cnt(acc, "game", "release_1p8", WINGS),
                 "tuck_normal_count": _cnt(acc, "game", "release_normal", WINGS),
                 "tuck_normal_le2_count": int(sum(_tuck(G_[w], "release_normal") for w in WINGS if _v0(G_[w], "normal") <= 2.0)),
                 "tuck_smooth_count": _cnt(acc, "game", "release_smooth", WINGS)},
        "reversal_45_dev_max": float(max(rev_dev.values())), "reversal_45_s": {w: [G_[w]["rev_t_to_minus"], F_[w]["rev_t_to_minus"]] for w in REF_WINGS},
        "ochi_bank_dev_max_deg": float(abs(F_["laminar"]["ochi_phi_max"] - G_["laminar"]["ochi_phi_max"])),
        "ochi_bank_deg": [G_["laminar"]["ochi_phi_max"], F_["laminar"]["ochi_phi_max"]],
        "phugoid_period_dev_max": float(max(phug_dev.values())),
        "phugoid_period_s": {w: [G_[w]["phug_period_s"], F_[w]["phug_period_s"]] for w in REF_WINGS},
        "turb_upsets_total": int(sum(F_[w]["turb_upset"] for w in TURB_WINGS)),
        "turb_upsets_total_base": int(sum(G_[w]["turb_upset"] for w in TURB_WINGS)),
        "turb_upsets": {w: [G_[w]["turb_upset"], F_[w]["turb_upset"]] for w in TURB_WINGS},
        "relturb_upsets": {w: [G_[w].get("relturb_upset"), F_[w].get("relturb_upset")] for w in TURB_WINGS},
        "relturb_n_per_wing": F_["sport"].get("relturb_n"),
        "guard_release_events": int(sum(F_[w].get(k, 0) for w in REF_WINGS for k in ("rev_release_count", "phug_release_count", "ochi_release_count"))),
        "vmax_ratio_median": round(float(np.median(q)), 4), "vmax_ratio_p10": round(float(np.percentile(q, 10)), 4),
        "vmax_ratio_n": len(q), "vmax_ratio_median_base": round(float(np.median(qg)), 4),
        "trim_dev_max_kmh": float(max(abs(F_[w]["trim_kmh"] - ref_trim[w]) for w in WINGS)),
        "release_time_s_median": {sc: float(np.median([(F_[w].get(sc) or {}).get("arm_release_time_s", 0.0) for w in WINGS])) for sc in SCS},
        "release_regrip_frac": {sc: float(np.mean([math.isfinite((F_[w].get(sc) or {}).get("arm_regrip_t_s", float("nan"))) for w in WINGS])) for sc in SCS},
        "release_events_min": int(min(m.get("arm_release_count", 0) for m in rel)),
        "release_g_smooth_max": float(max(V6._fin([(F_[w].get("release_smooth") or {}).get("rel_g_max") for w in WINGS]))),
        "release_g_smooth_max_base": float(max(V6._fin([(G_[w].get("release_smooth") or {}).get("rel_g_max") for w in WINGS]))),
        "v0_vt_median": {v: {k: float(np.nanmedian([_v0(acc[v][w], k) for w in WINGS])) for k in ("normal", "smooth", "p1_8")} for v in ("game", FIX)},
        "variants": variants,
        "note": "переворот — VM-К5 (тангаж < −60°, |α| > 90° за 30 с, средняя V 25–30 с вне ±10 % трима); база — вариант game "
                "(игра после порта); ограждения — сценарии эталонов игры на модели варианта; release_g_* — |F полос|/(M·g) до "
                "первого кадра переворота",
    }
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(s, ensure_ascii=False, indent=1, default=float))
    tmp.replace(OUT / "summary.json")
    _tables(acc, s)
    _figs(acc)
    print(json.dumps({k: v for k, v in s.items() if k != "variants"}, ensure_ascii=False, indent=1, default=float))


def _flags(res):
    return "".join("П" if _tuck(res, sc) else "в" for sc in SCS) if res and "release_smooth" in res else "—"


def _tables(acc, s):
    G_, F_ = acc["game"], acc[FIX]
    f2 = lambda x: "—" if x is None or not math.isfinite(x) else f"{x:.2f}"
    L = ["# VM-11: отпускание по событию — таблицы", "",
         "Флаги — release_normal / release_smooth / release_1p8: **П** — переворот, «в» — выход. База — `game`.", "",
         "## Варианты", "", "| вариант | ключи | крыльев | normal | normal ≤ 2·Vт | smooth | 1,8 | game на тех же n/s/1,8 | "
         "болтанка sport/laminar/training | переложение tr/lam/sp, с | фугоида tr/lam/sp, с | крен Очи, ° |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in s["variants"]:
        g = r.get("game_same_wings", {})
        tb = r.get("turb", {})
        rv, ph = r.get("rev_t_to_minus", {}), r.get("phug_period_s", {})
        L.append(f"| {r['name']} | `{json.dumps(r['keys'], ensure_ascii=False)}` | {r['wings']} | {r.get('normal', '—')} | "
                 f"{r.get('normal_le2', '—')} | {r.get('smooth', '—')} | {r.get('p1_8', '—')} | "
                 f"{g.get('release_normal', '—')} / {g.get('release_smooth', '—')} / {g.get('release_1p8', '—')} | "
                 f"{' / '.join(str(tb.get(w, '—')) for w in TURB_WINGS)} | {' / '.join(f2(rv.get(w)) for w in REF_WINGS)} | "
                 f"{' / '.join(f2(ph.get(w)) for w in REF_WINGS)} | {f2(r.get('ochi_phi_max'))} |")
    L += ["", "## По крыльям (game → ev)", "",
          "| крыло | трим | V0/Vт normal / full / 1,8 | game | ev | отпущены, с (n/s/1,8) | снова держат, с (n/s/1,8) | "
          "θ макс. game / ev, ° |", "|---|---|---|---|---|---|---|---|"]
    for w in WINGS:
        g, f = G_[w], F_[w]
        th = lambda r: max(V6._fin([(r.get(sc) or {}).get("rel_theta_max_pre_deg") for sc in SCS]) or [float("nan")])
        L.append(f"| {w} | {f['trim_kmh']:.1f} | {_v0(g, 'normal'):.2f} / {_v0(g, 'smooth'):.2f} / {_v0(g, 'p1_8'):.2f} | "
                 f"{_flags(g)} | {_flags(f)} | "
                 f"{' / '.join(f'{(f.get(sc) or {}).get('arm_release_time_s', 0.0):.1f}' for sc in SCS)} | "
                 f"{' / '.join(f2((f.get(sc) or {}).get('arm_regrip_t_s', float('nan')) - T_STEADY) for sc in SCS)} | {th(g):.0f} / {th(f):.0f} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n")


def _figs(acc):
    """out/vm11/fig/v0_outcome_48.png — исход выхода по V0/Vтрим: game против ev (пороги точки Ланчестера — VM-6)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    lp = V6.OUT / "lanchester.json"
    lan = json.loads(lp.read_text())["thresholds_V0_Vt"] if lp.exists() else {}
    fd = OUT / "fig"
    fd.mkdir(parents=True, exist_ok=True)
    fig, axs = plt.subplots(1, 2, figsize=(10, 4), sharey=True)
    for ax, v, title in ((axs[0], "game", "руки держат всегда (game)"), (axs[1], FIX, f"отпускание по событию ({FIX})")):
        for k, (sc, y) in enumerate((("release_normal", "normal"), ("release_smooth", "smooth"), ("release_1p8", "p1_8"))):
            xs = [_v0(acc[v][w], y) for w in WINGS]
            tk = [_tuck(acc[v][w], sc) for w in WINGS]
            yy = [k + 0.15 * ((i % 5) - 2) / 2 for i in range(len(xs))]
            ax.scatter([x for x, t in zip(xs, tk) if t], [a for a, t in zip(yy, tk) if t], marker="x", c="#b2182b", s=18,
                       label="переворот" if k == 0 else None)
            ax.scatter([x for x, t in zip(xs, tk) if not t], [a for a, t in zip(yy, tk) if not t], marker="o",
                       facecolors="none", edgecolors="#2166ac", s=18, label="выход" if k == 0 else None)
        for key, ls, lab in (("tuck_tau0.5", "--", "точка Ланчестера: θ < −60° / петля"),
                             ("candle_tau0.5", ":", "точка: «свеча» V < 0,5·Vт")):
            if key in lan:
                ax.axvline(lan[key]["median"], ls=ls, c="k", lw=1, label=lab)
        ax.axvline(2.0, ls="-.", c="#777777", lw=0.8, label="2·Vтрим (порог normal VM-К8)")
        ax.set_yticks([0, 1, 2], ["normal", "smooth", "1,8"])
        ax.set_xlabel("V0 / Vтрим")
        ax.set_title(title)
        ax.grid(alpha=0.3)
    axs[0].legend(fontsize=7, loc="lower right")
    fig.tight_layout()
    fig.savefig(fd / "v0_outcome_48.png", dpi=130)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("run")
    a.add_argument("--wings", default="")
    a.add_argument("--vars", default="game,ev")
    a.add_argument("--scen", default="release,turb,ref")
    a.add_argument("--jobs", type=int, default=12)
    sub.add_parser("report")
    args = ap.parse_args()
    {"run": cmd_run, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
