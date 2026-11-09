#!/usr/bin/env python3
"""Фикстура бенча TB-3: State пузыря в разные моменты жизни и ожидаемые bubble.velocity.

Пишет out/bench_fixture.json; читает его rust/dp-air/benches/thermal_bubble.rs (порт velocity в Rust, сверка и замеры).
Вход как у игры: from_game(0, 0, 0, w* = 2,5 м/с, z_l = 1400 м, Env(wind=(3, 0), zi=1400)).
Системный python3 + numpy:  python3 tools/research/thermal_bubble/bench_fixture.py
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

WSTAR, ZL = 2.5, 1400.0
ENV = bb.Env(wind=(3.0, 0.0), zi=1400.0)
CASE_TIMES = [30.0, 120.0, 400.0, 690.0, 800.0, 1000.0, 1700.0]   # моменты жизни: рост, зрелость, отрыв, распад
POP_STEP = 100.0                                                   # население: возраст через 100 с по всей жизни


def sd(st: bb.State) -> dict:
    return {k: float(v) for k, v in dataclasses.asdict(st).items()}


def points_for(st: bb.State, rng: np.random.Generator, n: int) -> np.ndarray:
    """Точки: у головы, у шлейфа, по коробке; z строго внутри (0, zi)."""
    n_h, n_p = int(n * 0.4), int(n * 0.3)
    n_b = n - n_h - n_p
    d = rng.normal(size=(n_h, 3))
    d /= np.linalg.norm(d, axis=1)[:, None]
    h = np.array([st.xc, st.yc, st.zc]) + d * (rng.uniform(0.2, 3.0, n_h) * st.R)[:, None]
    ang = rng.uniform(0, 2 * np.pi, n_p)
    rho = rng.uniform(0.0, 2.5, n_p) * max(st.b0, 30.0)
    zt = max(st.zc - st.R, st.zb + 1.0)
    pz = rng.uniform(max(st.zb, 1.0), max(zt, st.zb + 2.0), n_p)
    pl = np.stack([st.xc + rho * np.cos(ang), st.yc + rho * np.sin(ang), pz], axis=1)
    bx = np.stack([st.xc + rng.uniform(-1000, 1000, n_b), st.yc + rng.uniform(-1000, 1000, n_b),
                   rng.uniform(1.0, ENV.zi - 1.0, n_b)], axis=1)
    p = np.concatenate([h, pl, bx])
    p[:, 2] = np.clip(p[:, 2], 1.0, ENV.zi - 1.0)
    return p


def main() -> int:
    rng = np.random.default_rng(20261109)
    src = bb.from_game(0.0, 0.0, 0.0, WSTAR, ZL, ENV)
    cases = []
    for t in CASE_TIMES:
        st = bb.state(src, ENV, t)
        assert st is not None, t
        p = points_for(st, rng, 70)
        cases.append({"name": f"t{int(t)}", "t": t, "states": [sd(st)], "points": p.tolist(),
                      "v": bb.velocity(p, [st], ENV).tolist()})
    # сумма двух пузырей рядом (линейность и вклад соседа)
    a, b = bb.state(src, ENV, 400.0), bb.state(src, ENV, 690.0)
    b = dataclasses.replace(b, xs=b.xc + 300.0, xc=b.xc + 300.0, yc=b.yc + 150.0, ys=b.yc + 150.0)
    p = np.concatenate([points_for(a, rng, 25), points_for(b, rng, 25)])
    cases.append({"name": "pair", "t": 0.0, "states": [sd(a), sd(b)], "points": p.tolist(),
                  "v": bb.velocity(p, [a, b], ENV).tolist()})
    tr = bb._traj(src, ENV)
    pop = []
    t = POP_STEP / 2
    while t < tr.t_end:
        st = bb.state(src, ENV, t)
        if st is not None:
            pop.append(sd(st))
        t += POP_STEP
    out = {"format": "tb-bench-fixture", "version": 1,
           "env": {"wind": list(ENV.wind), "zi": ENV.zi, "ground": True, "lid": True},
           "game": {"wstar": WSTAR, "zl": ZL, "n_allen": 8.5 / ZL ** 2, "t_end": float(tr.t_end)},
           "cases": cases, "population": pop}
    dest = here / "out" / "bench_fixture.json"
    dest.parent.mkdir(exist_ok=True)
    tmp = dest.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(out))
    os.replace(tmp, dest)
    print(f"{dest}: {sum(len(c['points']) for c in cases)} точек, население {len(pop)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
