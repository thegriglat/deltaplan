"""SWC-9: слой Рипа (swpy) против Пикара на разрезах cascade-2d C0-C4 по SW5 v2.
Запуск: tools/research/sw_charges/py tools/research/sw_charges/sections/run_sections.py [--only C2] [--no-plots]
"""
import argparse
import csv
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SW = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(SW, "..", "..", ".."))
sys.path.insert(0, SW)
sys.path.insert(0, os.path.join(REPO, "tools", "research", "cascade_2d", "contract"))
from swpy import case as swcase, solver  # noqa: E402
import cascade2d_io as c2io  # noqa: E402

DATA = os.path.expanduser(os.environ.get("CASCADE2D_DATA", "~/data/cascade_2d"))
RAW = os.path.expanduser(os.environ.get("SWC9_RAW", "~/data/sw_charges/sections"))
OUT = os.path.join(SW, "out", "sections")

G, THETA0, RHO_CP, KAPPA, Z0 = 9.81, 300.0, 1206.0, 0.4, 0.1   # THETA0 как air3d/air.py (300 К)
N_LAYER = 1500.0            # configs/atmosphere.json n_layer_m
H_TOP = 2500.0              # верх области Пикара (~2525 м)
X_UP = -4800.0
TOL = 1e-5               # steady_tol; 5e-4 слишком грубо для слабых течений (C3), см. README
CASES = ("C0", "C1", "C2", "C3", "C4")
SUN = dict(az=100.0, el=45.0, H0=330.0, diffuse=0.10, lw=40.0)   # air3d/synth.py sun_flux, fixtures.heated_slope


def git_rev():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=HERE).stdout.strip()
    except Exception:
        return "unknown"


def load_case(c):
    d = json.load(open(os.path.join(DATA, "cases", f"{c}_d50.json")))
    return d["params"], d["case_params"]


def r1_u0(U10, alpha, u_aloft, h0):
    """R1 п. 2: среднее U(z) = U10 (z/10)^a до z_sat, дальше u_aloft, по 0..h0."""
    zs = 10.0 * (u_aloft / U10) ** (1.0 / alpha)
    if h0 <= zs:
        return U10 * 10 ** (-alpha) * h0 ** alpha / (1 + alpha), zs
    integ = U10 * 10 ** (-alpha) * zs ** (1 + alpha) / (1 + alpha)
    return (integ + u_aloft * (h0 - zs)) / h0, zs


def r1_cd(h0):
    return (KAPPA / math.log(0.37 * h0 / Z0)) ** 2


def block_mean(a, k):
    return a.reshape(-1, k).mean(axis=1)


def sun_q(zb, dx):
    """Поток солнца (Вт/м²) по уклону рельефа слоя; 1D (рельеф постоянен по y). Как synth.sun_flux."""
    gx = np.gradient(zb, dx)
    e, a = math.radians(SUN["el"]), math.radians(SUN["az"])
    sx, sz = math.cos(e) * math.sin(a), math.sin(e)
    cos_inc = -gx * sx + sz
    return SUN["H0"] * (np.clip(cos_inc, 0, None) + SUN["diffuse"] * max(sz, 0)) - SUN["lw"]


def variants(c, cp, prm):
    """Список вариантов ref: dict(h0, b0, rule_b0, note, q_on)."""
    U10, ua = cp["U10"], cp["U_aloft"]
    out = []
    if c == "C2":
        N2 = cp["N"] ** 2
        for h0 in (1000.0, 2500.0):
            out.append(dict(h0=h0, b0=N2 * h0, rule_b0="N2h0", note=f"b0=N^2*h0, N={cp['N']}"))
            out.append(dict(h0=h0, b0=N2 * N_LAYER, rule_b0="N2delta", note=f"b0=N^2*delta, delta={N_LAYER:.0f} м"))
    elif c == "C3":
        h0 = 1500.0
        N2 = G / THETA0 * 5.8e-3
        out.append(dict(h0=h0, b0=N2 * N_LAYER, rule_b0="N2delta", q_on=True,
                        note=f"z_i=1500, gam над z_i 5,8 К/км, N^2={N2:.3e}, delta={N_LAYER:.0f} м; q_heat=sun_flux(az100,el45) по уклону слоя, taper 2 км"))
        out.append(dict(h0=h0, b0=N2 * N_LAYER, rule_b0="N2delta", q_on=True, tag="3h", t_end=10800.0,
                        note="как C3, но нагрев 3 ч (чувствительность ко времени)"))
        out.append(dict(h0=h0, b0=N2 * N_LAYER, rule_b0="N2delta", q_on=False, tag="q0",
                        note="контроль C3 без нагрева (q_heat=0)"))
    else:
        out.append(dict(h0=H_TOP, b0=None, rule_b0=None, cap=True,
                        note="крышка: h0=2500 м, b0 из F0=0,1 (rule_b0=null)"))
    return out


def make_sw_case(c, cp, prm, v, hP, dx_sw, name):
    k = int(round(dx_sw / 50.0))
    zb = block_mean(hP, k)
    nx = zb.size
    U0, zs = r1_u0(cp["U10"], prm["alpha"], cp["U_aloft"], v["h0"])
    b0 = v["b0"] if v["b0"] is not None else (U0 / 0.1) ** 2 / v["h0"]
    cd = r1_cd(v["h0"])
    c_w = math.sqrt(b0 * v["h0"])
    Tc = nx * dx_sw / (U0 + c_w)
    heated = v.get("q_on", False)
    t_end = v.get("t_end") or min(max(12.0 * Tc, 3600.0), 43200.0)
    avg_from = 0.6 * t_end if not heated else t_end - 1800.0
    meta, arrays = swcase.make_case(
        name, shape="flat", dim=1, nx=nx, dx=dx_sw, h0=v["h0"], b0=b0, U0=U0, cd=cd, theta0=THETA0, rho_cp=RHO_CP,
        g=G, forcing="balance", sponge=(1600.0, 600.0), t_end=t_end, cfl=0.45, steady_tol=TOL, avg_from=avg_from,
        mapping=None)
    meta["grid"]["x0"] = -6400.0
    arrays["zb"] = zb[None, :].copy()
    if heated:
        x = -6400.0 + (np.arange(nx) + 0.5) * dx_sw
        taper = np.clip(np.minimum(x + 6400.0, 6400.0 - x) / 2000.0, 0, 1)
        arrays["q_heat"] = (sun_q(zb, dx_sw) * taper)[None, :]
    meta["source"] = {"kind": "cascade2d", "shape": None, "s": None,
                      "H": float(cp["H"]) if cp["H"] else None, "a": float(cp["L"]),
                      "ref_case": f"{DATA}/cases/{c}_d50.json"}
    meta["mapping"] = {"U10": cp["U10"], "N": cp["N"], "z_i": cp["z_i"], "dtheta": b0 * THETA0 / G,
                       "rule": "docs/research/sw_charges/literature.md §7 R1"}
    return meta, arrays, dict(U0=U0, b0=b0, z_sat=zs, cd=cd, t_end=t_end)


def picard_u_layer(fld, hsw_cells, zb_sw, dx_sw):
    """ū_P по клеткам слоя (SW5 v2). fld = (meta, arrays) F1. Возвращает ū_P (nsw,), число клеток."""
    m, a = fld
    nx, nz, dx, dz, z0 = m["nx"], m["nz"], m["dx"], m["dz"], m["z0"]
    uc = 0.5 * (a["u"][:, :-1] + a["u"][:, 1:])          # (nz, nx)
    air = a["cell"] > 0.5
    zc = z0 + (np.arange(nz) + 0.5) * dz
    kcol = int(round(dx_sw / dx))
    nsw = zb_sw.size
    out = np.zeros(nsw)
    for i in range(nsw):
        vals = []
        for ic in range(i * kcol, (i + 1) * kcol):
            sel = air[:, ic] & (zc > zb_sw[i]) & (zc <= zb_sw[i] + hsw_cells[i])
            if not sel.any():                           # h_SW < dz: одна нижняя клетка воздуха колонны
                idx = np.where(air[:, ic])[0]
                sel = np.zeros(nz, bool)
                sel[idx[0]] = True
            vals.append(uc[sel, ic])
        out[i] = np.concatenate(vals).mean()
    return out


def metrics(xs, uP, uS, xc, L, dx_sw):
    iup = int(np.floor((X_UP + 6400.0) / dx_sw))
    uup = uP[iup]
    W = max(6 * L, 3000.0)
    msk = np.abs(xs - xc) <= W
    icr = int(np.floor((xc + 6400.0) / dx_sw))
    lee = (xs >= xc) & (xs <= xc + W)
    out = {"u_up_P": float(uup), "u_up_SW": float(uS[iup])}
    out["E"] = float(np.sqrt(np.mean((uS[msk] - uP[msk]) ** 2)) / uup)
    out["E0"] = float(np.sqrt(np.mean((uup - uP[msk]) ** 2)) / uup)
    out["E_c"] = float(np.sqrt(np.mean(((uS[msk] - uS[iup]) - (uP[msk] - uup)) ** 2)) / uup)   # без смещения U0
    out["bias"] = float(np.mean(uS[msk] - uP[msk]) / uup)
    out["S_sw"], out["S_p"] = float(uS[icr] / uup), float(uP[icr] / uup)
    j_s, j_p = np.argmin(np.where(lee, uS, np.inf)), np.argmin(np.where(lee, uP, np.inf))
    out["D_sw"], out["D_p"] = float(uS[j_s] / uup), float(uP[j_p] / uup)
    out["x_D_sw"], out["x_D_p"] = float(xs[j_s]), float(xs[j_p])
    out["n_cells"] = int(msk.sum())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    ap.add_argument("--no-plots", action="store_true")
    ap.add_argument("--dxsw", default="400,200")
    ap.add_argument("--tol", type=float, default=1e-5)
    ap.add_argument("--suffix", default="")
    a = ap.parse_args()
    global TOL, RAW
    TOL = a.tol
    if a.suffix:
        RAW = RAW + a.suffix
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(RAW, exist_ok=True)
    rows, series = [], {}
    for c in (a.only.split(",") if a.only else CASES):
        prm, cp = load_case(c)
        P = {d: c2io.read_f1(os.path.join(DATA, "fields", c, f"picard_none_d{d}.json")) for d in (50, 400)}
        hP = P[50][1]["h"].astype(np.float64)
        for v in variants(c, cp, prm):
            for dxs in [int(s) for s in a.dxsw.split(",")]:
                tag = v.get("tag", "")
                name = f"{c}_{v['rule_b0'] or 'cap'}_h{int(v['h0'])}{('_' + tag) if tag else ''}_sw{dxs}"
                meta, arrays, info = make_sw_case(c, cp, prm, v, hP, float(dxs), name)
                outdir = os.path.join(RAW, name)
                t0 = time.time()
                fld, rec = solver.run((meta, arrays), outdir)
                wall = time.time() - t0
                # пишем SW1 рядом (для воспроизведения)
                from swpy import io as swio
                swio.write_pair(os.path.join(outdir, name + ".json"), meta, arrays)
                nsw = meta["grid"]["nx"]
                xs = -6400.0 + (np.arange(nsw) + 0.5) * dxs
                key = "u_mean" if "u_mean" in fld else None
                if key and rec["status"] != "steady":
                    hS, uS = fld["h_mean"][0], fld["u_mean"][0]
                else:
                    hS = fld["h"][0]
                    uS = np.where(fld["wet"][0] > 0, fld["hu"][0] / np.maximum(hS, 1e-12), 0.0)
                zbS = fld["zb"][0]
                F0 = info["U0"] / math.sqrt(info["b0"] * v["h0"])
                H = float(cp["H"] or 0.0)
                M = H / v["h0"]
                for dxp in ((50, 400) if dxs == 400 else (50,)):
                    uP = picard_u_layer(P[dxp], hS, zbS, float(dxs))
                    m = metrics(xs, uP, uS, cp["x_c"], cp["L"], float(dxs))
                    notes = v["note"] + f"; dx_sw={dxs}; U0 R1={info['U0']:.3f}, z_sat={info['z_sat']:.0f} м, cd={info['cd']:.4f}"
                    row = dict(case=c, dx=dxp, dx_sw=dxs, sw_case=name, sw_run=os.path.join(outdir, name + ".run.json"),
                               rule_b0=v["rule_b0"], h0=v["h0"], b0=info["b0"], U0=info["U0"], F0=F0, M=M,
                               E=m["E"], E0=m["E0"], S_sw=m["S_sw"], S_p=m["S_p"], D_sw=m["D_sw"], D_p=m["D_p"],
                               x_D_sw=m["x_D_sw"], x_D_p=m["x_D_p"], status=rec["status"], wall_s=round(wall, 2),
                               E_c=m["E_c"], bias=m["bias"], u_up_P=m["u_up_P"], u_up_SW=m["u_up_SW"],
                               variant=tag or None, steady_residual=rec["steady_residual"], t_model=rec["t"],
                               dry_cells=rec["dry_cells"], mass_rel_err=rec["mass_rel_err"], notes=notes)
                    rows.append(row)
                    series[(name, dxp)] = (xs, uS, uP, zbS, hS)
                    print(f"{c} {name} P{dxp}: {rec['status']} t={rec['t']:.0f} E={m['E']:.3f} E0={m['E0']:.3f} "
                          f"E_c={m['E_c']:.3f} S={m['S_sw']:.2f}/{m['S_p']:.2f} D={m['D_sw']:.2f}/{m['D_p']:.2f} "
                          f"wall={wall:.1f}s", flush=True)
    res = {"format": "sw-sections", "version": 2, "git": git_rev(), "created": time.strftime("%Y-%m-%dT%H:%M:%S"), "rows": rows}
    suffix = a.suffix + ("" if not a.only else "_" + a.only.replace(",", ""))
    jp = os.path.join(OUT, f"sections{suffix}.json")
    json.dump(res, open(jp, "w"), ensure_ascii=False, indent=1)
    with open(jp[:-5] + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    np.savez(os.path.join(OUT, f"profiles{suffix}.npz"),
             **{f"{k[0]}__P{k[1]}__{n}": arr for k, v in series.items() for n, arr in zip(("x", "uS", "uP", "zb", "h"), v)})
    if not a.no_plots:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        for (name, dxp), (xs, uS, uP, zbS, hS) in series.items():
            if dxp != 50 or a.suffix:
                continue
            fig, ax = plt.subplots(2, 1, figsize=(7, 5), sharex=True)
            ax[0].plot(xs, uS, "o-", ms=3, label="ū_SW")
            ax[0].plot(xs, uP, "s-", ms=3, label="ū_P (dx 50)")
            ax[0].set_ylabel("ū, м/с"); ax[0].legend()
            ax[1].plot(xs, zbS); ax[1].set_ylabel("z_b слоя, м"); ax[1].set_xlabel("x, м")
            fig.suptitle(name); fig.tight_layout()
            fig.savefig(os.path.join(OUT, name + ".png"), dpi=110); plt.close(fig)


if __name__ == "__main__":
    main()
