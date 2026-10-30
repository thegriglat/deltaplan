"""Readers for R1 cases and R4 snapshots, regions and field deviations (PR-8, R7 v1). numpy only.

Everything here is a pure function of arrays. Layout of 3D arrays: (NZ, NY, NX) with a 1-cell halo,
index (k*NY+j)*NX+i (R1/R4); the interior is [1:-1, 1:-1, 1:-1]. Cell centre height of interior
level k (0-based): z_bot + (k + 0.5) * dz (kernels.rs:114, halo index kk = k + 1).
"""
import json
from pathlib import Path

import numpy as np

# Region parameters (documented in README / summary.regions).
SLOPE_MIN = 0.3       # terrain slope |grad h| (m/m, ~17 deg): upper quintile of Ongudai columns (median 0.22); see README
AGL_BANDS = {"agl_10_50": (10.0, 50.0), "agl_50_100": (50.0, 100.0),
             "agl_100_200": (100.0, 200.0), "agl_200_400": (200.0, 400.0)}
SLOPE_AGL = (10.0, 400.0)
THERMAL_AGL = (10.0, 400.0)
LAUNCH_AGL_MAX = 400.0


def read_pair(json_path, names=None):
    """Reads `<x>.json` + `<x>.bin` (R1 or R4): returns (meta, {name: float32 array})."""
    jp = Path(json_path)
    meta = json.loads(jp.read_text())
    raw = np.fromfile(jp.with_suffix(".bin"), dtype="<f4")
    out = {}
    for k, (off, n) in meta["arrays"].items():
        if names is None or k in names:
            out[k] = raw[off:off + n]
    return meta, out


def interior(a, nzh, nyh, nxh):
    """Interior (without halo) view of a flat halo array."""
    return a.reshape(nzh, nyh, nxh)[1:-1, 1:-1, 1:-1]


class Geometry:
    """Fluid mask, height above terrain, terrain slope and crop window of one case."""

    def __init__(self, case_json):
        meta, arr = read_pair(case_json, ("hc", "cell"))
        self.meta = meta
        nxh, nyh, nzh = meta["dims"]
        self.dims = (nzh, nyh, nxh)
        self.nx, self.ny, self.nz = meta["nx"], meta["ny"], meta["nz"]
        self.fluid = interior(arr["cell"], nzh, nyh, nxh) == 1
        self.hc = arr["hc"].reshape(self.ny, self.nx).astype(np.float64)
        zc = meta["z_bot"] + (np.arange(self.nz) + 0.5) * meta["dz"]
        self.agl = zc[:, None, None] - self.hc[None, :, :]
        gy, gx = np.gradient(self.hc, meta["dx"])
        self.hx, self.hy = gx, gy
        self.slope = np.hypot(gx, gy)                      # |grad h|, m/m, per column
        c = meta["crop"]
        self.crop = np.zeros((self.ny, self.nx), bool)
        self.crop[c["j0"]:c["j0"] + c["n"], c["i0"]:c["i0"] + c["n"]] = True

    def masks(self, w_ref, w_thr):
        """Region masks (bool, interior shape) for the reference vertical velocity `w_ref`."""
        f, agl = self.fluid, self.agl
        m = {"domain": f.copy(),
             "launch": f & self.crop[None] & (agl <= LAUNCH_AGL_MAX)}
        for name, (lo, hi) in AGL_BANDS.items():
            m[name] = f & (agl >= lo) & (agl < hi)
        steep = (self.slope >= SLOPE_MIN)[None]
        m["slopes"] = f & steep & (agl >= SLOPE_AGL[0]) & (agl < SLOPE_AGL[1])
        m["thermals"] = (f & ~steep & (agl >= THERMAL_AGL[0]) & (agl < THERMAL_AGL[1])
                         & (w_ref > w_thr))
        return m


def load_uvw(state_json, geom):
    """u, v, w, th of a snapshot as float64 interior arrays."""
    meta, arr = read_pair(state_json, ("u", "v", "w", "th"))
    nzh, nyh, nxh = geom.dims
    return {k: interior(a, nzh, nyh, nxh).astype(np.float64) for k, a in arr.items()}


def deviation(f, ref, masks, geom):
    """Per region: max and rms of |d(u,v)| and |dw| (m/s), and cell count.

    Extra `dwt_*`: the same for the along-terrain vertical speed wt = w + u*hx + v*hy (hx, hy: terrain gradient),
    which is what a pilot on a slope feels; the lowest fluid cell has w = 0 by the staggering.
    """
    du = np.hypot(f["u"] - ref["u"], f["v"] - ref["v"])
    dw = np.abs(f["w"] - ref["w"])
    dwt = np.abs((f["w"] - ref["w"]) + (f["u"] - ref["u"]) * geom.hx[None] + (f["v"] - ref["v"]) * geom.hy[None])
    out = {}
    for name, m in masks.items():
        n = int(m.sum())
        if n == 0:
            out[name] = dict(du_max=0.0, du_rms=0.0, dw_max=0.0, dw_rms=0.0, dwt_max=0.0, dwt_rms=0.0, n_cells=0)
            continue
        a, b, c = du[m], dw[m], dwt[m]
        out[name] = dict(du_max=float(a.max()), du_rms=float(np.sqrt(np.mean(a * a))),
                         dw_max=float(b.max()), dw_rms=float(np.sqrt(np.mean(b * b))),
                         dwt_max=float(c.max()), dwt_rms=float(np.sqrt(np.mean(c * c))), n_cells=n)
    return out


def flows(f, ref, masks, geom):
    """Signed errors (field minus ref, m/s) of the flows the pilot feels: thermal peak/mean w, slope mean w."""
    t, s = masks["thermals"], masks["slopes"]
    d = f["w"] - ref["w"]
    dt = d + (f["u"] - ref["u"]) * geom.hx[None] + (f["v"] - ref["v"]) * geom.hy[None]
    return dict(
        thermal_w_peak_err=float(f["w"][t].max() - ref["w"][t].max()) if t.any() else 0.0,
        thermal_w_mean_err=float(d[t].mean()) if t.any() else 0.0,
        slope_w_mean_err=float(d[s].mean()) if s.any() else 0.0,
        slope_wt_mean_err=float(dt[s].mean()) if s.any() else 0.0)
