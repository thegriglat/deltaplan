#!/usr/bin/env python3
"""Контрактный тест thermal-bubble (docs/contracts/thermal-bubble.md): TB1, TB2, TB3.

python3 check_contract.py tb1            — шаблон bubble.py
python3 check_contract.py tb2            — порт нынешнего профиля current.py
python3 check_contract.py <файл.json>... — сводки TB3 (по полю format)
python3 check_contract.py tb4 [v2|v3]    — имена стыка TB4 в rust/dp-air (v2 — с кешем и радиусом пузырей; v3 — без флага)
Только numpy + stdlib. Код возврата 0 — всё прошло; иначе 1 и список нарушений.
"""
from __future__ import annotations

import dataclasses
import importlib
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(PKG))

FAIL: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAIL.append(msg)


# ---------------------------------------------------------------- TB1
def _box(states, env, pad):
    xs = [s.xs for s in states] + [s.xc for s in states]
    ys = [s.ys for s in states] + [s.yc for s in states]
    R = max(s.R for s in states)
    return (min(xs) - pad * R, max(xs) + pad * R, min(ys) - pad * R, max(ys) + pad * R, 0.0, env.zi)


def _face_flux(b, states, env, n=48):
    """Поток через 6 граней коробки (Гаусс–Лежандр n×n): (сумма v·n dA, сумма |v·n| dA)."""
    bm = importlib.import_module("bubble")
    g, wq = np.polynomial.legendre.leggauss(n)
    x0, x1, y0, y1, z0, z1 = b

    def nodes(a0, a1):
        return 0.5 * (a1 - a0) * g + 0.5 * (a1 + a0), 0.5 * (a1 - a0) * wq

    net = 0.0
    gross = 0.0
    X, WX = nodes(x0, x1)
    Y, WY = nodes(y0, y1)
    Z, WZ = nodes(z0, z1)
    # грани: (ось нормали, координата, знак)
    eps = 1e-9 * (z1 - z0)
    faces = [
        ("x", x0, -1), ("x", x1, +1),
        ("y", y0, -1), ("y", y1, +1),
        ("z", z0 + eps, -1), ("z", z1 - eps, +1),
    ]
    for ax, c, sgn in faces:
        if ax == "x":
            A, B = np.meshgrid(Y, Z, indexing="ij")
            W = np.outer(WY, WZ)
            p = np.stack([np.full_like(A, c), A, B], -1)
            k = 0
        elif ax == "y":
            A, B = np.meshgrid(X, Z, indexing="ij")
            W = np.outer(WX, WZ)
            p = np.stack([A, np.full_like(A, c), B], -1)
            k = 1
        else:
            A, B = np.meshgrid(X, Y, indexing="ij")
            W = np.outer(WX, WY)
            p = np.stack([A, B, np.full_like(A, c)], -1)
            k = 2
        v = bm.velocity(p, states, env)
        vn = sgn * v[..., k]
        net += float(np.sum(vn * W))
        gross += float(np.sum(np.abs(vn) * W))
    return net, gross


def tb1() -> None:
    try:
        bm = importlib.import_module("bubble")
    except Exception as e:  # noqa: BLE001
        check(False, f"tb1: import bubble: {e!r}")
        return
    for name in ("PARAMS", "Env", "Source", "State", "state", "velocity", "from_game", "from_strength", "kbar",
                 "from_game_strength", "between_q"):
        check(hasattr(bm, name), f"tb1: bubble.{name} есть")
    if FAIL:
        return
    # 1. PARAMS
    for key in ("alpha_thermal", "C_thermal", "alpha_plume", "core_flux_fraction", "hill_shell"):
        check(key in bm.PARAMS, f"tb1: PARAMS[{key!r}] есть")
    for key, d in bm.PARAMS.items():
        ok = (
            isinstance(d, dict)
            and isinstance(d.get("value"), (int, float))
            and math.isfinite(float(d["value"]))
            and isinstance(d.get("unit"), str)
            and isinstance(d.get("source"), str)
            and d["source"].strip() != ""
            and d.get("reliability") in ("high", "medium", "low")
        )
        check(ok, f"tb1: PARAMS[{key!r}] — value/unit/source/reliability")
    # 11. v3: доля ядра и оболочка
    cf = float(bm.PARAMS["core_flux_fraction"]["value"])
    hs = float(bm.PARAMS["hill_shell"]["value"])
    check(0.0 < cf <= 1.0, f"tb1 v3: 0 < core_flux_fraction {cf:.3g} ≤ 1")
    check(0.0 < hs < 1.0, f"tb1 v3: 0 < hill_shell {hs:.3g} < 1")
    # поля State
    need = ("xs", "ys", "xc", "yc", "zc", "R", "U", "Q", "F0", "zb")
    names = [f.name for f in dataclasses.fields(bm.State)]
    check(all(n in names for n in need), f"tb1: поля State {need}")
    env = bm.Env(wind=(3.0, 0.0), zi=1400.0)
    src = bm.from_game(0.0, 0.0, 0.0, 2.5, 1400.0, env)
    check(src.F0 > 0 and src.tau > 0, f"tb1: from_game → F0 {src.F0:.4g} > 0, tau {src.tau:.4g} > 0")
    # 2. state
    check(bm.state(src, env, src.t0 - 1.0) is None, "tb1: state(t < t0) is None")
    ts = [src.t0 + src.tau * f for f in (0.2, 0.5, 1.0)]
    sts = [bm.state(src, env, t) for t in ts]
    check(all(s is not None for s in sts), "tb1: state не None на (t0, t0+tau]")
    if any(s is None for s in sts):
        return
    check(all(s.R > 0 and s.U >= 0 for s in sts), "tb1: R > 0, U ≥ 0")
    check(sts[0].zc < sts[1].zc < sts[2].zc, f"tb1: zc растёт {[round(s.zc, 1) for s in sts]}")
    drift = max(
        max(abs(s.xc - (src.x + env.wind[0] * (t - src.t0))), abs(s.yc - (src.y + env.wind[1] * (t - src.t0))))
        for s, t in zip(sts, ts)
    )
    check(drift <= 1e-6, f"tb1: снос головы по ветру, ошибка {drift:.2e} м ≤ 1e-6")
    check(all(abs(s.xs - s.xc) <= 1e-9 and abs(s.ys - s.yc) <= 1e-9 for s in sts),
          "tb1 v2: ось вертикальна — xs = xc, ys = yc")
    a = sts[1]
    b = dataclasses.replace(sts[1], xs=a.xs + 3 * a.R, xc=a.xc + 3 * a.R, yc=a.yc + a.R, ys=a.ys + a.R)
    box = _box([a], env, 4.0)
    rng = np.random.default_rng(1)
    P = np.stack(
        [rng.uniform(box[0], box[1], 4000), rng.uniform(box[2], box[3], 4000), rng.uniform(1.0, env.zi - 1.0, 4000)],
        -1,
    )
    va = bm.velocity(P, [a], env)
    check(va.shape == P.shape and va.dtype == np.float64, f"tb1: velocity форма {va.shape}, {va.dtype}")
    check(bool(np.all(np.isfinite(va))), "tb1: velocity конечна")
    # 3. линейность
    vab = bm.velocity(P, [a, b], env)
    vb = bm.velocity(P, [b], env)
    lin = float(np.max(np.abs(vab - va - vb)) / max(np.max(np.abs(vab)), 1e-30))
    check(lin <= 1e-9, f"tb1: линейность {lin:.2e} ≤ 1e-9")
    # 4. земля и крышка
    wmax = float(np.max(np.abs(va[..., 2])))
    check(wmax > 0, f"tb1: max|w| = {wmax:.3g} > 0")
    neg = bm.velocity(np.array([[a.xc, a.yc, -10.0]]), [a], env)
    check(bool(np.all(neg == 0.0)), "tb1: z < 0 → 0")
    g = np.stack([P[:, 0], P[:, 1], np.zeros(len(P))], -1)
    wg = float(np.max(np.abs(bm.velocity(g, [a], env, ground=True, lid=True)[..., 2])))
    check(wg <= 1e-3 * wmax, f"tb1: |w(z=0)| {wg:.2e} ≤ 1e-3·max|w|")
    l = np.stack([P[:, 0], P[:, 1], np.full(len(P), env.zi)], -1)
    wl = float(np.max(np.abs(bm.velocity(l, [a], env, ground=True, lid=True)[..., 2])))
    check(wl <= 1e-3 * wmax, f"tb1: |w(z=zi)| {wl:.2e} ≤ 1e-3·max|w|")
    # 5. масса через коробку — на трёх стадиях
    for s, f in zip(sts, (0.2, 0.5, 1.0)):
        net, gross = _face_flux(_box([s], env, 4.0), [s], env)
        rel = abs(net) / max(gross, 1e-30)
        check(rel <= 1e-3, f"tb1: поток через коробку (t0+{f}·tau) {rel:.2e} ≤ 1e-3 (gross {gross:.3g} м³/с)")
    # 6. дивергенция в точке
    h = 1e-4 * a.R
    div = np.zeros(len(P))
    for k in range(3):
        e = np.zeros(3)
        e[k] = h
        div += (bm.velocity(P + e, [a], env)[..., k] - bm.velocity(P - e, [a], env)[..., k]) / (2 * h)
    p99 = float(np.percentile(np.abs(div), 99)) * a.R / max(a.U, 1e-30)
    check(p99 <= 1e-3, f"tb1: p99 |div|·R/U {p99:.2e} ≤ 1e-3")
    # 7. дальнее поле головы без шлейфа
    hd = dataclasses.replace(a, Q=0.0, F0=0.0, zb=a.zc)
    far = np.array([[hd.xc + 20 * hd.R, hd.yc, hd.zc], [hd.xc, hd.yc - 20 * hd.R, hd.zc]])
    vf = float(np.max(np.linalg.norm(bm.velocity(far, [hd], env), axis=-1)))
    check(vf <= 1e-2 * max(hd.U, 1e-30), f"tb1: |v| на 20R {vf:.2e} ≤ 1e-2·U ({hd.U:.3g})")
    # 8–9. v2: непрерывность во времени и конец жизни
    dt = 2.0
    t_cap = src.t0 + 4 * src.tau + 3600.0
    life = []
    t = src.t0 + dt
    while t <= t_cap:
        st = bm.state(src, env, t)
        if st is None:
            break
        life.append((t, st))
        t += dt
    ended = bm.state(src, env, t) is None
    check(ended and len(life) > 1, f"tb1 v2: конец жизни (None) к t0+{t - src.t0:.0f} с ≤ t0+4·tau+3600")
    if len(life) < 2:
        return
    rmax = max(st.R for _, st in life)
    gx = np.arange(-3 * rmax, 3 * rmax + 1e-9, 0.25 * rmax)
    gz = np.arange(1.0, env.zi - 1.0 + 1e-9, 0.25 * rmax)
    GX, GZ = np.meshgrid(gx, gz, indexing="ij")
    vmax = 0.0
    jump = 0.0
    t_jump = None
    prev = None
    last = None
    for t, st in life:
        ox = src.x + env.wind[0] * (t - src.t0)
        oy = src.y + env.wind[1] * (t - src.t0)
        G = np.stack([GX + ox, np.full_like(GX, oy), GZ], -1)
        v = bm.velocity(G, [st], env)
        m = float(np.max(np.linalg.norm(v, axis=-1)))
        vmax = max(vmax, m)
        if prev is not None:
            d = float(np.max(np.linalg.norm(v - prev, axis=-1)))
            if d > jump:
                jump, t_jump = d, t
        prev = v
        last = m
    check(jump <= 0.25 * vmax,
          f"tb1 v2: скачок за 2 с {jump:.3g} ≤ 0,25·max|v| {0.25 * vmax:.3g} (худший при t0+{(t_jump or 0) - src.t0:.0f} с)")
    check(last <= 0.05 * vmax, f"tb1 v2: перед концом max|v| {last:.3g} ≤ 0,05·max|v| {0.05 * vmax:.3g}")
    tb1_v3(bm, env, src)


def tb1_v3(bm, env, src) -> None:
    # 10. гладкость края головы
    st = bm.state(src, env, src.t0 + 0.5 * src.tau)
    hd = dataclasses.replace(st, Q=0.0, F0=0.0, zb=st.zc)
    h = 0.005 * hd.R
    x = np.arange(-2 * hd.R, 2 * hd.R + 1e-9, h)
    for name, line in (
        ("экватор", np.stack([hd.xc + x, np.full_like(x, hd.yc), np.full_like(x, hd.zc)], -1)),
        ("ось", np.stack([np.full_like(x, hd.xc), np.full_like(x, hd.yc), np.clip(hd.zc + x, 0.5, env.zi - 0.5)], -1)),
    ):
        w = bm.velocity(line, [hd], env)[..., 2]
        k = float(np.max(np.abs(w[2:] - 2 * w[1:-1] + w[:-2]))) / h * hd.R / max(hd.U, 1e-30)
        check(k <= 1.2, f"tb1 v4: гладкость края головы ({name}) max|Δ²w|/h·R/U {k:.3g} ≤ 1,2")
    # 12. from_strength
    zl, tau = 1400.0, 690.0
    zz = np.arange(1.0, env.zi + 1e-9, 5.0)
    for w0 in (2.0, 4.0):
        s2 = bm.from_strength(0.0, 0.0, 0.0, w0, zl, tau, env)
        wm = 0.0
        t = s2.t0 + 10.0
        while t <= s2.t0 + 4 * s2.tau + 3600.0:
            st2 = bm.state(s2, env, t)
            if st2 is None:
                break
            ax = np.stack([np.full_like(zz, st2.xc), np.full_like(zz, st2.yc), zz], -1)
            wm = max(wm, float(np.max(bm.velocity(ax, [st2], env)[..., 2])))
            t += 10.0
        rel = abs(wm - w0) / w0
        check(rel <= 0.02, f"tb1 v3: from_strength(w0={w0}) — max w на оси {wm:.4g}, отн. {rel:.2e} ≤ 2e-2")
    # 13. kbar
    kb = bm.kbar(zl, tau, env, 2.5)
    check(isinstance(kb, float) and math.isfinite(kb) and kb > 0, f"tb1 v4: kbar(1400, 690, w0=2,5) = {kb!r} > 0")
    # 14. from_game_strength (v5)
    w0 = 1.2436 * 2.56
    sg = bm.from_game_strength(0.0, 0.0, 0.0, w0, 1400.0, 690.0, env)
    f_exp = 0.371 * 2.56 ** 3 * 1400.0 / 8.5
    rel = abs(sg.F0 - f_exp) / f_exp
    cff = bm.PARAMS["core_flux_fraction"]["value"]
    rel_c = abs(sg.F0 - cff * 2.56 ** 3 * 1400.0 / 8.5) / sg.F0
    check(rel_c <= 1e-12, f"tb1 v5: from_game_strength F0 = core_flux_fraction·w*³·z_l/8,5, отн. {rel_c:.1e} ≤ 1e-12")
    check(rel <= 2e-3 and sg.tau == 690.0, f"tb1 v5: F0 = 0,371·2,56³·1400/8,5 (число 0,371 округлено: отн. {rel:.1e} ≤ 2e-3), tau = 690")
    # 15. between_q (v5)
    q = np.array([bm.between_q(i / 20.0) for i in range(21)])
    mean = float(np.sum(q[1:] + q[:-1]) * 0.5 / 20.0)
    check(q.size == 21 and np.isfinite(q).all() and abs(mean - 1.0) <= 1e-6, f"tb1 v5: between_q 21 узел, среднее {mean:.9f} (|−1| ≤ 1e-6), конечно")


# ---------------------------------------------------------------- TB4
def tb4() -> None:
    root = PKG.parents[2]
    air = root / "rust" / "dp-air"

    def has(rel: str, *needles: str) -> None:
        f = air / rel
        txt = f.read_text() if f.is_file() else ""
        for n in needles:
            check(n in txt, f"tb4: {rel}: {n!r}")

    v3 = "v3" in sys.argv[1:]
    if v3:
        # v3 (круг 3): шаблон по умолчанию, флага нет
        txt = (air / "src/terms/thermal/cfg.rs").read_text()
        check("bubble_template" not in txt, "tb4 v3: флага bubble_template в cfg.rs нет")
        has("src/terms/thermal/cfg.rs", "bubble_radius_m", "/thermal/bubble_radius_m")
        has("tests/thermal_bubble_embed.rs", "fn port_vs_python", "fn table_accuracy", "table_max_rel=", "fn bubble_cache_budget",
            "build_ms_per_s=", "fn bubble_sum", "fn no_table_profile", "fn cloud_suck", "fn between_q_used",
            "fn bubble_on_core_axis", "core_axis_dx_over_r=")
        txt = (air / "tests/thermal_bubble_embed.rs").read_text()
        check("fn flag_off_bitwise" not in txt, "tb4 v3: flag_off_bitwise удалён")
        check(not (air / "tests" / "data" / "thermal_bubble_off.json").exists(), "tb4 v3: tests/data/thermal_bubble_off.json удалён")
        has("src/terms/slots.rs", "pub uh: [f64; 2]")
        has("src/terms/thermal/mod.rs", "pub mod bubble;")
        has("src/terms/thermal/bubble.rs", "BubbleTable")
        return
    has("src/terms/thermal/cfg.rs", "bubble_template", "/thermal/bubble_template")
    has("src/terms/slots.rs", "pub uh: [f64; 2]")
    has("src/terms/thermal/mod.rs", "pub mod bubble;")
    has("src/terms/thermal/bubble.rs", "BubbleTable")
    has("tests/thermal_bubble_embed.rs", "fn flag_off_bitwise", "fn port_vs_python", "fn table_accuracy",
        "fn flag_on_sum", "table_max_rel=")
    if "v2" in sys.argv[1:]:
        has("src/terms/thermal/cfg.rs", "bubble_radius_m", "/thermal/bubble_radius_m")
        has("tests/thermal_bubble_embed.rs", "fn bubble_cache_budget", "build_ms_per_s=", "fn no_table_no_w")
    check((air / "tests" / "data" / "thermal_bubble_off.json").is_file(), "tb4: tests/data/thermal_bubble_off.json есть")


# ---------------------------------------------------------------- TB2
def tb2() -> None:
    try:
        cm = importlib.import_module("current")
    except Exception as e:  # noqa: BLE001
        check(False, f"tb2: import current: {e!r}")
        return
    cfg = {
        "ring_sink_factor": 1.6,
        "profile_cutoff_radii": 2.5,
        "radius_min_factor": 0.45,
        "ground_ramp_m": 150.0,
        "top_taper_m": 120.0,
    }
    top, R, w0 = 1400.0, 107.0, 3.1
    p = np.array([[0.0, 0.0, 700.0]])
    w = float(cm.current_w(p, src=(0.0, 0.0), top=top, R=R, w0=w0, cfg=cfg)[0])
    check(abs(w - w0) <= 1e-9 * w0, f"tb2: ось, ξ = 0,5: w {w:.6g} = w0 {w0}")
    xi = 0.5
    r = R * max(0.45, xi ** (1 / 3) * (1 - 0.25 * xi) / 0.75)
    p1 = np.array([[r, 0.0, 700.0]])
    w1 = float(cm.current_w(p1, src=(0.0, 0.0), top=top, R=R, w0=w0, cfg=cfg)[0])
    check(abs(w1) <= 1e-9, f"tb2: x = 1: w {w1:.2e} = 0")
    p2 = np.array([[0.0, 0.0, 50.0]])
    w2 = float(cm.current_w(p2, src=(0.0, 0.0), top=top, R=R, w0=w0, cfg=cfg)[0])
    check(abs(w2 - w0 * (50 / 150) ** (1 / 3)) <= 1e-9 * w0, f"tb2: разгон у земли dh = 50: {w2:.6g}")
    p3 = np.array([[0.0, 0.0, -5.0], [0.0, 0.0, 0.0]])
    w3 = cm.current_w(p3, src=(0.0, 0.0), top=top, R=R, w0=w0, cfg=cfg)
    check(w3.shape == (2,) and bool(np.all(w3 == 0.0)), "tb2: dh ≤ 0 → 0, форма (...)")


# ---------------------------------------------------------------- TB3
COMPARE_Q = (
    "w_core_max_over_wstar",
    "core_radius_over_zi",
    "rise_speed_over_wstar",
    "inflow_ground_over_wstar",
    "outflow_top_over_wstar",
    "ring_sink_min_over_wstar",
    "updraft_area_fraction",
)


def _num_or_null(x) -> bool:
    return x is None or (isinstance(x, (int, float)) and math.isfinite(float(x)))


def tb3(path: Path) -> None:
    try:
        d = json.loads(path.read_text())
    except Exception as e:  # noqa: BLE001
        check(False, f"tb3: {path}: чтение json: {e!r}")
        return
    fmt = d.get("format")
    check(d.get("version") == 1, f"tb3: {path.name}: version 1")
    if fmt == "tb-compare":
        check(isinstance(d.get("case"), dict), f"tb3: {path.name}: case")
        rows = d.get("rows")
        check(isinstance(rows, list), f"tb3: {path.name}: rows — список")
        rows = rows or []
        keys = ("quantity", "unit", "bubble", "current", "literature", "lit_range", "source", "note")
        for r in rows:
            ok = all(k in r for k in keys) and all(_num_or_null(r[k]) for k in ("bubble", "current", "literature"))
            lr = r.get("lit_range")
            ok = ok and (lr is None or (isinstance(lr, list) and len(lr) == 2 and all(_num_or_null(x) for x in lr)))
            check(ok, f"tb3: {path.name}: строка {r.get('quantity')!r} — поля и типы")
        have = {r.get("quantity") for r in rows}
        for q in COMPARE_Q:
            check(q in have, f"tb3: {path.name}: quantity {q}")
        dv = d.get("div") or {}
        check(all(_num_or_null(dv.get(k)) and dv.get(k) is not None for k in ("p99_rel", "flux_rel")),
              f"tb3: {path.name}: div.p99_rel, div.flux_rel")
        figs = d.get("figures")
        check(isinstance(figs, list) and len(figs) > 0, f"tb3: {path.name}: figures непуст")
    elif fmt == "tb-bench":
        check(isinstance((d.get("machine") or {}).get("cpu"), str), f"tb3: {path.name}: machine.cpu")
        check(d.get("profile") == "release", f"tb3: {path.name}: profile release")
        ns = d.get("ns_per_point") or {}
        for k in ("current_contribution", "current_sample", "bubble_analytic"):
            check(isinstance(ns.get(k), (int, float)) and ns[k] > 0, f"tb3: {path.name}: ns_per_point.{k} > 0")
        check(_num_or_null(ns.get("bubble_table")), f"tb3: {path.name}: ns_per_point.bubble_table число|null")
        check(isinstance(d.get("bubbles_per_point"), (int, float)), f"tb3: {path.name}: bubbles_per_point")
        tb = d.get("table_bytes")
        check(tb is None or isinstance(tb, int), f"tb3: {path.name}: table_bytes int|null")
        e = d.get("port_max_rel_err")
        check(isinstance(e, (int, float)) and math.isfinite(e), f"tb3: {path.name}: port_max_rel_err")
    elif fmt == "tb-les":
        rows = d.get("rows")
        check(isinstance(rows, list), f"tb3: {path.name}: rows — список")
        rows = rows or []
        for r in rows:
            ok = all(k in r for k in ("quantity", "unit", "literature", "lit_range", "source", "note", "reliability"))
            ok = ok and _num_or_null(r.get("literature")) and r.get("reliability") in ("high", "medium", "low")
            lr = r.get("lit_range")
            ok = ok and (lr is None or (isinstance(lr, list) and len(lr) == 2 and all(_num_or_null(x) for x in lr)))
            check(ok, f"tb3: {path.name}: строка {r.get('quantity')!r} — поля и типы")
        have = {r.get("quantity") for r in rows}
        for q in ("inflow_ground_over_wstar", "outflow_top_over_wstar", "ring_sink_min_over_wstar", "rise_speed_over_wstar"):
            check(q in have, f"tb3: {path.name}: quantity {q}")
        check(isinstance(d.get("searched"), list), f"tb3: {path.name}: searched — список")
    else:
        check(False, f"tb3: {path.name}: неизвестный format {fmt!r}")


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    for a in argv:
        if a == "tb1":
            tb1()
        elif a == "tb2":
            tb2()
        elif a == "tb4":
            tb4()
        elif a in ("v2", "v3"):
            pass
        else:
            tb3(Path(a))
    print(f"\n{'PASS' if not FAIL else 'FAIL'}: нарушений {len(FAIL)}")
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
