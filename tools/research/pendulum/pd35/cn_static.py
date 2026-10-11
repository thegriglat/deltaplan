"""PD-35: статические C_N, C_L, C_D крыла прототипа (GameSim) по углу атаки 20…90° — поток вдоль x мира,
киль под углом a, без вращения. Печатает строку на крыло и угол. Запуск: $PY cn_static.py"""
import json, math, sys
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import export_reference as er
from pendulum.model import R_from_euler, Sim

for wing in ["training", "apogee", "laminar", "sport"]:
    blk = json.loads((er.ROOT / f"configs/wings/{wing}.json").read_text())["pendulum"]
    s = er.make(wing, blk)
    p = s.p
    q = 0.5 * p.rho * p.area
    row = []
    for d in (20, 30, 45, 60, 75, 90):
        a = math.radians(d)
        R = R_from_euler(0.0, a, 0.0)
        F, _, _ = Sim.wing_aero(s, np.zeros(3), np.array([1.0, 0.0, 0.0]), R, np.zeros(3))
        if s._r0 is not None:
            s.r_strip_b = s._r0
        Fb = R.T @ F
        row.append(f"{d}°: CN {-Fb[2]/q:.2f} CL {-F[2]/q:.2f} CD {-F[0]/q:.2f}")
    print(wing, f"Λ {math.degrees(p.sweep):.1f}", " | ".join(row))
