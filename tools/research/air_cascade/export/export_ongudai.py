"""AC-R2: экспорт случаев Онгудая 400 м (12:00, ветер 150°) в формат R1 v1 (docs/contracts/air-cascade.md).

Эталон — tools/research/air3d/air.py (CuPy, float64), тот же путь решения, что у
picard_gpu_refs.py (solve: make + init_background + solve(max_outer=3000) + finalize), но вход собран
из массивов фикстуры tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12 (hc, H, gam из .bin;
params и profiles — из .json): слоя рельефа data/terrain/ongudai в копиях нет (как в
test_air_picard_gpu.gd, case_ongudai). Упаковка массивов — Pack и порядок из air3d/fixtures.py.

    PY=tools/research/heat_ca/.venv/bin/python
    $PY tools/research/air_cascade/export/export_ongudai.py            # все 4 случая
    $PY tools/research/air_cascade/export/export_ongudai.py u3_heat    # выборочно (u3_mech нужен для сверки поля)

PR-3 (R5 v1): случаи с суффиксом часа `_h1200` / `_h1215` — вход часа снят кодом игры (warm/dump_inputs.gd:
H, θ̄-градиент, z_i, профиль притока), hc/сетка — из фикстуры; см. README («T+15»).

    $PY .../export_ongudai.py u3_heat_h1200 u3_mech_h1200 u3_heat_h1215 u3_mech_h1215

Выход: $AIR_CASCADE_DATA/ongudai/ (по умолчанию ~/data/air_cascade/ongudai/).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/research/air3d"))
import air as A  # noqa: E402
import fixtures as FX  # noqa: E402  (Pack, G, STATE)

FIX = ROOT / "tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12"
OUT = Path(os.environ.get("AIR_CASCADE_DATA", "~/data/air_cascade")).expanduser() / "ongudai"
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
CHECK_EVERY = 10
MAX_OUTER = 3000
CASES = {  # имя → (U10, нагрев)
    "u3_heat": (3.0, True), "u3_mech": (3.0, False), "u0_heat": (0.0, True), "u6_heat": (6.0, True),
}
WARM_IN = Path(os.environ.get("AIR_CASCADE_WARM_INPUTS", str(OUT / "warm_inputs"))).expanduser()
HOURS = {"h1200": 12.0, "h1215": 12.25, "h1230": 12.5}   # суффикс имени → час (SunClock, ч); T, T+15, T+30 (recompute_game_min)
WARM_FROM = {"h1215": "h1200", "h1230": "h1215"}         # цепочка тёплых стартов: суффикс предыдущего слота
ITER_TOL = 10
FIELD_TOL = 1e-3     # доля u_scale
THETA_TOL = 0.05     # К


def load_fixture():
    m = json.loads(FIX.with_suffix(".json").read_text())
    raw = np.fromfile(FIX.with_suffix(".bin"), "<f4")
    arr = {k: raw[o:o + n].astype(np.float64) for k, (o, n) in m["arrays"].items()}
    return m, arr


def ref_iters(m, U, heat):
    R = {(r["U10"], r["heat"], r["dtype"]): r["iters"] for r in m["runs"]}
    return R.get((U, heat, "float64"), R.get((U, heat, "float32")))


def git_rev():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def split_name(name):
    """'u3_heat_h1215' → ('u3_heat', 'h1215'); без суффикса — (name, None) (режим фикстуры 12:00, AC-R2)."""
    for suf in HOURS:
        if name.endswith("_" + suf):
            return name[: -len(suf) - 1], suf
    return name, None


def load_game_inputs(suf):
    """Вход часа от кода игры (warm/dump_inputs.gd): H (ny·nx), gam (nz+2), z_i, alpha, max_profile."""
    d = json.loads((WARM_IN / f"inputs_{suf}.json").read_text())
    assert abs(d["hour"] - HOURS[suf]) < 1e-9, (d["hour"], suf)
    return d


def solve_case(m, arr, U, heat, inp=None):
    import cupy as cp
    g = A.Grid(m["dx"], m["nx"], m["ny"], m["dz"], m["z_bot"], m["nz"], m["x0"], m["y0"])
    hc = arr["hc"].reshape(g.ny, g.nx)
    zc = g.z_bot + (np.arange(g.nz + 2) - 0.5) * g.dz
    if inp is None:      # фикстура 12:00 (AC-R2)
        gam_c, z_i, H = arr["gam"], m["z_i"], arr["H"]
        pr = m["profiles"][f"{U:g}"]
        hl = "12h"
    else:                # вход часа от кода игры
        assert abs(inp["u10"] - U) < 1e-9
        gam_c, z_i, H = np.asarray(inp["gam"], np.float64), inp["z_i"], np.asarray(inp["H"], np.float64)
        pr = dict(alpha=inp["alpha"], max_profile=inp["max_profile"])
        hl = f"{inp['hour']:g}h"
    assert gam_c.size == g.nz + 2 and H.size == g.ny * g.nx
    case = A.Case(U10=U, wdir=m["wdir"], gam=lambda z: np.interp(np.asarray(z, float), zc, gam_c),
                  z_i=z_i, H=H.reshape(g.ny, g.nx) if heat else None,
                  label=f"ongudai {hl} U{U:g} {m['wdir']:g}° {'' if heat else 'noheat'}".strip())
    prm = replace(A.Params(), alpha=pr["alpha"], max_profile=pr["max_profile"])
    for k, v in m["params"].items():
        assert getattr(prm, k) == v, (k, getattr(prm, k), v)       # фикстура считалась на умолчаниях
    assert abs(prm.dtau_per_m * g.dx - m["dtau_u"]) < 1e-9
    S = A.Air(g, hc, case, prm, dtype=np.float64)
    S.init_background()
    st = S.solve(max_outer=MAX_OUTER, check_every=CHECK_EVERY, **TOL)
    S.finalize()
    cp.cuda.Device().synchronize()
    return S, case, st


INPUT_KEYS = ("hc", "cell", "tu", "tv", "tw", "nu_bg", "Q", "gam", "cplz", "sp_u", "sp_w", "spc", "ubg", "vbg",
              "lam", "Kx", "Ky", "Kz", "fixed_u", "fixed_v", "b_u", "b_v")
# вход решателя → откуда берётся в игре (файл:функция)
GAME_SRC = {
    "Q": "air_place.gd:surface_flux (H по часу: SurfaceHeating.directions/sky_heat) → air_case.gd:prepare (Q из H)",
    "gam": "air_place.gd:day + gamma (θ̄(z) на час: t, z_dry, профиль над слоем)",
}
GAME_SRC_DEFAULT = "производное от z_i/γ/H внутри Air.__init__/init_background (air.py), вход игры — см. поля H, gam, z_i"


def read_case_arrays(path):
    """Входные массивы записанного случая (float32 LE): {имя: ndarray}."""
    mm = json.loads(Path(str(path) + ".json").read_text())
    raw = np.fromfile(str(path) + ".bin", "<f4")
    return {k: raw[o:o + n].astype(np.float64) for k, (o, n) in mm["arrays"].items() if k in INPUT_KEYS}, mm


def diff_inputs(a_new, a_old):
    """Что изменилось во входе решателя между двумя случаями: [{name, max_abs, rms, ref_max}] (только ненулевые)."""
    ch, same = [], []
    for k in INPUT_KEYS:
        d = a_new[k] - a_old[k]
        mx = float(np.max(np.abs(d)))
        if mx > 0:
            ch.append(dict(name=k, max_abs=mx, rms=float(np.sqrt(np.mean(d ** 2))),
                           ref_max_abs=float(np.max(np.abs(a_old[k]))),
                           source=GAME_SRC.get(k, GAME_SRC_DEFAULT)))
        else:
            same.append(k)
    return ch, same


def export(name, m, arr, ref_stats):
    base_name, suf = split_name(name)
    U, heat = CASES[base_name]
    inp = load_game_inputs(suf) if suf else None
    S, case, st = solve_case(m, arr, U, heat, inp)
    NX, NY, NZ = S.shape[2], S.shape[1], S.shape[0]
    G = FX.G
    P = FX.Pack()
    P.add("hc", S.hc)
    for k, a in (("cell", S.cell_np), ("tu", S.tu_np), ("tv", S.tv_np), ("tw", S.tw_np), ("nu_bg", S.nu_np),
                 ("Q", S.Q_np), ("gam", S.gam_np), ("cplz", S.cplz_np), ("sp_u", S.sp_np), ("sp_w", S.spw_np),
                 ("spc", S.spc_np), ("ubg", S.ubg_np), ("vbg", S.vbg_np), ("lam", S.lam_np),
                 ("Kx", S.Kx_np), ("Ky", S.Ky_np), ("Kz", S.Kz_np)):
        P.add(k, np.nan_to_num(np.asarray(a, np.float64)))
    P.add("fixed_u", G(S.fixed_u)); P.add("fixed_v", G(S.fixed_v))
    P.add("b_u", G(S.b_u)); P.add("b_v", G(S.b_v))
    for k in FX.STATE:
        P.add("sol_" + k, np.nan_to_num(np.asarray(G(getattr(S, k)), np.float64)))
    u, v, w, th = S.centers()
    uu, vv, ww, tt = (np.asarray(x, np.float64) for x in (u, v, w, th))
    fin = {"u": uu, "v": vv, "w": ww, "theta": tt}
    res = S.hist[-1]
    t_ref = round(S.wall - S.t_check, 3)
    src = dict(fixture="tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12", U10=U, heat=heat,
               dtype="float64", git=git_rev())
    if inp is not None:
        src.update(hour=inp["hour"], t_max_c=inp["t_max"], inputs_from="tools/research/air_cascade/warm/dump_inputs.gd",
                   hc_from="fixture (слоя рельефа Онгудая в копиях нет)", z_i_m=inp["z_i"],
                   profile=dict(alpha=inp["alpha"], max_profile=inp["max_profile"], stab_class=inp["stab_class"],
                                sun_elev=inp["sun_elev"]),
                   H_range=[inp["H_min"], inp["H_max"]])
        if suf in WARM_FROM:
            src["warm_from"] = f"ongudai_d400_{base_name}_{WARM_FROM[suf]}"
    meta = dict(
        format="ref-case", version=1, case=f"ongudai_d400_{name}",
        dims=[NX, NY, NZ], halo=1, dx=S.g.dx, dz=S.g.dz, z_bot=S.g.z_bot, x0=S.g.x0, y0=S.g.y0,
        nx=S.g.nx, ny=S.g.ny, nz=S.g.nz,
        params={k: getattr(S.prm, k) for k in S.prm.__dataclass_fields__},
        case_params=dict(U10=case.U10, wdir=case.wdir, z_i=case.z_i, U_aloft=S.U_a, label=case.label),
        cd=S.cd, fixed_scale=S.fixed_scale, n_fluid=S.n_fluid, closure=S.closure_info,
        mg_levels_xyz=[list(L["shape"])[::-1] for L in S.mg.levels],
        criterion=dict(tol_mom_rms=TOL["tol_mom"], tol_th_rms=TOL["tol_th"], tol_div_rms=TOL["tol_div"],
                       check_every=CHECK_EVERY),
        solution=dict(status=st, iters=int(S.outer), final_residuals=res,
                      max_speed=float(np.nanmax(np.sqrt(uu ** 2 + vv ** 2 + ww ** 2))),
                      w_range=[float(np.nanmin(ww)), float(np.nanmax(ww))],
                      th_range=[float(np.nanmin(tt)), float(np.nanmax(tt))]),
        history=[dict(it=h["it"], mom_rms=h["mom_rms"], th_rms=h["th_rms"], thd_rms=h["thd_rms"],
                      div_rms=h["div_rms"]) for h in S.hist],
        source=src,
        crop=m["crop"], t_ref_s=t_ref,
        notes=(f"Онгудай 400 м, {inp['hour']:g} ч (вход часа снят кодом игры: warm/dump_inputs.gd, hc из фикстуры), "
               "ветер с 150°. " if inp else "Онгудай 400 м, 12:00, ветер с 150°. ") +
              " Постоянный вход после подготовки Air + решение до критерия + "
              "finalize (sol_*), float64 → float32 LE. Без блоков одной итерации. Вход собран из массивов фикстуры "
              "(hc, H, gam — float32), solve как picard_gpu_refs.solve (taper по умолчанию, graph, max_outer 3000).")
    if suf in WARM_FROM:
        old = OUT / f"ongudai_d400_{base_name}_{WARM_FROM[suf]}"
        a_old, _ = read_case_arrays(old)
        offs = P.arrays
        flat = np.concatenate(P.parts)
        a_new = {k: flat[o:o + n].astype(np.float64) for k, (o, n) in offs.items() if k in INPUT_KEYS}
        ch, same = diff_inputs(a_new, a_old)
        h0 = load_game_inputs(WARM_FROM[suf])
        dH = np.asarray(inp["H"]) - np.asarray(h0["H"])
        src["changed"] = ch
        src["unchanged"] = same
        src["changed_game_inputs"] = dict(
            H=dict(max_abs=float(np.abs(dH).max()), rms=float(np.sqrt(np.mean(dH ** 2))), mean=float(dH.mean()),
                   ref_max=float(np.max(h0["H"])), source=GAME_SRC["Q"]),
            gam=dict(max_abs=float(np.abs(np.asarray(inp["gam"]) - np.asarray(h0["gam"])).max()),
                     source=GAME_SRC["gam"]),
            z_i=dict(old=h0["z_i"], new=inp["z_i"], delta=inp["z_i"] - h0["z_i"],
                     source="air_place.gd:day (z_i по θ-профилю на час; set_zi_terrain по столбцам — в air.py нет)"),
            profile=dict(alpha=[h0["alpha"], inp["alpha"]], max_profile=[h0["max_profile"], inp["max_profile"]],
                         sun_elev=[h0["sun_elev"], inp["sun_elev"]],
                         source="air_case.gd:set_inflow → wind_profile.gd:apply_to_case"),
            wind=dict(u10=[h0["u10"], inp["u10"]], wdir=m["wdir"], changed=False,
                      source="air_runtime.gd:conditions_of (ветер — настройки/атмосфера, от часа не зависит)"))
    OUT.mkdir(parents=True, exist_ok=True)
    base = OUT / f"ongudai_d400_{name}"
    arrays = P.arrays
    # запись во временный файл и переименование
    tb, tj = Path(str(base) + ".bin.tmp"), Path(str(base) + ".json.tmp")
    np.concatenate(P.parts).tofile(tb)
    tj.write_text(json.dumps(dict(meta, arrays=arrays), ensure_ascii=False, indent=1))
    os.replace(tb, str(base) + ".bin")
    os.replace(tj, str(base) + ".json")
    size = os.path.getsize(str(base) + ".bin") / 2 ** 20
    ref = ref_iters(m, U, heat) if inp is None else S.outer
    print(f"{name}: {st}, iters {S.outer} (fixture {ref}), t_ref {t_ref} s, {size:.1f} MB", flush=True)
    ref_stats[name] = dict(iters=int(S.outer), ref=ref, t=t_ref, mb=size, fields=fin)
    del S


def check_field(m, arr, stats):
    """Поле у старта (crop, центры клеток) u3_heat (+w_mech из u3_mech) против crop_* фикстуры."""
    if "u3_heat" not in stats or "u3_mech" not in stats:
        return None
    c = m["crop"]; n = c["n"]; i0, j0 = c["i0"], c["j0"]
    h, mm = stats["u3_heat"]["fields"], stats["u3_mech"]["fields"]
    mine = dict(u=h["u"], v=h["v"], w_mech=mm["w"], w_conv=h["w"] - mm["w"], theta=h["theta"])
    mine = {k: np.nan_to_num(a)[:, j0:j0 + n, i0:i0 + n].astype("<f4").astype(np.float64) for k, a in mine.items()}
    us = m["u_scale"]
    out = {}
    for k, a in mine.items():
        ref = arr["crop_" + k].reshape(a.shape)
        d = float(np.max(np.abs(a - ref)))
        out[k] = dict(max_abs=d, rel=d / us if k != "theta" else None)
    ok = all(v["rel"] <= FIELD_TOL for k, v in out.items() if k != "theta") and out["theta"]["max_abs"] <= THETA_TOL
    return out, ok, us


def main():
    names = sys.argv[1:] or list(CASES)
    names = sorted(names, key=lambda n: (split_name(n)[1] or "", n))      # h1200 раньше h1215 (changed — по записанному)
    m, arr = load_fixture()
    stats = {}
    for nme in names:
        export(nme, m, arr, stats)
    print("\ncase           iters  fixture  diff  t_ref_s   MB")
    bad = False
    for nme, s in stats.items():
        d = abs(s["iters"] - s["ref"])
        bad |= d > ITER_TOL
        print(f"{nme:13s} {s['iters']:6d} {s['ref']:8d} {d:5d} {s['t']:8.2f} {s['mb']:6.1f}")
    fc = check_field(m, arr, stats)
    if fc:
        out, ok, us = fc
        print(f"\nполе у старта (crop {m['crop']}), u_scale {us:.3f}:")
        for k, v in out.items():
            print(f"  {k:7s} max|Δ| {v['max_abs']:.3e}" + (f"  /u_scale {v['rel']:.2e}" if v["rel"] is not None else "  К"))
        print("  допуск: ≤ 1e-3·u_scale, θ′ ≤ 0,05 К →", "OK" if ok else "FAIL")
        bad |= not ok
    print("max_iter_diff=%d" % max(abs(s["iters"] - s["ref"]) for s in stats.values()))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
