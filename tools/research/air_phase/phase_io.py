"""air-phase AP-3: план P2 → случаи, запись и чтение результатов P3 v2, контрольные точки тёплых цепочек.

Контракты — docs/contracts/air-phase.md (P2 v3, P3 v2, P4 v3, P5 v1). Здесь нет GPU: модуль импортируется в процессе
записи (пул CPU) и командой `status`.
"""
from __future__ import annotations

import dataclasses
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "proto"))
sys.path.insert(0, str(ROOT / "tools/research/air_synth/solver"))
import phase_plan_pb2 as pb  # noqa: E402

P3_CONTRACT = "P3 v2"
AGL_M = [25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000]
SNAP_LEVELS = [25, 600]
EDGE = 5
SERIES_ORDER = ("GRID", "SEPARATION", "ENVELOPE", "ENVELOPE_REAL", "SWEEP", "RELAX", "ERODED", "FIXED_U")   # порядок счёта (P5 + v2; FIXED_U — P2 v4, последняя)
SERIES_RANK = {pb.Series.Value(s): i for i, s in enumerate(SERIES_ORDER)}
STATUS = {"ok": 0, "converged": 0, "max": 1, "diverged": 2}
TARGET = {"final": 0, "late_mean": 1}
WALL = {pb.WALL_NONE: "none", pb.WALL_GROUND: "ground", pb.WALL_LOW_Z0: "low_z0", pb.WALL_SLIP: "slip"}
CRIT = {pb.ABSOLUTE: "abs", pb.RELATIVE: "rel", pb.CRITERION_UNSPECIFIED: "abs"}

CASES_DTYPE = np.dtype([
    ("case_id", "i8"), ("line_id", "i4"), ("k", "i4"), ("series", "i1"), ("relief_id", "i4"), ("fr", "f4"),
    ("froude_table", "f4"), ("u10", "f4"), ("u_sat", "f4"), ("wdir_from_deg", "f4"), ("n_bv", "f4"), ("z_i_agl_m", "f4"),
    ("heat_flux_wm2", "f4"), ("zi_over_L", "f4"), ("dx_m", "f4"), ("start_case_id", "i8"), ("status", "i1"),
    ("iters", "i4"), ("target", "i1"), ("late_n", "i2"), ("late_spread60_p90", "f4"), ("resid_final", "f4"),
    ("resid_rel_final", "f4"), ("seconds", "f4"), ("batch_size", "i2"), ("cond_id", "i4"),
    ("envelope_angle_deg", "f4"), ("envelope_wall", "i1")])


def data_root():
    return Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data")))


def git_commit():
    try:
        return subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def solver_version(batch_module=None):
    """P3: `s<n>-<7 знаков sha1 air3d/*.py и batch-модуля>`. Если batch_solver сам даёт solver_version() — она."""
    if batch_module is not None and hasattr(batch_module, "solver_version"):
        return batch_module.solver_version()
    bs = HERE / "batch_solver.py"
    h = hashlib.sha1()
    for p in sorted((ROOT / "tools/research/air3d").glob("*.py")) + ([bs] if bs.exists() else []):
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return "s1-" + h.hexdigest()[:7]


# ------------------------------------------------------------------ план
@dataclasses.dataclass
class Case:
    case_id: int
    line_id: int
    k: int
    fr: float
    series: int


def load_plan(plan_dir):
    """→ (Plan, sha256 plan.pb, {line_id: Line}, {relief_id: Relief}, [Case] по case_id)."""
    raw = (Path(plan_dir) / "plan.pb").read_bytes()
    plan = pb.Plan()
    plan.ParseFromString(raw)
    lines = {ln.line_id: ln for ln in plan.lines}
    rel = {r.relief_id: r for r in plan.reliefs}
    cases = []
    for ln in plan.lines:
        for k, fr in enumerate(np.frombuffer(ln.fr_f64, "<f8")):
            cases.append(Case(int(ln.first_case_id + k), ln.line_id, k, float(fr), int(ln.series)))
    cases.sort(key=lambda c: c.case_id)
    return plan, hashlib.sha256(raw).hexdigest(), lines, rel, cases


def series_filter(names):
    """'grid,sweep' → множество enum; None/'' — все."""
    if not names:
        return set(SERIES_RANK)
    out = set()
    for s in names.split(",") if isinstance(names, str) else names:
        s = s.strip().upper()
        if s:
            out.add(pb.Series.Value(s))
    return out


class Sources:
    """Рельефы (g100) и строки условий S2 — лениво, с кэшем."""

    def __init__(self, plan, rel):
        self.plan, self.rel = plan, rel
        self._g, self._cond = {}, {}

    def g100(self, relief_id):
        if relief_id not in self._g:
            import reliefs as R
            r = self.rel[relief_id]
            same = [x for x in self.rel.values() if x.corpus == r.corpus and x.relief_id not in self._g]
            got = R.load_corpus(data_root() / r.corpus, [x.corpus_relief_id for x in same])
            for x, (_, g100, _, _) in zip(same, got):
                self._g[x.relief_id] = np.asarray(g100, np.float64)
        return self._g[relief_id]

    def cond_row(self, conditions, corpus_relief_id, cond_id):
        if conditions not in self._cond:
            tab = {}
            for p in sorted((data_root() / conditions).glob("part-*.h5")):
                with h5py.File(p, "r") as h:
                    t = h["conditions/table"][:]
                for r in t:
                    tab[(int(r["relief_id"]), int(r["cond_id"]))] = {n: r[n].item() for n in t.dtype.names}
            self._cond[conditions] = tab
        return self._cond[conditions][(int(corpus_relief_id), int(cond_id))]


def case_physics(plan, line, relief, fr, src):
    """Физика входа случая (без решателя): dict u10, wdir, alpha, max_profile, u_sat, n_bv, z_i_agl_m, heat_flux_wm2,
    ctx, cond_row, override-поля CaseSpec. Fr → U10: U_sat = Fr·N·h, U10 = U_sat/max_profile (plan_build.u10_from_fr)."""
    c = plan.context
    if line.conditions:
        row = src.cond_row(line.conditions, relief.corpus_relief_id, line.cond_id)
        heat = None if line.heat_flux_wm2 < 0 else 0.0          # P2 v3: −1 — решение «h», 0 — «m»
        ctx = dict(lat=float(row["lat_deg"]), lon=float(row["lon_deg"]), month=int(row["month"]), day=int(row["day"]),
                   hour_local=float(row["hour_local"]), utc_offset=float(row["utc_offset_h"]))
        return dict(u10=float(row["u10_m_s"]), wdir=float(row["wind_from_deg"]), alpha=float(row["alpha"]),
                    max_profile=float(row["max_profile"]), u_sat=float(row["u_sat_m_s"]), n_bv=float(row["n_bv_s"]),
                    z_i_agl_m=float(row["z_i_m"]), heat_flux_wm2=float(row["hs_w_m2"]) if heat is None else 0.0,
                    ctx=ctx, cond_row=row, ov_n=None, ov_zi=None, ov_heat=heat, h_m=float(relief.h_m))
    h = float(relief.h_m)
    u_sat = fr * line.n_bv_s * h
    u10 = u_sat / c.max_profile
    zi = h / line.h_over_zi
    ctx = dict(lat=c.lat, lon=c.lon, month=c.month, day=c.day, hour_local=c.hour_local, utc_offset=c.utc_offset)
    return dict(u10=u10, wdir=float(line.wdir_from_deg), alpha=c.alpha, max_profile=c.max_profile, u_sat=u_sat,
                n_bv=float(line.n_bv_s), z_i_agl_m=zi, heat_flux_wm2=float(line.heat_flux_wm2), ctx=ctx, cond_row=None,
                ov_n=float(line.n_bv_s), ov_zi=zi, ov_heat=float(line.heat_flux_wm2), h_m=h)


def numerics_kwargs(nm):
    return dict(advection_order=int(nm.advection_order), omega_u=float(nm.omega_u), omega_k=float(nm.omega_k),
                k_floor_m2s=float(nm.k_floor_m2s) if nm.k_floor_m2s > 0 else None, criterion=CRIT[nm.criterion],
                tol=float(nm.tol) if nm.tol > 0 else None, max_outer=int(nm.max_outer), snap_from=int(nm.snap_from),
                snap_step=int(nm.snap_step), late_from=int(nm.late_from), late_step=int(nm.late_step),
                envelope_angle_deg=float(nm.envelope_angle_deg), envelope_wall=WALL[nm.envelope_wall],
                envelope_z0_m=float(nm.envelope_z0_m) if nm.envelope_z0_m > 0 else None)


# ------------------------------------------------------------------ результаты: чтение
def parts(d):
    return sorted(Path(d).glob("part-*.h5"))


def done_cases(d):
    """{case_id: (status, part_index)} — объединение `cases` по частям (источник правды P3)."""
    out = {}
    for p in parts(d):
        n = int(p.stem.split("-")[1])
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
        for cid, st in zip(c["case_id"].tolist(), c["status"].tolist()):
            if cid in out:
                raise RuntimeError(f"дубль case_id {cid} в {p.name}")
            out[cid] = (st, n)
    return out


def next_part_index(d):
    ps = parts(d)
    return int(ps[-1].stem.split("-")[1]) + 1 if ps else 0


def jsonl(path, rec):
    rec = dict(rec)
    rec.setdefault("t", datetime.datetime.now().isoformat(timespec="seconds"))
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, default=float) + "\n")


def _replace_fsync(tmp, path):
    with open(tmp, "rb") as f:
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ------------------------------------------------------------------ контрольные точки (тёплый старт)
def _get(x):
    return x.get() if hasattr(x, "get") and not isinstance(x, dict) else x


def state_to_dict(st):
    """State решателя → {имя: np.ndarray | скаляр} (dataclass, dict или объект с to_dict())."""
    if hasattr(st, "to_dict"):
        d = st.to_dict()
    elif dataclasses.is_dataclass(st):
        d = {f.name: getattr(st, f.name) for f in dataclasses.fields(st)}
    elif isinstance(st, dict):
        d = dict(st)
    else:
        raise TypeError(f"State: неизвестный вид {type(st)}")
    return {k: (np.asarray(_get(v)) if hasattr(v, "shape") else v) for k, v in d.items()}


def state_from_dict(d, solver):
    if hasattr(solver, "state_from_dict"):
        return solver.state_from_dict(d)
    cls = getattr(solver, "State", None)
    if cls is not None and dataclasses.is_dataclass(cls):
        return cls(**d)
    if cls is not None and hasattr(cls, "from_dict"):
        return cls.from_dict(d)
    return d


def ckpt_path(d, line_id):
    return Path(d) / "ckpt" / f"line-{line_id}.h5"


def write_ckpt(d, line_id, case_id, k, status, state_d):
    """Состояние случая k линии (float32, как дал решатель); status 2 — без состояния (следующий — холодный)."""
    p = ckpt_path(d, line_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(p) + ".tmp"
    with h5py.File(tmp, "w") as h:
        h.attrs.update(dict(line_id=line_id, case_id=case_id, k=k, status=status))
        g = h.create_group("state")
        for key, v in (state_d or {}).items():
            if isinstance(v, np.ndarray) and v.ndim > 0:
                g.create_dataset(key, data=v, compression="gzip", compression_opts=1, shuffle=True)
            elif v is not None:
                g.attrs[key] = v
    _replace_fsync(tmp, p)


def read_ckpt(d, line_id):
    """→ (case_id, k, status, state_dict) или None."""
    p = ckpt_path(d, line_id)
    if not p.exists():
        return None
    with h5py.File(p, "r") as h:
        st = {k: h["state"][k][...] for k in h["state"]}
        st.update({k: (v.item() if hasattr(v, "item") else v) for k, v in h["state"].attrs.items()})
        return int(h.attrs["case_id"]), int(h.attrs["k"]), int(h.attrs["status"]), st


def drop_ckpt(d, line_id):
    p = ckpt_path(d, line_id)
    if p.exists():
        p.unlink()


# ------------------------------------------------------------------ запись части (в процессе-писателе)
def _ds(h, name, a, chunk_case=True):
    a = np.asarray(a)
    kw = dict(track_times=False, compression="gzip", compression_opts=4, shuffle=True)
    if chunk_case and a.ndim >= 1 and a.shape[0] > 0:
        kw["chunks"] = (1,) + a.shape[1:]
    return h.create_dataset(name, data=a, **kw)


def _finite(name, a, diverged):
    a = np.asarray(a)
    if np.all(np.isfinite(a)):
        return a
    if diverged:
        return np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)
    raise ValueError(f"{name}: NaN/inf в несошедшемся решении — ошибка")


def order_features(f, wdir, u10, alpha, mp):
    import phase_stats as PS
    phi = np.radians(wdir)
    return PS.field_features(f, (-np.sin(phi), -np.cos(phi)), u10, alpha, mp, "f")


def upstream_profile(f, ground, wdir, edge=EDGE):
    """Колонна притока на сетке 400 м: клетка на линии через центр против ветра у края (edge клеток внутрь).
    → (agl, along, z_ground)."""
    import bubble as B
    phi = np.radians(wdir)
    e = (-np.sin(phi), -np.cos(phi))
    x0 = y0 = -19200.0
    r = 19200.0 - (edge + 0.5) * 400.0
    px, py = np.array([-e[0] * r]), np.array([-e[1] * r])
    along = (B.bilinear(f[0], x0, y0, 400.0, px, py) * e[0] + B.bilinear(f[1], x0, y0, 400.0, px, py) * e[1])[:, 0]
    zg = float(B.bilinear(np.asarray(ground, np.float64), x0, y0, 400.0, px, py)[0])
    return np.asarray(AGL_M, float), along, zg


def bubble_of(item):
    """bubble P3 для случая SEPARATION: окно 100 м (если есть) или поле 400 м."""
    import bubble as B
    phi = np.radians(item["wdir"])
    e = (-np.sin(phi), -np.cos(phi))
    f400 = item["fields"]
    up = upstream_profile(f400, item["hc"], item["wdir"])
    # AP-10: fr_local по невозмущённому профилю притока (колонна у губки при 2-м порядке и Fr ≤ 0,5 несёт выброс)
    inflow = (item["alpha"], item["max_profile"]) if item.get("alpha") is not None and item.get("max_profile") else None
    w = item.get("window")
    if w is not None:
        wf = np.asarray(w["fields"], np.float32)
        ny, nx = wf.shape[-2:]
        dx, x0, y0 = float(w["dx_m"]), float(w["x0_m"]), float(w["y0_m"])
        xs = x0 + dx / 2 + dx * np.arange(nx)
        ys = y0 + dx / 2 + dx * np.arange(ny)
        X, Y = np.meshgrid(xs, ys)
        if w.get("hc") is not None and np.asarray(w["hc"]).shape == (ny, nx):
            ground = np.asarray(w["hc"], np.float64)            # земля окна (блочное среднее h100 решателя)
        else:
            ground = B.bilinear(item["g100"], -19200.0, -19200.0, 100.0, X.ravel(), Y.ravel()).reshape(ny, nx)
        c = (float(w["brink_x_m"]), float(w["brink_y_m"])) if "brink_x_m" in w else None   # AP-10: окно может не содержать (0, 0)
        return B.bubble(wf, w["agl_m"], x0, y0, dx, ground, e, item["h_m"], item["u_sat"], item["n_bv"], up, center=c,
                        edge=0, inflow=inflow)
    return B.bubble(f400, AGL_M, -19200.0, -19200.0, 400.0, item["hc"], e, item["h_m"], item["u_sat"], item["n_bv"],
                    up, edge=EDGE, inflow=inflow)


def write_batch(job):
    """Процесс-писатель: параметры порядка, bubble, часть P3 (атомарно), затем контрольные точки и progress.jsonl.
    job = dict(dir, part, attrs, items=[...], ckpts=[(line_id, case_id, k, status, state_dict)], drops=[line_id]).
    → dict(part, bytes, n)."""
    d = Path(job["dir"])
    items = sorted(job["items"], key=lambda it: it["rec"]["case_id"])
    n = job["part"]
    path = d / f"part-{n:05d}.h5"
    if items:
        m = len(items)
        recs = np.zeros(m, CASES_DTYPE)
        F, hc, hf, hbl, heff, orders, bubbles = [], [], [], [], [], [], []
        T = max(len(it["trace"]["iter"]) for it in items)
        tr_it = np.full((m, T), -1, np.int32)
        tr_res = np.zeros((m, T), np.float32)
        tr_du = np.zeros((m, T), np.float32)
        tr_f = np.zeros((m, T, 3, 2, 96, 96), np.float16)
        win = []
        any_env = any(it["h_eff"] is not None for it in items)
        any_sep = any(it["rec"]["series"] == pb.SEPARATION for it in items)
        for j, it in enumerate(items):
            dv = it["rec"]["status"] == 2
            for name in CASES_DTYPE.names:
                recs[j][name] = it["rec"][name]
            f = _finite("fields/f", it["fields"], dv).astype(np.float32)
            it["fields"] = f
            F.append(f.astype(np.float16))
            if not np.all(np.isfinite(F[-1])):
                raise ValueError(f"fields/f случая {it['rec']['case_id']}: выход за float16")
            hc.append(np.asarray(it["hc"], np.float32))
            hf.append(_finite("heat_flux", it["heat_flux"], dv).astype(np.float16))
            hbl.append(_finite("hbl", it["hbl"], dv).astype(np.float16))
            heff.append(np.asarray(it["h_eff"] if it["h_eff"] is not None else it["hc"], np.float32))
            t = it["trace"]
            nt = len(t["iter"])
            tr_it[j, :nt] = t["iter"]
            tr_res[j, :nt] = _finite("trace/resid", t["resid"], True)
            tr_du[j, :nt] = _finite("trace/du_max", t["du_max"], True)
            if nt:
                tr_f[j, :nt] = _finite("trace/fields", t["fields"], dv).astype(np.float16)
            orders.append(order_features(f, it["wdir"], it["u10"], it["alpha"], it["max_profile"]))
            if any_sep:
                bubbles.append(bubble_of(it) if it["rec"]["series"] == pb.SEPARATION else np.zeros((), _bubble_dtype()))
            if it.get("window") is not None:
                win.append((it["rec"]["case_id"], it["window"]))
        odt = np.dtype([(k, "f4") for k in orders[0]])
        order = np.array([tuple(o[k] for k in odt.names) for o in orders], odt)
        tmp = str(path) + ".tmp"
        with h5py.File(tmp, "w") as h:
            for k, v in job["attrs"].items():
                h.attrs[k] = v
            h.attrs["contract"], h.attrs["kind"] = P3_CONTRACT, "phase"
            h.attrs["n_records"] = m
            h.attrs["agl_m"] = np.array(AGL_M, np.int32)
            h.attrs["snap_levels_agl_m"] = np.array(SNAP_LEVELS, np.int32)
            h.attrs["created"] = datetime.datetime.now().isoformat(timespec="seconds")
            _ds(h, "cases", recs, chunk_case=False)
            fs = _ds(h, "fields/f", np.stack(F))
            fs.attrs["channels"] = "u,v,w,theta_prime"
            fs.attrs["axes"] = "case, channel, agl, j (north), i (east)"
            _ds(h, "inputs/hc", np.stack(hc))
            _ds(h, "inputs/heat_flux", np.stack(hf))
            _ds(h, "inputs/hbl", np.stack(hbl))
            if any_env:
                _ds(h, "inputs/h_eff", np.stack(heff))
            _ds(h, "trace/iter", tr_it)
            _ds(h, "trace/resid", tr_res)
            _ds(h, "trace/du_max", tr_du)
            _ds(h, "trace/fields", tr_f).attrs["axes"] = "case, snap, channel (u,v,w), level (25, 600 m AGL), j, i"
            _ds(h, "order", order, chunk_case=False)
            if any_sep:
                _ds(h, "bubble", np.array(bubbles, _bubble_dtype()), chunk_case=False)
            if win:
                shp = np.max([np.asarray(w["fields"]).shape for _, w in win], axis=0)
                wf = np.zeros((len(win),) + tuple(shp), np.float16)
                for q, (_, w) in enumerate(win):
                    a = np.asarray(w["fields"], np.float32)
                    wf[q][tuple(slice(0, s) for s in a.shape)] = _finite("window/fields", a, True).astype(np.float16)
                ds = _ds(h, "window/fields", wf)
                ds.attrs["dx_m"] = float(win[0][1]["dx_m"])
                ds.attrs["agl_m"] = np.asarray(win[0][1]["agl_m"], np.float32)
                ds.attrs["axes"] = "case, channel (u,v,w,theta_prime), agl, j, i; x0_m/y0_m — угол окна"
                h.create_dataset("window/case_id", data=np.array([c for c, _ in win], np.int64))
                h.create_dataset("window/x0_m", data=np.array([w["x0_m"] for _, w in win], np.float64))
                h.create_dataset("window/y0_m", data=np.array([w["y0_m"] for _, w in win], np.float64))
                h.create_dataset("window/shape", data=np.array([np.asarray(w["fields"]).shape for _, w in win], np.int32))
                if all(w.get("hc") is not None for _, w in win):
                    hw = np.zeros((len(win),) + tuple(shp[-2:]), np.float32)
                    for q, (_, w) in enumerate(win):
                        a = np.asarray(w["hc"], np.float32)
                        hw[q, : a.shape[0], : a.shape[1]] = a
                    _ds(h, "window/hc", hw).attrs["what"] = "земля окна, м н. у. м."
                st = {"ok": 0, "converged": 0, "max": 1, "diverged": 2}
                h.create_dataset("window/status", data=np.array([st.get(w.get("status"), -1) if isinstance(w.get("status"), str)
                                                                 else int(w.get("status", -1)) for _, w in win], np.int8))
                h.create_dataset("window/iters", data=np.array([int(w.get("iters", -1)) for _, w in win], np.int32))
                for key in ("brink_x_m", "brink_y_m", "downwind_fit_over_h"):
                    h.create_dataset(f"window/{key}", data=np.array([float(w.get(key, np.nan)) for _, w in win], np.float32))
        _replace_fsync(tmp, path)
    for (line_id, case_id, k, status, st) in job["ckpts"]:
        write_ckpt(d, line_id, case_id, k, status, st)
    for line_id in job["drops"]:
        drop_ckpt(d, line_id)
    nbytes = path.stat().st_size if items else 0
    for it in items:
        r = it["rec"]
        jsonl(d / "progress.jsonl", dict(case_id=int(r["case_id"]), line_id=int(r["line_id"]), k=int(r["k"]),
                                         series=pb.Series.Name(int(r["series"])), status=int(r["status"]),
                                         iters=int(r["iters"]), seconds=float(r["seconds"]), part=n,
                                         batch_size=int(r["batch_size"])))
    return dict(part=n, bytes=nbytes, n=len(items))


def _bubble_dtype():
    import bubble as B
    return B.BUBBLE_DTYPE
