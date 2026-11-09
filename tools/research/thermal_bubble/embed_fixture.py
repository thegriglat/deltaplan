#!/usr/bin/env python3
"""Фикстура встраивания TB-8 (TB4 v2): шаблон v4 — from_strength при разных (w0, zl, tau), State в стадиях жизни,
голова с оболочкой ψ, точки и ожидаемые bubble.velocity.

Пишет out/embed_fixture.json; читает rust/dp-air/tests/thermal_bubble_embed.rs (port_vs_python: velocity — отн. <= 1e-5,
F0 from_strength — отн. <= 1e-3, state — отн. <= 1e-5). out/bench_fixture.json (v2, для бенча) не трогает.
Системный python3 + numpy:  python3 tools/research/thermal_bubble/embed_fixture.py
"""
from __future__ import annotations

import dataclasses
import json
import os
import sys
from pathlib import Path

import numpy as np

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import bubble as bb  # noqa: E402

# (w0 — сила термика игры, м/с; zl — столб, м; tau — работа источника, с; моменты жизни, с)
SCENES = [
    (3.1, 1400.0, 690.0, [30.0, 120.0, 400.0, 690.0, 800.0, 1000.0, 1700.0]),
    (2.0, 1000.0, 500.0, [60.0, 300.0, 520.0, 900.0]),
    (4.0, 2000.0, 690.0, [150.0, 500.0, 760.0, 1200.0]),
    (1.6, 700.0, 400.0, [40.0, 200.0, 450.0]),
]


def sd(st: bb.State) -> dict:
    return {k: float(v) for k, v in dataclasses.asdict(st).items()}


def points_for(st: bb.State, zi: float, rng: np.random.Generator, n: int) -> np.ndarray:
    """Точки: у головы (в том числе в оболочке 0,9R…1,1R), у шлейфа, по коробке; z строго внутри (0, zi)."""
    n_h, n_s, n_p = int(n * 0.3), int(n * 0.15), int(n * 0.25)
    n_b = n - n_h - n_s - n_p
    d = rng.normal(size=(n_h, 3))
    d /= np.linalg.norm(d, axis=1)[:, None]
    h = np.array([st.xc, st.yc, st.zc]) + d * (rng.uniform(0.2, 3.0, n_h) * st.R)[:, None]
    d = rng.normal(size=(n_s, 3))
    d /= np.linalg.norm(d, axis=1)[:, None]
    sh = np.array([st.xc, st.yc, st.zc]) + d * (rng.uniform(0.88, 1.12, n_s) * st.R)[:, None]
    ang = rng.uniform(0, 2 * np.pi, n_p)
    rho = rng.uniform(0.0, 2.5, n_p) * max(st.b0, 30.0)
    zt = max(st.zc - st.R, st.zb + 1.0)
    pz = rng.uniform(max(st.zb, 1.0), max(zt, st.zb + 2.0), n_p)
    pl = np.stack([st.xc + rho * np.cos(ang), st.yc + rho * np.sin(ang), pz], axis=1)
    bx = np.stack([st.xc + rng.uniform(-1000, 1000, n_b), st.yc + rng.uniform(-1000, 1000, n_b),
                   rng.uniform(1.0, zi - 1.0, n_b)], axis=1)
    p = np.concatenate([h, sh, pl, bx])
    p[:, 2] = np.clip(p[:, 2], 1.0, zi - 1.0)
    return p


def main() -> int:
    rng = np.random.default_rng(20261110)
    cases, strengths, sources = [], [], []
    for si, (w0, zl, tau, times) in enumerate(SCENES):
        env = bb.Env(zi=zl)
        src = bb.from_strength(0.0, 0.0, 0.0, w0, zl, tau, env)
        sources.append({"w0": w0, "zl": zl, "tau": tau, "F0": src.F0, "b0": src.b0, "t_decay": src.t_decay,
                        "zh": src.zh, "t_end": float(bb._traj(src, env).t_end)})
        strengths.append({"w0": w0, "zl": zl, "tau": tau, "F0": src.F0})
        for t in times:
            st = bb.state(src, env, t)
            assert st is not None, (si, t)
            p = points_for(st, zl, rng, 80)
            cases.append({"name": f"s{si}_t{int(t)}", "scene": si, "t": t, "zi": zl, "states": [sd(st)],
                          "points": p.tolist(), "v": bb.velocity(p, [st], env).tolist()})
    # два пузыря рядом (линейность суммы)
    w0, zl, tau, _ = SCENES[0]
    env = bb.Env(zi=zl)
    src = bb.from_strength(0.0, 0.0, 0.0, w0, zl, tau, env)
    a, b = bb.state(src, env, 400.0), bb.state(src, env, 690.0)
    b = dataclasses.replace(b, xs=b.xc + 300.0, xc=b.xc + 300.0, yc=b.yc + 150.0, ys=b.yc + 150.0)
    p = np.concatenate([points_for(a, zl, rng, 40), points_for(b, zl, rng, 40)])
    cases.append({"name": "pair", "scene": 0, "t": 0.0, "zi": zl, "states": [sd(a), sd(b)],
                  "points": p.tolist(), "v": bb.velocity(p, [a, b], env).tolist()})
    out = {"format": "tb-embed-fixture", "version": 1, "sources": sources, "from_strength": strengths, "cases": cases}
    dest = here / "out" / "embed_fixture.json"
    dest.parent.mkdir(exist_ok=True)
    tmp = dest.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(out))
    os.replace(tmp, dest)
    print(f"{dest}: {sum(len(c['points']) for c in cases)} точек, {len(cases)} случаев, {len(sources)} источников")
    return 0


if __name__ == "__main__":
    sys.exit(main())
