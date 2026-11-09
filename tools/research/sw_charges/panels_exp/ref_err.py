"""SWC-16 (2): погрешность эталона Пикара P50 по сходимости сетки. P25 нет → P100 против P50 и P200 против P100 через
консервативное осреднение (2x2 дочерних клетки, все воздух) без интерполяции. Пишет out/panels2d/tunnel/picard_err.json."""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C


def restrict(a_fine, air_fine, nzc, nxc):
    """Сетка F1: грань z0_c = 2*z0_f.. клетка K крупной = дочерние k=2K-1, 2K; i=2I, 2I+1. Возвращает (среднее, маска все-воздух)."""
    out = np.full((nzc, nxc), np.nan)
    ok = np.zeros((nzc, nxc), bool)
    for K in range(1, nzc):
        if 2 * K >= a_fine.shape[0]:
            break
        sl = slice(2 * K - 1, 2 * K + 1)
        a = a_fine[sl, :2 * nxc].reshape(2, nxc, 2)
        m = air_fine[sl, :2 * nxc].reshape(2, nxc, 2)
        ok[K] = m.all(axis=(0, 2))
        out[K] = np.where(ok[K], a.mean(axis=(0, 2)), np.nan)
    return out, ok


def main():
    from run_cc import cc_points
    res = {}
    for case in ("C1", "C2", "C4"):
        P = {dx: C.Picard(case, dx) for dx in (200, 100, 50)}
        p50, p100, p200 = P[50], P[100], P[200]
        U10 = float(p50.cp["U10"])
        r_50_100, ok1 = restrict(p50.uc, p50.air, p100.uc.shape[0], p100.uc.shape[1])
        r_100_200, ok2 = restrict(p100.uc, p100.air, p200.uc.shape[0], p200.uc.shape[1])
        m1 = ok1 & p100.air
        m2 = ok2 & p200.air
        # агл центра P100 клетки (по колонке P100)
        agl100 = p100.zc[:, None] - p100.h[None, :]
        agl200 = p200.zc[:, None] - p200.h[None, :]
        near1 = m1 & (agl100 < 100)
        near2 = m2 & (agl200 < 100)
        e1 = (p100.uc - r_50_100); e2 = (p200.uc - r_100_200)
        def rms(e, m): return float(np.sqrt(np.nanmean(e[m] ** 2)))
        bulk = dict(n1=int(m1.sum()), n2=int(m2.sum()), E100_50=rms(e1, m1) / U10, E200_100=rms(e2, m2) / U10,
                    E100_50_near=rms(e1, near1) / U10, E200_100_near=rms(e2, near2) / U10)
        bulk["p"] = float(np.log2(bulk["E200_100"] / bulk["E100_50"]))
        bulk["p_near"] = float(np.log2(bulk["E200_100_near"] / bulk["E100_50_near"]))
        # точки SW7
        cpts = cc_points(p50, case, p50.cp)
        pts = []
        for q in cpts:
            I, K = q["i"] // 2, (q["k"] + 1) // 2
            ok = bool(m1[K, I])
            u50 = float(p50.uc[q["k"], q["i"]])
            ucell = float(r_50_100[K, I]) if ok else None
            d = float(p100.uc[K, I] - r_50_100[K, I]) if ok else None
            pts.append(dict(name=q["name"], zagl=q["zagl"], u50=u50, u50_cellmean=ucell, u100=float(p100.uc[K, I]), diff_100_50=d,
                            rel=(abs(d) / max(abs(ucell), 0.3 * U10) if ok else None)))
        # доля по группам высот
        g = {}
        for lab, lo, hi in (("нижняя клетка (<12.5 м)", 0, 12.6), ("12.5-25 м", 12.6, 25), ("~50 м", 25, 100), ("~300 м", 100, 1e9)):
            r = [p["rel"] for p in pts if p["rel"] is not None and lo <= p["zagl"] < hi]
            g[lab] = dict(n=len(r), median=float(np.median(r)) if r else None, max=float(np.max(r)) if r else None)
        res[case] = dict(U10=U10, bulk=bulk, points=pts, groups=g)
        print(case, {k: (round(v, 4) if isinstance(v, float) else v) for k, v in bulk.items()})
        for k, v in g.items(): print("  ", k, v)
    json.dump(res, open(os.path.join(C.OUT, "tunnel", "picard_err.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
