"""А1.3 (ревью): диагноз несходимости эталона air.py Онгудай 200 м, 3 м/с с нагревом (picard/, статус max).

История невязок θ′ и θ′_d по проверкам (каждые 10 итераций), где в поле живёт невязка θ′ (по высоте, в
нагретых столбцах, в губке), корреляция поля невязки между проверками (стоячая картина или качание).

  PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
  flock /tmp/heat_ca_gpu.lock $PY diag200.py <вариант> [max_outer] [dx]
Варианты:
  base32   — A.Air float32 как в picard_gpu_refs.py;
  base64   — то же float64 (если сходится — дело в округлении float32);
  prt1     — Pr_t = 1;
  tau_inf  — τ = 1e9 (θ′_d без стока: чисто проверка роли члена −θ′_d/τ);
  nocpl    — couple = 0 (полунеявная плавучесть выключена);
  dtau600  — Δτ_θ = 600 с (псевдошаг тепла вдвое меньше);
  sweeps8  — heat_sweeps = 8;
  oldsth   — cplz с прежним s_th = Δτ_θ/(1 + Δτ_θ/τ) (только коэффициент; неподвижная точка та же);
  nolocal  — local_k = False (без местного K по Ri: проверка обратной связи K ↔ θ′);
  krelax25 — k_relax = 0,25 (сильнее релаксация местного K между итерациями);
  old      — контроль: air.py до А1 (AIR3D_DIR=<каталог с air.py от feature/air-model>; вариант base32 там).
Выход — out/diag200_<вариант>.json (+ .npz с картами невязки).
"""
from __future__ import annotations

import dataclasses
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
import os
sys.path.insert(0, os.environ.get("AIR3D_DIR", str(HERE.parent.parent / "air3d")))   # old — air.py до А1 (контроль)
import air as A   # noqa: E402
import real as R  # noqa: E402

OUT = HERE / "out"
OUT.mkdir(exist_ok=True)
LOC, HOUR, WDIR = "ongudai", 12.0, 150.0
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)


class OldSth(A.Air):
    """cplz (и Kz проекции) с прежним s_th = Δτ_θ/(1 + Δτ_θ/τ)."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        prm = self.prm
        f = 1.0 / (1.0 + prm.dtau_th / prm.tau_cool)
        self.cplz_np = self.cplz_np * f
        self.cplz[...] = self.cp.asarray(self.cplz_np.astype(self.dt))
        # Kz проекции пересчитывается в __init__ от cplz — здесь не трогаем (только коэффициент SIMPLEC)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "base32"
    max_outer = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    dx = float(sys.argv[3]) if len(sys.argv) > 3 else 200.0
    dtype = np.float64 if what == "base64" else np.float32
    kw = {}
    cls = A.Air
    if what == "prt1":
        kw["pr_t"] = 1.0
    elif what == "tau_inf":
        kw["tau_cool"] = 1e9
    elif what == "nocpl":
        kw["couple"] = 0.0
    elif what == "dtau600":
        kw["dtau_th"] = 600.0
    elif what == "sweeps8":
        kw["heat_sweeps"] = 8
    elif what == "oldsth":
        cls = OldSth
    elif what == "nolocal":
        kw["local_k"] = False
    elif what == "krelax25":
        kw["k_relax"] = 0.25
    prm = A.Params(**kw)
    g, hc = R.grid_domain(LOC, dx)
    c = R.case(LOC, g, hc, HOUR, 3.0, WDIR, heat=True)
    A.Air, keep = cls, A.Air
    S = R.make(LOC, g, hc, c, prm=prm, dtype=dtype)
    A.Air = keep
    S.init_background()
    cp = S.cp
    fl = S.fluid_np
    Qn = S.Q.get() > 0
    spn = S.spc.get() > 0
    zc = S.zc
    agl = zc[:, None, None] - hc[None] if False else None  # noqa: F841 (высота над землёй — через k)
    hist = []
    prev = {"r": None}

    def cb(S_, r):
        # поле невязки θ′ (после residuals: шаблоны собраны от текущего состояния)
        S_.lines.resid(S_.Ct, S_.th, S_.bt, S_.rr)
        rt = (cp.abs(S_.rr) * S_.fluid).get()
        if hasattr(S_, "Ctd"):
            S_.lines.resid(S_.Ctd, S_.thd, S_.btd, S_.rr)
            rd = (cp.abs(S_.rr) * S_.fluid).get()
        else:
            rd = rt * 0
        k, j, i = np.unravel_index(int(rt.argmax()), rt.shape)
        n = S_.n_fluid
        rms = lambda m: float(np.sqrt(np.sum((rt * m) ** 2) / n))  # noqa: E731 (доля СКО от подмножества)
        # профиль СКО невязки θ′ по уровням
        prof = np.sqrt((rt ** 2).sum(axis=(1, 2)) / np.maximum(fl.sum(axis=(1, 2)), 1))
        corr = None
        if prev["r"] is not None:
            a, b = prev["r"].ravel(), rt.ravel()
            corr = float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))
        prev["r"] = rt.copy()
        hist.append(dict(it=r["it"], th_rms=r["th_rms"], thd_rms=r.get("thd_rms"), th_max=r["th_max"], thd_max=r.get("thd_max"),
                         mom_rms=r["mom_rms"], div_rms=r["div_rms"],
                         th_only_rms=float(np.sqrt(np.sum(rt ** 2) / n)), thd_only_rms=float(np.sqrt(np.sum(rd ** 2) / n)),
                         argmax=[int(k), int(j), int(i)], z_argmax=float(zc[k] - hc[j - 1, i - 1]) if 0 < j < hc.shape[0] + 1 and 0 < i < hc.shape[1] + 1 else None,
                         rms_Q=rms(Qn), rms_sponge=rms(spn), rms_rest=rms(~Qn & ~spn),
                         prof_kmax=int(prof.argmax()), prof_top3=[float(x) for x in np.sort(prof)[-3:]],
                         corr_prev=corr))
        if len(hist) % 5 == 0:
            h = hist[-1]
            print(f"  it {h['it']:5d} th {h['th_only_rms']:.2e} thd {h['thd_only_rms']:.2e} mom {h['mom_rms']:.2e} "
                  f"div {h['div_rms']:.2e} argmax {h['argmax']} zagl {h['z_argmax']} corr {corr}", flush=True)

    t0 = time.perf_counter()
    st = S.solve(max_outer=max_outer, graph=True, cb=cb, **TOL)
    wall = time.perf_counter() - t0
    # карты невязки θ′ в конце: max по z (план) и max по y (разрез)
    S.lines.resid(S.Ct, S.th, S.bt, S.rr)
    rt = (cp.abs(S.rr) * S.fluid).get()
    th = (S.th * S.fluid).get(); thd = (getattr(S, "thd", S.th * 0) * S.fluid).get()
    res = dict(variant=what, dx=dx, dtype=str(np.dtype(dtype)), params=dataclasses.asdict(prm), status=st, iters=S.outer, wall=wall,
               closure=S.closure_info, th_range=[float(th.min()), float(th.max())], thd_range=[float(thd.min()), float(thd.max())],
               budget=S.heat_budget(), hist=hist, air_py=A.__file__)
    what = what if "AIR3D_DIR" not in os.environ else "old_" + what
    what += os.environ.get("DIAG_TAG", "")      # суффикс имени выхода (например _3000)
    (OUT / f"diag200_{what}.json").write_text(json.dumps(res, ensure_ascii=False, indent=1, default=float))
    np.savez_compressed(OUT / f"diag200_{what}.npz", r_plan=rt.max(axis=0), r_xz=rt.max(axis=1), hc=hc, Q_plan=S.Q.get().max(axis=0),
                        th_xz=th[:, th.shape[1] // 2, :], zc=zc)
    print(json.dumps({k: v for k, v in res.items() if k != "hist"}, ensure_ascii=False, default=float))
    print("last:", json.dumps(hist[-1], default=float))


if __name__ == "__main__":
    main()
