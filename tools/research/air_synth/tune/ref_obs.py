"""Шаг 1: эталонные наблюдаемые на реальных квадратах. Запуск: ../corpus/.venv/bin/python ref_obs.py
-> out/ref_obs.json (по квадратам: detail 4, far 64; сравнение detail/far на одном квадрате; разброс)."""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terrain_stats"))
import dem  # noqa: E402
import observables as ob  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
C = (400 - ob.N) // 2  # 8: центральная обрезка 400 -> 384 клетки


def squares():
    for place in dem.PLACES:
        hd, _, _ = dem.load(place, "detail")
        hf, _, _ = dem.load(place, "far")
        d100 = dem.coarsen(hd, 4)  # 400x400
        yield f"{place}/detail", "detail", place, d100[C:C + ob.N, C:C + ob.N]
        yield f"{place}/far_center", "far_center", place, hf[600 + C:600 + C + ob.N, 600 + C:600 + C + ob.N]
        for i in range(4):
            for j in range(4):
                yield f"{place}/far_{i}{j}", "far", place, hf[i * 400 + C:i * 400 + C + ob.N, j * 400 + C:j * 400 + C + ob.N]


def one(a):
    name, kind, place, z = a
    return dict(name=name, kind=kind, place=place, obs=ob.observables(z))


if __name__ == "__main__":
    from multiprocessing import Pool
    os.makedirs(OUT, exist_ok=True)
    with Pool(6) as p:
        R = p.map(one, list(squares()))
    far = [r for r in R if r["kind"] == "far"]
    det = [r for r in R if r["kind"] == "detail"]
    cen = [r for r in R if r["kind"] == "far_center"]
    V = lambda rs: np.array([[r["obs"][n] for n in ob.NAMES] for r in rs], float)
    F, D, Cn = V(far), V(det), V(cen)
    S = dict(names=ob.NAMES, squares=R,
             far_mean=np.nanmean(F, 0).tolist(), far_std=np.nanstd(F, 0, ddof=1).tolist(),
             detail_minus_far_center=dict(mean=np.nanmean(D - Cn, 0).tolist(), std=np.nanstd(D - Cn, 0, ddof=1).tolist(),
                                          per_place=(D - Cn).tolist()))
    json.dump(S, open(os.path.join(OUT, "ref_obs.json"), "w"), indent=1)
    print(f"{'obs':16s} {'far mean':>9s} {'far std':>8s} {'det-far mean':>12s} {'sd':>7s}")
    for n, m, s, dm, ds in zip(ob.NAMES, S["far_mean"], S["far_std"], S["detail_minus_far_center"]["mean"], S["detail_minus_far_center"]["std"]):
        print(f"{n:16s} {m:9.3f} {s:8.3f} {dm:12.3f} {ds:7.3f}")
