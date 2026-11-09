#!/usr/bin/env python3
"""Contract test of picard-terrain (docs/contracts/picard-terrain.md), stdlib only.

Usage:
  check_contract.py selftest
  check_contract.py cases <case.json>...     PT1 v1 (+ PT2 v1 when params.cut_cells or name ends _cut)
  check_contract.py rows <rows.jsonl>...     PT4 v1
Exit 0 — all conform; 1 — violations (printed); 2 — usage.
"""
import json
import math
import os
import re
import sys
import tempfile
from array import array

R1_KEYS = ["case", "dims", "halo", "dx", "dz", "z_bot", "x0", "y0", "nx", "ny", "nz", "params",
           "criterion", "arrays"]
R1_ARRAYS = ["hc", "cell", "tu", "tv", "tw", "nu_bg", "Q", "gam", "cplz", "sp_u", "sp_w", "spc", "ubg",
             "vbg", "lam", "Kx", "Ky", "Kz", "fixed_u", "fixed_v", "b_u", "b_v"]
PT_KEYS = ["version", "site", "dx", "dz", "domain_m", "top_m", "U10", "wdir_deg", "z0", "heat", "source",
           "terrain", "probes"]
SITES = {"askervein", "kayancha", "perdigao_ne", "perdigao_sw"}
NAME_RE = re.compile(r"^(askervein|kayancha|perdigao_ne|perdigao_sw)_d(\d+|\d+p5)(_cut)?$")
CUT_ARRAYS = ["vf", "af_u", "af_v", "af_w"]
ROW_KEYS = ["format", "version", "task", "case", "site", "dx", "solver", "dtype", "cut_cells", "adv2",
            "limiter", "status", "iters", "max_iters", "final", "time", "r2", "state", "probes", "rotor",
            "masts_rmse", "note"]
STATUS = {"ok", "max", "diverged", "stalled"}
TOL = 1e-6


def data_dir():
    return os.environ.get("PICARD_TERRAIN_DATA", os.path.expanduser("~/data/picard_terrain"))


def read_arrays(json_path, d, names):
    binp = os.path.splitext(json_path)[0] + ".bin"
    size = os.path.getsize(binp)
    out = {}
    with open(binp, "rb") as f:
        for n in names:
            off, ln = d["arrays"][n]
            if (off + ln) * 4 > size:
                raise ValueError(f"array {n} past end of .bin")
            f.seek(off * 4)
            a = array("f")
            a.fromfile(f, ln)
            if sys.byteorder != "little":
                a.byteswap()
            out[n] = a
    return out


def check_case(path):
    err = []
    with open(path) as f:
        d = json.load(f)
    name = os.path.splitext(os.path.basename(path))[0]
    for k in R1_KEYS:
        if k not in d:
            err.append(f"R1 key missing: {k}")
    if err:
        return err
    if d.get("format") != "ref-case" or d.get("version") != 1:
        err.append("format/version must be ref-case/1")
    if d.get("case") != name:
        err.append(f"case {d.get('case')!r} != file name {name!r}")
    m = NAME_RE.match(name)
    if not m:
        err.append(f"bad case name {name!r}")
    nx, ny, nz = d["dims"]
    n3 = nx * ny * nz
    if d["halo"] != 1 or [d["nx"] + 2, d["ny"] + 2, d["nz"] + 2] != [nx, ny, nz]:
        err.append("dims must be nx+2, ny+2, nz+2 with halo 1")
    for a in R1_ARRAYS:
        if a not in d["arrays"]:
            err.append(f"R1 array missing: {a}")
    pt = d.get("pt")
    if not isinstance(pt, dict):
        return err + ["key pt missing"]
    for k in PT_KEYS:
        if k not in pt:
            err.append(f"pt.{k} missing")
    if err:
        return err
    if pt["version"] != 1:
        err.append("pt.version != 1")
    if pt["site"] not in SITES or (m and m.group(1) != pt["site"]):
        err.append(f"pt.site {pt['site']!r} bad or differs from name")
    if abs(pt["dx"] - d["dx"]) > 1e-9 or abs(pt["dz"] - d["dz"]) > 1e-9:
        err.append("pt.dx/dz differ from case dx/dz")
    if m:
        dxn = float(m.group(2).replace("p5", ".5"))
        if abs(dxn - d["dx"]) > 1e-9:
            err.append(f"name dx {dxn} != dx {d['dx']}")
    if abs(d["dz"] - d["dx"] / 2) > 1e-9:
        err.append("dz must be dx/2")
    if pt["heat"] is not False:
        err.append("pt.heat must be false")
    if pt["U10"] is not None and pt["U10"] < 5:
        err.append("U10 < 5 m/s")
    for k in ("script", "args", "git"):
        if k not in pt["source"]:
            err.append(f"pt.source.{k} missing")
    t = pt["terrain"]
    for k in ("path", "dataset", "x0", "y0", "dx"):
        if k not in t:
            err.append(f"pt.terrain.{k} missing")
    if "path" in t and not os.path.exists(os.path.join(data_dir(), t["path"])):
        err.append(f"terrain file missing: {t['path']}")
    if t.get("dx") != 30:
        err.append("pt.terrain.dx must be 30")
    probes = pt["probes"]
    if not probes:
        err.append("pt.probes empty")
    names = {p.get("name") for p in probes}
    for p in probes:
        for k in ("name", "x", "y", "z_agl", "role", "pair"):
            if k not in p:
                err.append(f"probe key {k} missing in {p}")
        if p.get("role") not in ("target", "norm", "mast"):
            err.append(f"probe role bad: {p}")
        if p.get("pair") is not None and p["pair"] not in names:
            err.append(f"probe pair not found: {p['pair']}")
    cut = bool(d["params"].get("cut_cells", False)) or (m is not None and m.group(3) == "_cut")
    if m and m.group(3) == "_cut" and not d["params"].get("cut_cells", False):
        err.append("_cut case must have params.cut_cells = true")
    if cut:
        err += check_cut(path, d, n3)
    else:
        for a in CUT_ARRAYS:
            if a in d["arrays"]:
                err.append(f"cut array {a} in a case without cut_cells")
    if not err:
        arr = read_arrays(path, d, ["cell"])
        if len(arr["cell"]) != n3:
            err.append("cell length != NX*NY*NZ")
    return err


def check_cut(path, d, n3):
    err = []
    c = d["pt"].get("cut")
    if not isinstance(c, dict):
        return ["pt.cut missing"]
    for k in ("version", "vf_min", "samples_per_edge", "terrain_dx"):
        if k not in c:
            err.append(f"pt.cut.{k} missing")
    if err:
        return err
    if c["version"] != 1 or c["terrain_dx"] != 30 or not (0 < c["vf_min"] < 1):
        err.append("pt.cut version/terrain_dx/vf_min bad")
    for a in CUT_ARRAYS:
        if a not in d["arrays"]:
            err.append(f"cut array missing: {a}")
    if err:
        return err
    A = read_arrays(path, d, CUT_ARRAYS + ["cell", "tu", "tv", "tw"])
    nx, ny, nz = d["dims"]
    for a in CUT_ARRAYS + ["cell"]:
        if len(A[a]) != n3:
            return [f"{a} length != NX*NY*NZ"]
    vf, cell = A["vf"], A["cell"]
    vmin = c["vf_min"]
    bad = {"range": 0, "type_vf": 0, "face_zero": 0, "full_cell": 0}
    for a in CUT_ARRAYS:
        for x in A[a]:
            if not (-TOL <= x <= 1 + TOL) or math.isnan(x):
                bad["range"] += 1
    sx, sy, sz = 1, nx, nx * ny
    for fa, ft in (("af_u", "tu"), ("af_v", "tv"), ("af_w", "tw")):
        for q in range(n3):
            if A[ft][q] == 1 and A[fa][q] <= 0:
                bad["face_zero"] += 1
    for k in range(1, nz - 1):
        for j in range(1, ny - 1):
            for i in range(1, nx - 1):
                q = (k * ny + j) * nx + i
                if cell[q] == 2:
                    continue
                if (cell[q] == 1) != (vf[q] >= vmin):
                    bad["type_vf"] += 1
                if cell[q] == 1 and vf[q] >= 1 - TOL:
                    faces = (A["af_u"][q], A["af_u"][q + sx], A["af_v"][q], A["af_v"][q + sy],
                             A["af_w"][q], A["af_w"][q + sz])
                    if min(faces) < 1 - TOL:
                        bad["full_cell"] += 1
    for k, v in bad.items():
        if v:
            err.append(f"PT2 {k}: {v} violations")
    return err


def check_rows(path):
    err = []
    with open(path) as f:
        lines = [ln for ln in f if ln.strip()]
    if not lines:
        return ["no rows"]
    for n, ln in enumerate(lines, 1):
        r = json.loads(ln)
        e = []
        for k in ROW_KEYS:
            if k not in r:
                e.append(f"key {k} missing")
        if e:
            err += [f"row {n}: {x}" for x in e]
            continue
        if r["format"] != "pt-row" or r["version"] != 1:
            e.append("format/version")
        if r["site"] not in SITES:
            e.append("site")
        if r["solver"] not in ("picard_rs", "air3d") or r["dtype"] not in ("f32", "f64"):
            e.append("solver/dtype")
        if r["status"] not in STATUS:
            e.append("status")
        if not isinstance(r["cut_cells"], bool) or not isinstance(r["adv2"], bool):
            e.append("cut_cells/adv2 must be bool")
        if r["adv2"] and r["limiter"] not in (0, 1, 2, 3):
            e.append("limiter")
        if not r["adv2"] and r["limiter"] is not None:
            e.append("limiter must be null when adv2 false")
        for k in ("mom_rms", "th_rms", "div_rms"):
            if k not in r["final"]:
                e.append(f"final.{k}")
        for k in ("total_s", "ms_per_iter", "threads", "locked"):
            if k not in r["time"]:
                e.append(f"time.{k}")
        if not isinstance(r["probes"], list):
            e.append("probes must be list")
        else:
            for p in r["probes"]:
                for k in ("name", "z_agl", "S", "dS"):
                    if k not in p:
                        e.append(f"probe.{k}")
        if r["rotor"] is not None:
            for t in r["rotor"]:
                for k in ("transect", "present", "L_m", "depth_m"):
                    if k not in t:
                        e.append(f"rotor.{k}")
        err += [f"row {n}: {x}" for x in e]
    return err


def write_case(dirp, name, cut, broken=False):
    nx, ny, nz = 6, 5, 6
    n3 = nx * ny * nz
    arrays, buf = {}, array("f")

    def add(n, vals):
        arrays[n] = [len(buf), len(vals)]
        buf.extend(vals)

    cell = [0.0] * n3
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                q = (k * ny + j) * nx + i
                edge = i in (0, nx - 1) or j in (0, ny - 1) or k == nz - 1
                cell[q] = 0.0 if k == 0 else (2.0 if edge else 1.0)
    for a in R1_ARRAYS:
        add(a, cell if a == "cell" else ([1.0] * n3 if a in ("tu", "tv", "tw") else [0.0] * n3))
    if cut:
        vf = [1.0 if c == 1 else (1.0 if c == 2 else 0.0) for c in cell]
        if broken:
            vf[(2 * ny + 2) * nx + 2] = 0.01
        add("vf", vf)
        for a in ("af_u", "af_v", "af_w"):
            add(a, [1.0] * n3)
    os.makedirs(os.path.join(dirp, "terrain"), exist_ok=True)
    open(os.path.join(dirp, "terrain", "askervein.h5"), "wb").close()
    j = {"format": "ref-case", "version": 1, "case": name, "dims": [nx, ny, nz], "halo": 1, "dx": 50.0,
         "dz": 25.0, "z_bot": 0.0, "x0": 0.0, "y0": 0.0, "nx": nx - 2, "ny": ny - 2, "nz": nz - 2,
         "params": {"adv2": False, "limiter": 0, "cut_cells": cut},
         "criterion": {"tol_mom_rms": 1e-4, "tol_th_rms": 1e-4, "tol_div_rms": 1e-6, "check_every": 10},
         "arrays": arrays,
         "pt": {"version": 1, "site": "askervein", "dx": 50.0, "dz": 25.0, "domain_m": [200, 150],
                "top_m": 1000.0, "U10": 8.9, "wdir_deg": 210.0, "z0": 0.03, "heat": False,
                "source": {"script": "selftest", "args": [], "git": "0"},
                "terrain": {"path": "terrain/askervein.h5", "dataset": "h", "x0": 0, "y0": 0, "dx": 30},
                "probes": [{"name": "HT_10", "x": 1, "y": 1, "z_agl": 10, "role": "target", "pair": "RS_10"},
                           {"name": "RS_10", "x": 0, "y": 0, "z_agl": 10, "role": "norm", "pair": None}]}}
    if cut:
        j["pt"]["cut"] = {"version": 1, "vf_min": 0.1, "samples_per_edge": 8, "terrain_dx": 30}
    p = os.path.join(dirp, name + ".json")
    with open(p, "w") as f:
        json.dump(j, f)
    with open(os.path.join(dirp, name + ".bin"), "wb") as f:
        buf.tofile(f)
    return p


def selftest():
    with tempfile.TemporaryDirectory() as t:
        os.environ["PICARD_TERRAIN_DATA"] = t
        ok = [write_case(t, "askervein_d50", False), write_case(t, "askervein_d50_cut", True)]
        bad = write_case(os.path.join(t, "b"), "askervein_d50_cut", True, broken=True)
        os.makedirs(os.path.join(t, "b", "terrain"), exist_ok=True)
        fails = []
        for p in ok:
            e = check_case(p)
            if e:
                fails.append(f"good case rejected {p}: {e}")
        os.environ["PICARD_TERRAIN_DATA"] = os.path.join(t, "b")
        if not check_case(bad):
            fails.append("broken cut case accepted")
        row = {k: None for k in ROW_KEYS}
        row.update(format="pt-row", version=1, task="PT-0", case="askervein_d50", site="askervein", dx=50,
                   solver="picard_rs", dtype="f32", cut_cells=False, adv2=False, limiter=None, status="ok",
                   iters=10, max_iters=2000, final={"mom_rms": 0, "th_rms": 0, "div_rms": 0},
                   time={"total_s": 1, "ms_per_iter": 1, "threads": 8, "locked": True},
                   probes=[{"name": "HT_10", "z_agl": 10, "S": 9.0, "dS": 0.3}], note="")
        rp = os.path.join(t, "rows.jsonl")
        with open(rp, "w") as f:
            f.write(json.dumps(row) + "\n")
        if check_rows(rp):
            fails.append(f"good row rejected: {check_rows(rp)}")
        row["status"] = "bad"
        with open(rp, "w") as f:
            f.write(json.dumps(row) + "\n")
        if not check_rows(rp):
            fails.append("bad row accepted")
    for x in fails:
        print("FAIL", x)
    print("selftest", "OK" if not fails else "FAIL")
    return 0 if not fails else 1


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "selftest":
        return selftest()
    if argv[0] not in ("cases", "rows") or len(argv) < 2:
        print(__doc__)
        return 2
    fn = check_case if argv[0] == "cases" else check_rows
    total = 0
    for p in argv[1:]:
        try:
            e = fn(p)
        except Exception as ex:  # noqa: BLE001 — any read error is a violation
            e = [f"read error: {ex}"]
        print(f"{p}: {'OK' if not e else 'FAIL'}")
        for x in e:
            print("  ", x)
        total += len(e)
    print("contract", "OK" if total == 0 else f"FAIL ({total})")
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
