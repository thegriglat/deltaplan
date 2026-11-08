"""Время шага sim3d на N ≈ 5000 панелей и ~2000 узлов нитей (хребет Agnesi H/L 0,5, сход каждый шаг).
Запуск: ./py sim3d/bench.py [шагов]."""
import sys
import numpy as np
import panels3d as P
import sim3d


def main(steps=45):
    a, H = 250.0, 125.0
    x = np.arange(-2000, 2001, 20.0)
    y = np.arange(-300, 301, 20.0)
    X, Y = np.meshgrid(x, y)
    t = P.Terrain3D(x, y, H / (1 + (X / a) ** 2), far_m=6000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 50.0) for yy in (-120.0, 0.0, 120.0)]
    p = P.build_panels(t, focus=foc, ds_min=20.0, focus_r=100, ds_max=800, growth=1.5)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    st = sim3d.Setup(t, p, bg, 0.1, dict(fil=dict(bounds=(-2000.0, 900.0, -300.0, 300.0, 600.0))))
    print(f"N панелей {p.N}, backend {st.infl.backend}, сборка {st.infl.t_assemble_s:.2f} с")
    r = sim3d.run(st, float(steps), 1.0)
    S = r["stats"]
    print("| t | узлов | отрезков | подшагов | время шага, с |")
    print("|---|---|---|---|---|")
    for s in S[:: max(1, len(S) // 10)]:
        print(f"| {s['t']:.0f} | {s['n_nodes']} | {s['n_seg']} | {s['substeps']} | {s['t_step']:.2f} |")
    j = int(np.argmin([abs(s["n_nodes"] - 2000) for s in S]))
    print(f"≈2000 узлов: t={S[j]['t']:.0f}, узлов {S[j]['n_nodes']}, шаг {S[j]['t_step']:.2f} с, подшагов {S[j]['substeps']}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 45)
