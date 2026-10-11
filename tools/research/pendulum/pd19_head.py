"""PD-19: голова поперёк в болтанке — эталон test_pendulum_head.gd (PROTO_CM) на прототипе в той же
постановке, что тест: GameSim, блок reference.json, поле reference.json → turbulence, пилот мягко держит
горизонт (BankHold 1,5/0,8/0,3), 40 с, первые 10 с пропуск, СКО в полосе 0,3–3 Гц (ДПФ, бины k/T).
Отклик хаотичен — по шагам 1/120, 1/100, 1/60, 1/30 и среднее (как эталон болтанки PD-14).

  python tools/research/pendulum/pd19_head.py
"""
import json
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as X  # noqa: E402
from pendulum.scenarios import BankHold, _head_world  # noqa: E402

REF = json.loads((X.ROOT / "tests/flight/pendulum/reference.json").read_text())


def band_std(x, dt, lo=0.3, hi=3.0):
    x = np.asarray(x) - np.mean(x)
    n = len(x)
    T = n * dt
    F = np.fft.fft(x)
    k = np.arange(int(np.ceil(lo * T)), int(np.floor(hi * T)) + 1)
    return float(np.sqrt((2.0 * np.abs(F[k]) ** 2 / (n * n)).sum()))


def run(a):
    w, hz = a
    dt = 1 / hz
    s = X.make(w, REF["blocks"][w], dt=dt)
    s.air_fn = X.turbulence_fn(REF["turbulence"])
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    o = s.observe()
    hy = []
    for i in range(int(round(40.0 / dt))):
        s.step(hold(0.0, o))
        o = s.observe()
        if o["t"] > 10.0:
            hb = s.R.T @ (_head_world(s) - s.hang_world())
            hy.append(hb[1])
    return w, hz, band_std(hy, dt) * 100


if __name__ == "__main__":
    plan = [(w, hz) for w in ("training", "laminar", "sport") for hz in (120, 100, 60, 30)]
    res = {}
    with ProcessPoolExecutor(8) as ex:
        for w, hz, v in ex.map(run, plan):
            res.setdefault(w, {})[hz] = v
    for w, d in res.items():
        print(w, {k: round(v, 2) for k, v in d.items()}, "среднее", round(float(np.mean(list(d.values()))), 2))
