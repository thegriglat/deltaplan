#!/usr/bin/env python3
"""Contract test for air-cascade step 0 (docs/contracts/air-cascade.md, R1 v1, R2 v1, R3 v1; PR-5: R2 v1-v3, R4 v2).

Stdlib only. Exit code 0 = contract holds, 1 = violation (messages on stderr).

    python3 check_contract.py --ref tests/atmosphere/fixtures/air_model/ref/flat_wind.json ...
    python3 check_contract.py --results tools/research/air_cascade/picard_rs/out
    python3 check_contract.py --crate
    python3 check_contract.py --state D/picard_rs/states/<name>.json ...   # R4 v2
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

CRATE = Path(__file__).resolve().parents[1]

R1_KEYS = ["case", "dims", "halo", "dx", "dz", "z_bot", "x0", "y0", "nx", "ny", "nz", "params",
           "case_params", "mg_levels_xyz", "criterion", "solution", "history", "arrays"]
R1_CONST = ["hc", "cell", "tu", "tv", "tw", "nu_bg", "Q", "gam", "cplz", "sp_u", "sp_w", "spc",
            "ubg", "vbg", "lam", "Kx", "Ky", "Kz", "fixed_u", "fixed_v", "b_u", "b_v"]
R1_SOL = ["sol_u", "sol_v", "sol_w", "sol_th", "sol_thd", "sol_p"]
R1_FULL3D = ["cell", "tu", "tv", "tw", "nu_bg", "Q", "sp_u", "sp_w", "spc", "ubg", "vbg",
             "Kx", "Ky", "Kz"] + R1_SOL
R1_CRIT = ["tol_mom_rms", "tol_th_rms", "tol_div_rms", "check_every"]
R1_HIST = ["it", "mom_rms", "th_rms", "thd_rms", "div_rms"]

R2_KEYS = ["format", "version", "case", "input", "profile", "threads", "dtype", "status", "iters",
           "iters_ref", "history", "history_ref", "dev", "time", "host"]
R2_DEV = ["u0", "u_rel", "th_abs", "p_rel", "div_rms", "div_rms_ref"]
R2_TIME = ["total_s", "setup_s", "ms_per_iter", "check_ms", "ns_per_cell_iter", "n_cells"]
R2_PHASES = ["mom", "heat", "proj", "kupd", "other"]
R2_HOST = ["cpu", "rustc", "git"]
R2_STOP = ["converged", "max_iters", "time_budget", "diverged"]
R2_V3 = ["stop", "tol_scale", "time_budget_s", "init", "snapshots", "residuals"]
R4_KEYS = ["format", "version", "case", "input", "it", "dims", "halo", "nx", "ny", "nz", "dtype",
           "residuals", "host", "arrays"]
R4_REQUIRED = ["u", "v", "w", "th", "thd", "p"]
R4_OPTIONAL = ["nu", "nuh"]
R2_HIST = ["it", "mom_rms", "mom_max", "th_rms", "thd_rms", "div_rms"]

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def need(d: dict, keys: list[str], where: str) -> None:
    for k in keys:
        if k not in d:
            err(f"{where}: no key '{k}'")


def check_ref(path: Path) -> None:
    """R1 v1: JSON keys, required arrays, offsets inside .bin, 3D lengths match dims."""
    d = json.loads(path.read_text())
    w = str(path)
    need(d, R1_KEYS, w)
    if errors:
        return
    binp = path.with_suffix(".bin")
    if not binp.exists():
        err(f"{w}: no {binp.name}")
        return
    n_f32 = binp.stat().st_size // 4
    nxh, nyh, nzh = d["dims"]
    h = d["halo"]
    if h != 1 or (nxh, nyh, nzh) != (d["nx"] + 2 * h, d["ny"] + 2 * h, d["nz"] + 2 * h):
        err(f"{w}: dims {d['dims']} vs nx/ny/nz {d['nx']},{d['ny']},{d['nz']} halo {h}")
    n3 = nxh * nyh * nzh
    arr = d["arrays"]
    for a in R1_CONST + R1_SOL:
        if a not in arr:
            err(f"{w}: no array '{a}'")
    for a, (off, ln) in arr.items():
        if off < 0 or off + ln > n_f32:
            err(f"{w}: array '{a}' [{off}, {ln}] beyond .bin ({n_f32} f32)")
    for a in R1_FULL3D:
        if a in arr and arr[a][1] != n3:
            err(f"{w}: array '{a}' length {arr[a][1]} != NX*NY*NZ {n3}")
    for a in [k for k in arr if k.startswith(("Cm_", "Ch"))]:
        if arr[a][1] != 7 * n3:
            err(f"{w}: stencil '{a}' length {arr[a][1]} != 7*N {7 * n3}")
    need(d["criterion"], R1_CRIT, w + ".criterion")
    need(d["solution"], ["status", "iters", "max_speed"], w + ".solution")
    if not isinstance(d["history"], list) or not d["history"]:
        err(f"{w}: history must be a non-empty list")
    else:
        need(d["history"][0], R1_HIST, w + ".history[0]")
    if "format" in d:  # exported case (AC-R2)
        if d["format"] != "ref-case" or d.get("version") != 1:
            err(f"{w}: format/version {d.get('format')}/{d.get('version')} != ref-case/1")
        need(d, ["source", "crop", "t_ref_s"], w)
        if "source" in d:
            need(d["source"], ["fixture", "U10", "heat", "dtype", "git"], w + ".source")


def finite_or_null(v) -> bool:
    return v is None or (isinstance(v, (int, float)) and math.isfinite(v))


def check_result(path: Path) -> None:
    """R2 v1/v2/v3: result JSON fields, enums, numbers."""
    d = json.loads(path.read_text())
    w = str(path)
    need(d, R2_KEYS, w)
    if errors and any(e.startswith(w) for e in errors):
        return
    if d["format"] != "picard-rs-result" or d["version"] not in (1, 2, 3):
        err(f"{w}: format/version {d['format']}/{d['version']}")
    if d["profile"] not in ("dev", "release"):
        err(f"{w}: profile {d['profile']}")
    if d["dtype"] not in ("f32", "f64"):
        err(f"{w}: dtype {d['dtype']}")
    if d["status"] not in ("ok", "max", "diverged"):
        err(f"{w}: status {d['status']}")
    if not isinstance(d["threads"], int) or d["threads"] < 1:
        err(f"{w}: threads {d['threads']}")
    need(d["dev"], R2_DEV, w + ".dev")
    need(d["time"], R2_TIME, w + ".time")
    need(d["host"], R2_HOST, w + ".host")
    for sec in ("dev", "time"):
        for k, v in d[sec].items():
            if k == "phase_ms":  # R2 v2 dict, checked in check_r2_v2
                continue
            if not finite_or_null(v):
                err(f"{w}: {sec}.{k} = {v!r} (number or null)")
    if not isinstance(d["history"], list):
        err(f"{w}: history must be a list")
    elif d["history"]:
        need(d["history"][0], R2_HIST, w + ".history[0]")
    if d["version"] >= 2:
        check_r2_v2(d, w)
    if d["version"] == 3:
        check_r2_v3(d, w)
    name = path.stem
    if not re.fullmatch(r".+_(dev|release)_t\d+", name):
        err(f"{w}: file name must be <case>_<profile>_t<threads>.json")


def check_r2_v2(d: dict, w: str) -> None:
    """R2 v2: time.phase_ms (5 keys, sum = ms_per_iter +-2 %) and history[].t_s (non-decreasing)."""
    ph = d["time"].get("phase_ms")
    if not isinstance(ph, dict) or sorted(ph) != sorted(R2_PHASES):
        err(f"{w}: time.phase_ms must have exactly keys {R2_PHASES}")
    else:
        bad = [k for k, v in ph.items()
               if not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0]
        if bad:
            err(f"{w}: time.phase_ms {bad} must be finite numbers >= 0")
        else:
            ms = d["time"]["ms_per_iter"]
            tot = sum(ph.values())
            if not isinstance(ms, (int, float)) or not ms > 0 or abs(tot / ms - 1) > 0.02:
                err(f"{w}: sum(phase_ms) {tot} != ms_per_iter {ms} (+-2 %)")
    last = -math.inf
    for i, h in enumerate(d["history"] if isinstance(d["history"], list) else []):
        t = h.get("t_s") if isinstance(h, dict) else None
        if not isinstance(t, (int, float)) or not math.isfinite(t) or t < last:
            err(f"{w}: history[{i}].t_s = {t!r} (finite, non-decreasing)")
            break
        last = t


def check_r2_v3(d: dict, w: str) -> None:
    """R2 v3: stop (enum), tol_scale, time_budget_s, init, snapshots, residuals."""
    need(d, R2_V3, w)
    if any(e.startswith(w) and "no key" in e for e in errors):
        return
    if d["stop"] not in R2_STOP:
        err(f"{w}: stop {d['stop']!r} not in {R2_STOP}")
    ts = d["tol_scale"]
    if not isinstance(ts, (int, float)) or not math.isfinite(ts) or ts <= 0:
        err(f"{w}: tol_scale {ts!r} must be a finite number > 0")
    tb = d["time_budget_s"]
    if tb is not None and (not isinstance(tb, (int, float)) or not math.isfinite(tb) or tb < 0):
        err(f"{w}: time_budget_s {tb!r} must be null or a number >= 0")
    if d["init"] is not None and not isinstance(d["init"], str):
        err(f"{w}: init must be null or a path string")
    sn = d["snapshots"]
    if not isinstance(sn, list) or not all(isinstance(x, str) for x in sn):
        err(f"{w}: snapshots must be a list of path strings")
    r = d["residuals"]
    if not isinstance(r, dict):
        err(f"{w}: residuals must be an object")
    else:
        need(r, R2_HIST, w + ".residuals")
        for k, v in r.items():
            if not finite_or_null(v):
                err(f"{w}: residuals.{k} = {v!r} (number or null)")
    status_of = {"converged": "ok", "max_iters": "max", "time_budget": "max", "diverged": "diverged"}
    if d["stop"] in status_of and d["status"] != status_of[d["stop"]]:
        err(f"{w}: status {d['status']!r} does not match stop {d['stop']!r}")


def check_state(path: Path) -> None:
    """R4 v2: state JSON + .bin (float32 LE), arrays u, v, w, th, thd, p (+ nu, nuh), sizes, finite."""
    from array import array
    w = str(path)
    d = json.loads(path.read_text())
    need(d, R4_KEYS, w)
    if any(e.startswith(w) and "no key" in e for e in errors):
        return
    if d["format"] != "picard-rs-state" or d["version"] != 2 or d["dtype"] != "f32":
        err(f"{w}: format/version/dtype {d['format']}/{d['version']}/{d['dtype']}")
    dims = d["dims"]
    if not (isinstance(dims, list) and len(dims) == 3 and all(isinstance(x, int) and x > 0 for x in dims)):
        err(f"{w}: dims {dims!r}")
        return
    if d["halo"] != 1 or [d["nx"], d["ny"], d["nz"]] != [x - 2 for x in dims]:
        err(f"{w}: dims {dims} do not match halo 1 and nx/ny/nz")
    if not isinstance(d["it"], int) or d["it"] < 0:
        err(f"{w}: it {d['it']!r}")
    if d["residuals"] is not None:
        if not isinstance(d["residuals"], dict):
            err(f"{w}: residuals must be null or an object")
        else:
            need(d["residuals"], R2_HIST, w + ".residuals")
    n3 = dims[0] * dims[1] * dims[2]
    arrays = d["arrays"]
    for k in R4_REQUIRED:
        if k not in arrays:
            err(f"{w}: arrays has no '{k}'")
    for k in arrays:
        if k not in R4_REQUIRED + R4_OPTIONAL:
            err(f"{w}: unknown array '{k}'")
    binp = path.with_suffix(".bin")
    if not binp.exists():
        err(f"{binp}: missing")
        return
    raw = binp.read_bytes()
    nf = len(raw) // 4
    if len(raw) % 4:
        err(f"{binp}: size {len(raw)} is not a multiple of 4")
    data = array("f")
    data.frombytes(raw[: nf * 4])
    if sys.byteorder == "big":
        data.byteswap()
    for k, ent in arrays.items():
        if not (isinstance(ent, list) and len(ent) == 2 and all(isinstance(x, int) for x in ent)):
            err(f"{w}: arrays.{k} = {ent!r} (need [offset, length])")
            continue
        off, ln = ent
        if ln != n3 or off < 0 or off + ln > nf:
            err(f"{w}: arrays.{k} [{off}, {ln}] (cells {n3}, .bin {nf} float32)")
            continue
        if not math.isfinite(math.fsum(data[off: off + ln])):
            err(f"{w}: array {k} has non-finite values")


def check_crate() -> None:
    """R3 v1: package layout, release profile, no target-cpu / rustflags."""
    cargo = CRATE / "Cargo.toml"
    if not cargo.exists():
        err(f"{cargo}: missing")
        return
    t = cargo.read_text()
    if not re.search(r'^name\s*=\s*"picard_rs"', t, re.M):
        err("Cargo.toml: package name must be picard_rs")
    if not re.search(r'^edition\s*=\s*"2024"', t, re.M):
        err("Cargo.toml: edition must be 2024")
    m = re.search(r"^\[profile\.release\]\s*\n((?:(?!^\[).*\n?)*)", t, re.M)
    if not m:
        err("Cargo.toml: no [profile.release]")
    else:
        body = m.group(1)
        for k, v in (("opt-level", "3"), ("lto", '"fat"'), ("codegen-units", "1"),
                     ("panic", '"abort"')):
            if not re.search(rf"^{re.escape(k)}\s*=\s*{re.escape(v)}\s*$", body, re.M):
                err(f"Cargo.toml [profile.release]: need {k} = {v}")
    if "target-cpu" in t:
        err("Cargo.toml: target-cpu is forbidden")
    for p in list(CRATE.glob(".cargo/config*")):
        err(f"{p}: .cargo/config is forbidden (rustflags)")
    gi = CRATE / ".gitignore"
    gtxt = gi.read_text() if gi.exists() else ""
    for k in ("target",):
        if not re.search(rf"^/?{k}/?\s*$", gtxt, re.M):
            err(f"{gi}: must ignore {k}/")
    src = CRATE / "src"
    if not (src / "lib.rs").exists():
        err("src/lib.rs missing")
    banned = re.compile(r"\bstatic\s+mut\b|\bthread_local!|\bRefCell\b|\bCell<|build_global\(")
    for f in src.rglob("*.rs"):
        txt = f.read_text()
        if not txt.lstrip().startswith("//!"):
            err(f"{f}: must start with a //! module comment (English)")
        for ln, line in enumerate(txt.splitlines(), 1):
            if banned.search(line) and not line.lstrip().startswith("//"):
                err(f"{f}:{ln}: hidden mutable state / global pool: {line.strip()}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", nargs="*", default=[], help="R1 case .json files")
    ap.add_argument("--results", nargs="*", default=[], help="R2 result dirs or files")
    ap.add_argument("--crate", action="store_true", help="check R3 (crate)")
    ap.add_argument("--state", nargs="*", default=[], help="R4 v2 state .json files")
    a = ap.parse_args()
    if not (a.ref or a.results or a.crate or a.state):
        ap.error("nothing to check")
    for p in a.ref:
        check_ref(Path(p))
    n_res = 0
    for p in a.results:
        pp = Path(p)
        files = sorted(pp.glob("*.json")) if pp.is_dir() else [pp]
        if not files:
            err(f"{pp}: no result JSON")
        for f in files:
            check_result(f)
            n_res += 1
    for p in a.state:
        check_state(Path(p))
    if a.crate:
        check_crate()
    for e in errors:
        print("CONTRACT FAIL:", e, file=sys.stderr)
    if not errors:
        print(f"contract OK (ref {len(a.ref)}, results {n_res}, states {len(a.state)}, crate {a.crate})")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
