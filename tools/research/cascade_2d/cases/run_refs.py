"""Эталоны Пикара для cascade-2d (CSD-1): picard_rs на случаях R1 → F1 среднего ряда + F2 + таблица сходимости.

    tools/research/cascade_2d/py tools/research/cascade_2d/cases/run_refs.py all      # solve + convert + table
    ... run_refs.py solve [--cases C0,C1] [--dx 400,200]    # только решение (под замком cpu), сырьё в $CASCADE2D_DATA/raw
    ... run_refs.py convert                                 # raw -> F1 (fields/<C>/) + F2 (+ копия в out/runs/<C>/)
    ... run_refs.py table                                   # out/convergence.{json,md}

Решатель: rust/target/release/picard без правок (cargo build --release --manifest-path rust/Cargo.toml -p picard_rs).
Раскладка state (R4 v2) — (NZ, NY, NX) с ореолом, сетка MAC: u[k,j,i] — левая x-грань клетки i (интерьер i = 1..nx),
v — грань по y, w[k,j,i] — нижняя z-грань клетки k; div клетки (k,j,i) = (u[i+1]-u[i])/dx + (v[j+1]-v[j])/dx + (w[k+1]-w[k])/dz.
F1 среднего ряда j = ny/2: u[kk,f] = U[kk+1, j+1, f+1], w[kf,ii] = W[kf+1, j+1, ii+1].
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent / "contract"))
import cascade2d_io as IO  # noqa: E402

PICARD = ROOT / "rust/target/release/picard"
DP = ROOT / ".dpcli/dpcli"
DATA = Path(IO.data_dir())
CASES = ("C0", "C1", "C2", "C3", "C4")
LEVELS = IO.LEVELS_DX
THREADS = int(os.environ.get("CASCADE2D_THREADS", "1"))   # под замком cpu cgroup CPUQuota=100%: 8 потоков в 3,7 раза медленнее 1 (замер C1 d100)
MAX_ITERS = 3000
TIME_BUDGET_S = 7200.0
ML = {"C0": 500.0, "C1": 500.0, "C2": 300.0, "C3": 500.0}   # L для M1; x_c = 0 (C4 — из case_params)
RUNS_OUT = Path(os.environ.get("CASCADE2D_RUNS", str(HERE.parent / "out/runs")))


def git_hash():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    except Exception:
        return None


def cpu_name():
    try:
        for ln in open("/proc/cpuinfo"):
            if ln.startswith("model name"):
                return ln.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor()


def rustc():
    try:
        return subprocess.check_output(["rustc", "--version"], text=True).strip()
    except Exception:
        return None


def raw_paths(c, dx):
    d = DATA / "raw" / c
    return d, d / f"picard_d{dx}.state.json", d / f"picard_d{dx}.r2.json", d / f"picard_d{dx}.meta.json"


# ------------------------------------------------------------------ solve
def solve(cases, dxs, force=False):
    for c in cases:
        for dx in dxs:
            d, st, r2, meta = raw_paths(c, dx)
            if meta.exists() and not force:
                print(f"{c} d{dx}: есть, пропуск", flush=True)
                continue
            d.mkdir(parents=True, exist_ok=True)
            case = DATA / "cases" / f"{c}_d{dx}.json"
            cmd = [str(DP), "lock", "cpu", "cascade-ref", "--", str(PICARD), "solve", str(case), "--threads", str(THREADS),
                   "--max-iters", str(MAX_ITERS), "--time-budget", str(TIME_BUDGET_S), "--save-state", str(st),
                   "--out", str(r2)]
            t0 = time.time()
            p = subprocess.Popen(cmd)
            _, status, ru = os.wait4(p.pid, 0)
            wall = time.time() - t0
            rc = os.waitstatus_to_exitcode(status)
            if rc != 0:
                print(f"{c} d{dx}: код {rc}", flush=True)
                continue
            meta.write_text(json.dumps(dict(cmd=" ".join(cmd), wall_s=wall, ru_maxrss_mb=ru.ru_maxrss / 1024.0,
                                            created=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"))))
            r = json.loads(r2.read_text())
            print(f"{c} d{dx}: {r['status']} iters {r['iters']} total {r['time']['total_s']:.1f} s, rss {ru.ru_maxrss/1024:.0f} МБ",
                  flush=True)


# ------------------------------------------------------------------ чтение
def read_case(c, dx):
    p = DATA / "cases" / f"{c}_d{dx}.json"
    m = json.loads(p.read_text())
    b = np.fromfile(p.with_suffix(".bin"), "<f4")
    shp = tuple(m["dims"][::-1])
    A = {}
    for n in ("hc", "cell", "tu", "tw"):
        o, l = m["arrays"][n]
        A[n] = b[o:o + l]
        if n != "hc":
            A[n] = A[n].reshape(shp)
    A["hc"] = A["hc"].reshape(m["ny"], m["nx"])
    return m, A, p.with_suffix(".bin").stat().st_size


def read_state(path):
    m = json.loads(path.read_text())
    b = np.fromfile(path.with_suffix(".bin"), "<f4")
    shp = tuple(m["dims"][::-1])
    S = {}
    for n, (o, l) in m["arrays"].items():
        S[n] = b[o:o + l].reshape(shp)
    return m, S, path.with_suffix(".bin").stat().st_size


def mid_row(cm, A, S, ny):
    """F1 среднего ряда j = ny/2 (индекс интерьера) -> (arrays dict, j)."""
    nx, nz = cm["nx"], cm["nz"]
    j = ny // 2
    jh = j + 1
    arr = {
        "u": S["u"][1:nz + 1, jh, 1:nx + 2],
        "w": S["w"][1:nz + 2, jh, 1:nx + 1],
        "th": S["th"][1:nz + 1, jh, 1:nx + 1],
        "cell": (A["cell"][1:nz + 1, jh, 1:nx + 1] == 1).astype(np.float32),
        "tu": A["tu"][1:nz + 1, jh, 1:nx + 2],
        "tw": A["tw"][1:nz + 2, jh, 1:nx + 1],
        "h": A["hc"][j, :],
    }
    arr = {k: np.array(v, np.float32) for k, v in arr.items()}
    arr["u"][arr["tu"] == 0] = 0
    arr["w"][arr["tw"] == 0] = 0
    return arr, j


def u_ref_of(meta, arr):
    """U_ref (M1): |u| клетки на ~100 м над землёй при x = -4800 (клетка = среднее двух граней)."""
    dx, dz, z0 = meta["dx"], meta["dz"], meta["z0"]
    i = int(np.floor((-4800.0 - meta["x0"]) / dx))
    h = float(arr["h"][i])
    k = int(np.argmin(np.abs(z0 + (np.arange(meta["nz"]) + 0.5) * dz - (h + 100.0))))
    return float(abs(0.5 * (arr["u"][k, i] + arr["u"][k, i + 1])))


# ------------------------------------------------------------------ convert
def convert(cases, dxs):
    refs = {}
    for c in cases:
        # U_ref — по P25, при его отсутствии по самому мелкому
        U_ref = None
        for dx in sorted(dxs):
            _, st, _, mt = raw_paths(c, dx)
            if not mt.exists():
                continue
            cm, A, _ = read_case(c, dx)
            sm, S, _ = read_state(st)
            arr, _ = mid_row(cm, A, S, cm["ny"])
            meta = dict(dx=cm["dx"], dz=cm["dz"], nx=cm["nx"], nz=cm["nz"], x0=-6400.0, z0=-cm["dz"])
            U_ref = u_ref_of(meta, arr)
            break
        if U_ref is None:
            continue
        for dx in dxs:
            d, st, r2p, mt = raw_paths(c, dx)
            if not mt.exists():
                continue
            cm, A, case_bytes = read_case(c, dx)
            sm, S, st_bytes = read_state(st)
            r2 = json.loads(r2p.read_text())
            mm = json.loads(mt.read_text())
            ny, nx, nz = cm["ny"], cm["nx"], cm["nz"]
            arr, j = mid_row(cm, A, S, ny)
            fdir = DATA / "fields" / c
            f1 = fdir / f"picard_none_d{dx}.json"
            meta = dict(case=c, source="picard", variant=None, dx=dx, dz=dx / 4.0, nx=nx, nz=nz, x0=-6400.0, z0=-dx / 4.0,
                        parent_dx=None, seed=None, git=git_hash())
            IO.write_f1(f1, meta, arr)
            m1, a1 = IO.read_f1(f1)
            IO.check_f1_arrays(m1, a1)
            # --- баланс: F1 2D и 3D решателя
            div = IO.div2d(m1, a1)
            rel = IO.rel_div(div, dx, U_ref)
            air = a1["cell"] > 0.5
            # 3D дивергенция по state (клетки типа 1 интерьера), для сверки с div_rms решателя
            u3, v3, w3 = S["u"].astype(np.float64), S["v"].astype(np.float64), S["w"].astype(np.float64)
            d3 = ((u3[1:-1, 1:-1, 2:] - u3[1:-1, 1:-1, 1:-1]) / dx + (v3[1:-1, 2:, 1:-1] - v3[1:-1, 1:-1, 1:-1]) / dx
                  + (w3[2:, 1:-1, 1:-1] - w3[1:-1, 1:-1, 1:-1]) / (dx / 4.0))
            air3 = A["cell"][1:-1, 1:-1, 1:-1] == 1
            div3_rms = float(np.sqrt(np.mean(d3[air3] ** 2)))
            div2_rms = float(np.sqrt(np.mean(div[air] ** 2)))
            div2_max = float(np.abs(div[air]).max())
            # --- однородность по y: max |f(j) - f(ny/2)| / U_ref по u, w
            yu = 0.0
            for nme, sl in (("u", (slice(1, nz + 1), slice(1, nx + 2))), ("w", (slice(1, nz + 2), slice(1, nx + 1)))):
                F = S[nme][sl[0], 1:ny + 1, sl[1]]
                yu = max(yu, float(np.abs(F - F[:, j:j + 1, :]).max()) / U_ref)
            # --- y-среднее по рядам: его 2D div равна среднему 3D div (v = 0 на стенках y) -> согласовано с решателем
            avg = dict(arr)
            avg["u"] = S["u"][1:nz + 1, 1:ny + 1, 1:nx + 2].mean(axis=1).astype(np.float32)
            avg["w"] = S["w"][1:nz + 2, 1:ny + 1, 1:nx + 1].mean(axis=1).astype(np.float32)
            avg["th"] = S["th"][1:nz + 1, 1:ny + 1, 1:nx + 1].mean(axis=1).astype(np.float32)
            avg["u"][arr["tu"] == 0] = 0
            avg["w"][arr["tw"] == 0] = 0
            fm = fdir / "ymean" / f"picard_none_d{dx}.json"
            IO.write_f1(fm, meta, avg)
            ma, aa = IO.read_f1(fm)
            IO.check_f1_arrays(ma, aa)
            relm = IO.rel_div(IO.div2d(ma, aa), dx, U_ref)
            dmean_u = float(np.abs(aa["u"] - a1["u"]).max()) / U_ref
            dmean_w = float(np.abs(aa["w"] - a1["w"]).max()) / U_ref
            ymean_note = (f"y-среднее по рядам (fields/{c}/ymean/): max_rel_div={relm[aa['cell'] > 0.5].max():.2e}, "
                          f"max|ymean-mid|/U_ref: u {dmean_u:.3f}, w {dmean_w:.3f}")
            res = r2.get("residuals") or {}
            work = r2["time"]["total_s"] - r2["time"]["setup_s"]
            f2 = dict(
                format="cascade2d-run", version=1, case=c, source="picard", variant=None, dx=dx, parent_dx=None, seed=None,
                threads=int(r2["threads"]), ny=ny, status=r2["status"], iters=int(r2["iters"]),
                time=dict(total_s=r2["time"]["total_s"], setup_s=r2["time"]["setup_s"], work_s=work, per_row_s=work / ny),
                memory=dict(peak_rss_mb=mm["ru_maxrss_mb"], arrays_mb=(case_bytes + st_bytes) / 2 ** 20),
                balance=dict(max_rel_div=float(rel[air].max()), rms_rel_div=float(np.sqrt(np.mean(rel[air] ** 2))),
                             levels=[dict(dx=dx, max_rel_div=float(rel[air].max()))]),
                y_uniform=yu, query=None, field=str(f1), cmd=mm["cmd"],
                host=dict(cpu=cpu_name(), rustc=rustc()), git=git_hash(),
                notes=(f"U_ref={U_ref:.4f} м/с (|u| P25 на 100 м над землёй, x=-4800); stop={r2.get('stop')}; "
                       f"peak_rss_mb = ru_maxrss процесса (lock+picard, wait4), включает загрузку случая и state; "
                       f"arrays_mb = размер .bin случая + state; ms_per_iter={r2['time']['ms_per_iter']:.3f}; "
                       f"mom_rms={res.get('mom_rms')}, div_rms решателя (3D, невязка)={res.get('div_rms')}; "
                       f"3D div_rms из state={div3_rms:.3e}, F1 2D div_rms={div2_rms:.3e}, max|div|={div2_max:.3e} 1/с; "
                       f"{ymean_note}; physical params as game case, sponge_axes=x; ny={ny}, средний ряд j={j}"))
            IO.validate_f2(f2)
            fdir.mkdir(parents=True, exist_ok=True)
            for dest in (fdir / f"picard_none_d{dx}.run.json", RUNS_OUT / c / f"picard_none_d{dx}.run.json"):
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_suffix(".tmp")
                tmp.write_text(json.dumps(f2, ensure_ascii=False, indent=1))
                os.replace(tmp, dest)
            print(f"{c} d{dx}: {ymean_note}; F1/F2 записаны; div3={div3_rms:.2e} div2={div2_rms:.2e} (решатель {res.get('div_rms')}), "
                  f"y_uniform={yu:.2e}, max_rel_div={f2['balance']['max_rel_div']:.2e}", flush=True)


# ------------------------------------------------------------------ сходимость по сетке
def cell_vel(arr):
    uc = 0.5 * (arr["u"][:, :-1] + arr["u"][:, 1:])
    wc = 0.5 * (arr["w"][:-1] + arr["w"][1:])
    return uc, wc


def interp_to(meta_c, a_c, meta_f):
    """Линейная интерполяция u, w грубой сетки (F1) на грани тонкой; скорость в земле 0 (грани tu/tw = 0 уже нули)."""
    from scipy.interpolate import RegularGridInterpolator as RGI
    out = {}
    dxc, dzc, dxf, dzf = meta_c["dx"], meta_c["dz"], meta_f["dx"], meta_f["dz"]
    x0, z0c, z0f = -6400.0, meta_c["z0"], meta_f["z0"]
    # u: x-грани, z центры
    xu_c = x0 + np.arange(meta_c["nx"] + 1) * dxc
    zu_c = z0c + (np.arange(meta_c["nz"]) + 0.5) * dzc
    xu_f = x0 + np.arange(meta_f["nx"] + 1) * dxf
    zu_f = z0f + (np.arange(meta_f["nz"]) + 0.5) * dzf
    f = RGI((zu_c, xu_c), a_c["u"].astype(np.float64), bounds_error=False, fill_value=None)
    Z, X = np.meshgrid(np.clip(zu_f, zu_c[0], zu_c[-1]), xu_f, indexing="ij")
    out["u"] = f(np.stack([Z, X], -1))
    xw_c = x0 + (np.arange(meta_c["nx"]) + 0.5) * dxc
    zw_c = z0c + np.arange(meta_c["nz"] + 1) * dzc
    xw_f = x0 + (np.arange(meta_f["nx"]) + 0.5) * dxf
    zw_f = z0f + np.arange(meta_f["nz"] + 1) * dzf
    f = RGI((zw_c, xw_c), a_c["w"].astype(np.float64), bounds_error=False, fill_value=None)
    Z, X = np.meshgrid(np.clip(zw_f, zw_c[0], zw_c[-1]), np.clip(xw_f, xw_c[0], xw_c[-1]), indexing="ij")
    out["w"] = f(np.stack([Z, X], -1))
    return out


def diff_50_25(c):
    """СКО (u - u_ref), (w - w_ref) P50 против P25 в ROI M1 (0 < z_agl <= 300, |x| <= 3L), клетки воздуха P25 / U_ref."""
    f25 = DATA / "fields" / c / "picard_none_d25.json"
    f50 = DATA / "fields" / c / "picard_none_d50.json"
    if not (f25.exists() and f50.exists()):
        return None
    m25, a25 = IO.read_f1(f25)
    m50, a50 = IO.read_f1(f50)
    run25 = IO.read_f2(DATA / "fields" / c / "picard_none_d25.run.json")
    U = float(run25["notes"].split("U_ref=")[1].split()[0])
    b = interp_to(m50, a50, m25)
    for k, t in (("u", "tu"), ("w", "tw")):
        b[k] = np.where(a25[t] > 0, b[k], 0.0)
    ub, wb = cell_vel({"u": b["u"], "w": b["w"]})
    ur, wr = cell_vel(a25)
    nz, nx = m25["nz"], m25["nx"]
    xc = m25["x0"] + (np.arange(nx) + 0.5) * m25["dx"]
    zc = m25["z0"] + (np.arange(nz) + 0.5) * m25["dz"]
    zagl = zc[:, None] - a25["h"][None, :]
    air = a25["cell"] > 0.5
    L = ML.get(c)
    xcen = 0.0
    if L is None:
        cp = json.loads((DATA / "cases" / f"{c}_d25.json").read_text())["case_params"]
        L, xcen = cp["L"], cp["x_c"]
    xc = xc - xcen
    roi = air & (zagl > 0) & (zagl <= 300) & (np.abs(xc)[None, :] <= 3 * L)
    lee = air & (zagl > 0) & (zagl <= 300) & (xc[None, :] > 0) & (xc[None, :] <= 6 * L)
    rms = lambda d, m: float(np.sqrt(np.mean(d[m] ** 2)) / U)
    return dict(U_ref=U, E_u=rms(ub - ur, roi), E_w=rms(wb - wr, roi), E_u_lee=rms(ub - ur, lee),
                rms_u_ref=rms(ur, roi), rms_w_ref=rms(wr, roi), n_roi=int(roi.sum()))


def table():
    rows, conv = [], {}
    for c in CASES:
        for dx in LEVELS:
            p = DATA / "fields" / c / f"picard_none_d{dx}.run.json"
            if not p.exists():
                continue
            r = IO.read_f2(p)
            ms = float(r["notes"].split("ms_per_iter=")[1].split(";")[0])
            rows.append(dict(case=c, dx=dx, status=r["status"], iters=r["iters"], ms_per_iter=ms, total_s=r["time"]["total_s"],
                             per_row_s=r["time"]["per_row_s"], rss_mb=r["memory"]["peak_rss_mb"],
                             arrays_mb=r["memory"]["arrays_mb"], max_rel_div=r["balance"]["max_rel_div"],
                             rms_rel_div=r["balance"]["rms_rel_div"], y_uniform=r["y_uniform"]))
        d = diff_50_25(c)
        if d:
            conv[c] = d
    out = HERE
    out.mkdir(exist_ok=True)
    (out / "convergence.json").write_text(json.dumps(dict(runs=rows, p50_vs_p25=conv), indent=1))
    L = ["| случай | dx, м | статус | итераций | мс/итер | total, с | per_row, с | RSS, МБ | arrays, МБ | max rel_div | y_uniform |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {r['case']} | {r['dx']} | {r['status']} | {r['iters']} | {r['ms_per_iter']:.2f} | {r['total_s']:.1f} | "
                 f"{r['per_row_s']:.2f} | {r['rss_mb']:.0f} | {r['arrays_mb']:.0f} | {r['max_rel_div']:.2e} | {r['y_uniform']:.2e} |")
    L += ["", "| случай | U_ref, м/с | E_u (P50 vs P25) | E_w | E_u_lee | СКО u_ref/U_ref в ROI | СКО w_ref/U_ref в ROI |",
          "|---|---|---|---|---|---|---|"]
    for c, d in conv.items():
        L.append(f"| {c} | {d['U_ref']:.3f} | {d['E_u']:.4f} | {d['E_w']:.4f} | {d['E_u_lee']:.4f} | {d['rms_u_ref']:.4f} | {d['rms_w_ref']:.4f} |")
    (out / "convergence.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["all", "solve", "convert", "table"])
    ap.add_argument("--cases", default=",".join(CASES))
    ap.add_argument("--dx", default=",".join(str(d) for d in LEVELS))
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    cases = a.cases.split(",")
    dxs = [int(x) for x in a.dx.split(",")]
    if a.what in ("all", "solve"):
        solve(cases, dxs, a.force)
    if a.what in ("all", "convert"):
        convert(cases, dxs)
    if a.what in ("all", "table"):
        table()


if __name__ == "__main__":
    main()
