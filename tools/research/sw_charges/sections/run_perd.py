"""SWC-9: разрез PERD (Perdigão, NE-случай 27.04.2017): слой Рипа вдоль ветра через гребни tse13 и tse04.
Запуск: tools/research/cascade_2d/py tools/research/sw_charges/sections/run_perd.py
Выход: out/sections/perd.csv, perd_profiles.npz, perd_*.png; сырьё SW1–SW3 в ~/data/sw_charges/sections/PERD_*.
"""
import csv
import math
import os
import sys

import numpy as np
from scipy.ndimage import map_coordinates

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_sections as RS  # noqa: E402
REPO = RS.REPO
sys.path.insert(0, os.path.join(REPO, "tools", "research", "cases"))
import perdigao as PD  # noqa: E402
from swpy import case as swcase, solver, io as swio  # noqa: E402

ALPHA, F_COR = PD.NOM["alpha"], PD.F_COR
L_LINE = 8000.0


def main():
    ci = PD.case_inputs("ne")
    wdir = ci["wdir"]
    ms = PD.masts()
    x0g, y0g, n, hc = PD.terrain(10.0, 9000.0)       # hc[iy, ix], y на север
    ex, ny_ = math.sin(math.radians(wdir)), math.cos(math.radians(wdir))   # орт «откуда» (на NE-сторону)
    # s вдоль орта «откуда»; поток идёт к убыванию s. x = -(s - s_mid)
    def s_of(name):
        return ms[name]["x"] * ex + ms[name]["y"] * ny_
    def perp(name):
        return ms[name]["x"] * ny_ - ms[name]["y"] * ex      # смещение от линии через tse13 (вправо от орта)
    s_mid = 0.5 * (s_of("tse13") + s_of("tse04"))
    p0 = ms["tse13"]["x"] * ny_ - ms["tse13"]["y"] * ex
    # линия через точку на полпути между проекциями гребней, проходящая через tse13
    sk = np.arange(-L_LINE / 2, L_LINE / 2, 10.0) + 5.0
    xs_line = -sk                                   # координата слоя (вдоль потока)
    s_abs = s_mid + sk * (-1.0)                     # s = s_mid - xline_rel ; x_rel = -(s - s_mid)
    # точка линии: s_abs·орт + p0·перпендикуляр
    px = s_abs * ex + p0 * ny_
    py = s_abs * ny_ - p0 * ex
    ix = (px - x0g) / 10.0 - 0.5
    iy = (py - y0g) / 10.0 - 0.5
    z = map_coordinates(hc, [iy, ix], order=1, mode="nearest")
    z -= z.min()
    x_fine = -(s_abs - s_mid)                       # вдоль потока, м от середины
    # положения мачт на линии
    pos = {k: -(s_of(k) - s_mid) for k in ("tse13", "tse04", "tse09", "tse10", "tse12", "tse11", "tse06")}
    # R1: U100 на гребне -> U10 (alpha NOM), z_sat по u*, h
    U100 = ci["u100"]
    U10 = U100 * 10 ** (-ALPHA) * 1.0
    z0 = PD.z0_nominal()
    ustar = 0.4 * U10 / math.log(10 / z0)
    hmech = 0.3 * ustar / F_COR
    zsat = 0.3 * hmech
    ualoft = U10 * (zsat / 10) ** ALPHA
    print(f"wdir {wdir:.1f} U100 {U100} U10 {U10:.2f} u* {ustar:.3f} z_sat {zsat:.0f} U_aloft {ualoft:.2f}; "
          f"перп. смещение tse04 от линии: {perp('tse04') - perp('tse13'):.0f} м; позиции {pos}")
    rows, prof = [], {}
    obs = {"tse09_100": 2.8354, "tse13_100": 8.791, "tse04_100": 7.8573}
    for h0 in (2500.0, 1000.0):
        for dxs in (400.0, 200.0):
            k = int(round(dxs / 10.0))
            nx = int(L_LINE / dxs)
            zb = z[: nx * k].reshape(nx, k).mean(axis=1)
            U0, _ = RS.r1_u0(U10, ALPHA, ualoft, h0)
            b0 = (U0 / 0.1) ** 2 / h0
            cd = RS.r1_cd(h0)
            name = f"PERD_cap_h{int(h0)}_sw{int(dxs)}"
            meta, arrays = swcase.make_case(name, shape="flat", dim=1, nx=nx, dx=dxs, h0=h0, b0=b0, U0=U0, cd=cd,
                                            theta0=RS.THETA0, rho_cp=RS.RHO_CP, g=RS.G, forcing="balance",
                                            sponge=(1000.0, 600.0), t_end=7200.0, steady_tol=1e-5, avg_from=4000.0)
            meta["grid"]["x0"] = -L_LINE / 2
            arrays["zb"] = zb[None, :].copy()
            outdir = os.path.join(RS.RAW, name)
            fld, rec = solver.run((meta, arrays), outdir)
            swio.write_pair(os.path.join(outdir, name + ".json"), meta, arrays)
            if rec["status"] != "steady" and "u_mean" in fld:
                hS, uS = fld["h_mean"][0], fld["u_mean"][0]
            else:
                hS = fld["h"][0]
                uS = fld["hu"][0] / np.maximum(hS, 1e-9)
            xc = -L_LINE / 2 + (np.arange(nx) + 0.5) * dxs

            def cell(name_):
                return int(np.clip(np.floor((pos[name_] + L_LINE / 2) / dxs), 0, nx - 1))
            ic13, ic04, ic09 = cell("tse13"), cell("tse04"), cell("tse09")
            r = dict(sw_case=name, h0=h0, dx_sw=dxs, U0=U0, b0=b0, F0=U0 / math.sqrt(b0 * h0), status=rec["status"],
                     t_model=rec["t"], dry_cells=rec["dry_cells"],
                     u_tse13=uS[ic13], u_tse04=uS[ic04], u_tse09=uS[ic09], ratio_valley_crest=uS[ic09] / uS[ic13],
                     h_tse13=hS[ic13], h_tse09=hS[ic09], u_min=float(uS.min()), x_u_min=float(xc[np.argmin(uS)]),
                     reverse_cells=int((uS < 0).sum()), u_min_over_U0=float(uS.min() / U0),
                     cells_between_crests=abs(ic04 - ic13), zb_range=float(zb.max() - zb.min()),
                     obs_ratio_tse09_tse13_100m=obs["tse09_100"] / obs["tse13_100"])
            rows.append(r)
            prof[name] = np.vstack([xc, zb, uS, hS])
            print({k_: (round(v, 3) if isinstance(v, float) else v) for k_, v in r.items()}, flush=True)
    out = os.path.join(RS.OUT, "perd.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    np.savez(os.path.join(RS.OUT, "perd_profiles.npz"), x_fine=x_fine, z_fine=z, **prof)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    for name, (xc, zb, uS, hS) in prof.items():
        fig, ax = plt.subplots(2, 1, figsize=(7, 5), sharex=True)
        ax[0].plot(xc, uS, "o-", ms=3); ax[0].axhline(0, c="k", lw=.5); ax[0].set_ylabel("ū_SW, м/с")
        ax[1].plot(x_fine, z, lw=.8, label="рельеф 10 м"); ax[1].step(xc, zb, where="mid", label="слой")
        for k, v in pos.items():
            ax[1].axvline(v, c="gray", lw=.4); ax[1].text(v, z.max(), k, fontsize=6, rotation=90)
        ax[1].legend(); ax[1].set_xlabel("x вдоль потока, м"); fig.suptitle(name); fig.tight_layout()
        fig.savefig(os.path.join(RS.OUT, name + ".png"), dpi=110); plt.close(fig)


if __name__ == "__main__":
    main()
