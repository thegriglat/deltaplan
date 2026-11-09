#!/usr/bin/env python3
"""PT6 v1: picard_rs::cut_build (CLI `picard cut-build`) против cut.py на 5 случаях опыта.

  tools/research/sw_charges_3d/py tools/research/picard_terrain/contract/check_cut_build.py [case ...]

Для случая <c> (PT1) и <c>_cut (PT2) из $PICARD_TERRAIN_DATA:
  * растр terrain/<site>.h5 выгружается в сырой f32 во временную папку, вызывается rust/target/release/picard cut-build;
  * эталон 1 — массивы vf, af_* готового <c>_cut (после finish); эталон 2 — cut.fractions + правила finish из cut.build
    (по cell, tu, tv, tw готового случая) + cut.type_height; счётчики — pt.cut готового случая.
Последняя строка: cut_build: max_dvf=<x> max_daf=<x> hc_type_mismatch=<n> counts_mismatch=<n> cases=<k>.
Код 0 — только если max <= 1e-6 и несовпадений нет.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(ROOT / "tools/research/air3d"))
import cut as CUT  # noqa: E402
import sample as SM  # noqa: E402

CASES = ["askervein_d50", "askervein_d100", "kayancha_d50", "kayancha_d100", "perdigao_ne_d30"]
TOL = 1e-6
EXE = ROOT / "rust/target/release/picard"


def py_finish(vf, au, av, aw, cell, tu, tv, tw):
    """Правила cut.build после типов (полная клетка, пол грани) -> счётчики."""
    full = (cell == 1) & (vf >= 1 - 1e-6)
    n_snap = int((full & (vf < 1)).sum())
    vf[full] = 1.0
    au[full] = 1.0; au[:, :, 1:][full[:, :, :-1]] = 1.0
    av[full] = 1.0; av[:, 1:, :][full[:, :-1, :]] = 1.0
    aw[full] = 1.0; aw[1:][full[:-1]] = 1.0
    n_floor = 0
    for a, t in ((au, tu), (av, tv), (aw, tw)):
        bad = (t == 1) & (a <= 0)
        n_floor += int(bad.sum())
        a[bad] = CUT.AF_FLOOR
    cutc = (cell[1:-1, 1:-1, 1:-1] == 1) & (vf[1:-1, 1:-1, 1:-1] < 1 - 1e-6)
    return n_snap, n_floor, int(cutc.sum())


def one(name, work):
    D = CUT.D
    meta, _ = CUT.read_case(D / "cases" / f"{name}.json")
    cmeta = json.loads((D / "cases" / f"{name}_cut.json").read_text())
    NX, NY, NZ = meta["dims"]
    shape = (NZ, NY, NX)
    pt = meta["pt"]
    ras = SM.Raster(D / pt["terrain"]["path"], pt["terrain"]["dataset"])
    rbin = work / f"{name}_raster.f32"
    ras.h.astype("<f4").tofile(rbin)
    ny, nx = ras.h.shape
    rjson = work / f"{name}_raster.json"
    rjson.write_text(json.dumps(dict(nx=nx, ny=ny, x0=ras.x0, y0=ras.y0, dx=ras.dx, bin=str(rbin))))
    prefix = work / f"{name}_out"
    subprocess.run([str(EXE), "cut-build", "--raster", str(rjson), "--grid", str(D / "cases" / f"{name}.json"),
                    "--types", str(D / "cases" / f"{name}_cut.json"), "--out", str(prefix), "--threads", "8"],
                   check=True, stdout=subprocess.DEVNULL)
    o = json.loads(Path(f"{prefix}.json").read_text())
    raw = np.fromfile(f"{prefix}.bin", dtype="<f4")
    n3 = NX * NY * NZ
    got = [raw[i * n3:(i + 1) * n3].reshape(shape).astype(np.float64) for i in range(4)]
    hc_got = np.fromfile(f"{prefix}.bin", dtype="<f8", offset=4 * 4 * n3).reshape(meta["ny"], meta["nx"])
    # эталон 1: готовый _cut
    cj = D / "cases" / f"{name}_cut.json"
    mm = np.memmap(cj.with_suffix(".bin"), dtype="<f4", mode="r")
    sv = {k: np.asarray(mm[o_:o_ + n], np.float64).reshape(shape) for k, (o_, n) in cmeta["arrays"].items()
          if k in ("vf", "af_u", "af_v", "af_w", "cell", "tu", "tv", "tw")}
    d1 = [float(np.abs(g - sv[k]).max()) for g, k in zip(got, ("vf", "af_u", "af_v", "af_w"))]
    # эталон 2: cut.py с нуля
    vf, au, av, aw = CUT.fractions(meta, ras, CUT.SAMPLES)
    hct = CUT.type_height(meta, vf, CUT.VF_MIN)
    cnt = py_finish(vf, au, av, aw, sv["cell"], sv["tu"], sv["tv"], sv["tw"])
    d2 = [float(np.abs(g - r).max()) for g, r in zip(got, (vf, au, av, aw))]
    dvf = max(d1[0], d2[0])
    daf = max(d1[1:] + d2[1:])
    hcm = int((hc_got != hct).sum())
    c = cmeta["pt"]["cut"]
    want = (c["n_snap_full"], c["n_face_floor"], c["n_cut_cells"])
    mine = (o["n_snap_full"], o["n_face_floor"], o["n_cut_cells"])
    cm = int(mine != want) + int(mine != cnt)
    t = o["time_ms"]
    print(f"{name}: grid {meta['nx']}x{meta['ny']}x{meta['nz']} raster {nx}x{ny} dvf={dvf:.2e} daf={daf:.2e} "
          f"hc_type_mismatch={hcm} counts {mine} want {want} py {cnt}; "
          f"ms fractions {t['fractions']:.1f} type_height {t['type_height']:.1f} finish {t['finish']:.1f} "
          f"threads {o['threads']}", flush=True)
    return dvf, daf, hcm, cm


def main():
    names = sys.argv[1:] or CASES
    if not EXE.exists():
        sys.exit(f"no {EXE}: cargo build --release -p picard_rs (in rust/)")
    res = []
    with tempfile.TemporaryDirectory(prefix="cut_build_") as w:
        for nm in names:
            res.append(one(nm, Path(w)))
    dvf = max(r[0] for r in res)
    daf = max(r[1] for r in res)
    hcm = sum(r[2] for r in res)
    cm = sum(r[3] for r in res)
    print(f"cut_build: max_dvf={dvf:.3e} max_daf={daf:.3e} hc_type_mismatch={hcm} counts_mismatch={cm} cases={len(res)}")
    sys.exit(0 if dvf <= TOL and daf <= TOL and hcm == 0 and cm == 0 else 1)


if __name__ == "__main__":
    main()
