"""Оценка и отчёт пилота (контракт П3): python -m pilotnn.evaluate <eval|report> <каталог прогона> <каталог отчёта>

eval   — предсказания основной сети и сетей кривой на отложенных/тестовых случаях, базовые линии, ключевые
         числа на 60 м над стартами, сравнение с целями air-lite, экспорт ONNX + ORT ↔ PyTorch + время ORT CPU
         → <отчёт>/metrics.json, <отчёт>/eval_fields.npz (поля для картинок).
report — картинки (срезы «решатель / сеть / разница», кривая (в), распределения ошибок) и report.md;
         вывод по ориентирам ШП — правилом из чисел (config.yaml → eval), без ручных вставок.

Ключевые числа (П3): высота 60 м над рельефом — линейно между 50 и 75 м; по горизонтали — билинейно по
центрам клеток. В каждой точке оценки (старты места, см. data.Dataset.starts):
  wind   — |Δ(u, v)| с нагревом (ошибка вектора горизонтального ветра), м/с; speed — |Δ|скорости|| с нагревом;
  lift_m — |Δw| без нагрева; lift_h — |Δw| с нагревом, м/с;
  rms1km — RMS |Δ(u, v)| с нагревом по клеткам, чьи центры в 1 км от точки, м/с.
Базовые линии: «приток» — профиль притока без поправки (цель П2 = 0: u = Ub(a)·ê, w = 0, θ′ = 0);
«среднее» — среднее цели П2 по обучающим случаям (по каналу и высоте, без зависимости от места).
"""
from __future__ import annotations

import os

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402

from . import common as C  # noqa: E402
from . import model as M  # noqa: E402
from . import prep as P  # noqa: E402
from .data import Dataset, solver_status  # noqa: E402
from .train import load_arrays  # noqa: E402

CODE_FILES = [Path(__file__), Path(P.__file__), Path(M.__file__)]
SETS = ("train", "newcond", "holdout_place", "holdout_proc")
SET_NAMES = dict(train="обучающие (проверка, что учится)", newcond="(а) новые условия, знакомый рельеф",
                 holdout_place="(б) незнакомое место (ongudai)", holdout_proc="(б′) отложенные процедурные рельефы")
PREDS = ("net", "inflow", "mean")
PRED_NAMES = dict(net="сеть", inflow="профиль притока", mean="среднее по набору")
METRICS = ("wind", "speed", "lift_m", "lift_h", "rms1km")
MAX_TRAIN_EVAL = 60


class Prog:
    def __init__(self, d: Path, total, unit, label):
        self.p, self.total, self.unit, self.label, self.t = d / "progress.json", total, unit, label, 0.0

    def put(self, done, force=False):
        if force or time.time() - self.t > 1:
            self.t = time.time()
            C.atomic_write_json(self.p, dict(done=done, total=self.total, unit=self.unit, label=self.label, t=self.t))


def file_sha(p: Path):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()[:16]


def load_net(sub: Path, dev):
    task = json.loads((sub / "task.json").read_text())
    ck = torch.load(sub / "ckpt" / "best.pt", map_location="cpu", weights_only=False)
    n_out = ck["model"]["out_scale"].numel()
    n_maps = ck["model"]["inp.conv.weight"].shape[1]
    n_film = ck["model"]["emb.0.weight"].shape[1]
    m = M.build(task["train"]["model"], n_maps, n_film, n_out)
    m.load_state_dict(ck["model"])
    return m.to(dev).eval(), task


@torch.no_grad()
def predict(model, X, F, dev, bs=8):
    out = []
    for i in range(0, len(X), bs):
        out.append(model(torch.from_numpy(X[i:i + bs]).to(dev), torch.from_numpy(F[i:i + bs]).to(dev)).float().cpu().numpy())
    return np.concatenate(out)


# ---------------------------------------------------------------------------------------------- геометрия
def level_weights(agl, a_key):
    agl = list(agl)
    for i in range(len(agl) - 1):
        if agl[i] <= a_key <= agl[i + 1]:
            t = (a_key - agl[i]) / (agl[i + 1] - agl[i])
            return i, 1 - t, t
    raise ValueError(a_key)


def at_level(F, lw):
    i, w0, w1 = lw
    return w0 * F[..., i, :, :] + w1 * F[..., i + 1, :, :]


def bilinear(F2, x, y, g):
    fi = (x - g["x0"]) / g["dx"] - 0.5
    fj = (y - g["y0"]) / g["dx"] - 0.5
    i0 = int(np.clip(np.floor(fi), 0, F2.shape[-1] - 2)); j0 = int(np.clip(np.floor(fj), 0, F2.shape[-2] - 2))
    a, b = float(np.clip(fi - i0, 0, 1)), float(np.clip(fj - j0, 0, 1))
    return ((1 - b) * ((1 - a) * F2[..., j0, i0] + a * F2[..., j0, i0 + 1])
            + b * ((1 - a) * F2[..., j0 + 1, i0] + a * F2[..., j0 + 1, i0 + 1]))


def grid_of(row, shape):
    d = row.get("d400") or {}
    dx = float(d.get("dx", 400.0))
    return dict(dx=dx, x0=float(d.get("x0", -0.5 * shape[-1] * dx)), y0=float(d.get("y0", -0.5 * shape[-2] * dx)))


def key_numbers(truth, pred, starts, g, lw, radius):
    """→ список dict по точкам оценки (ошибки предсказания против решателя)."""
    th, ph = at_level(truth["h"], lw), at_level(pred["h"], lw)        # (4, ny, nx)
    tm, pm = at_level(truth["m"], lw), at_level(pred["m"], lw)
    ny, nx = th.shape[-2:]
    xc = g["x0"] + (np.arange(nx) + 0.5) * g["dx"]
    yc = g["y0"] + (np.arange(ny) + 0.5) * g["dx"]
    Xc, Yc = np.meshgrid(xc, yc)
    dvec = np.hypot(ph[0] - th[0], ph[1] - th[1])
    out = []
    for (x, y) in starts:
        T = bilinear(th, x, y, g); Pp = bilinear(ph, x, y, g)
        Tm = bilinear(tm, x, y, g); Pm = bilinear(pm, x, y, g)
        near = np.hypot(Xc - x, Yc - y) <= radius
        out.append(dict(wind=float(math.hypot(Pp[0] - T[0], Pp[1] - T[1])),
                        speed=float(abs(math.hypot(Pp[0], Pp[1]) - math.hypot(T[0], T[1]))),
                        lift_m=float(abs(Pm[2] - Tm[2])), lift_h=float(abs(Pp[2] - T[2])),
                        rms1km=float(np.sqrt(np.mean(dvec[near] ** 2))) if near.any() else float("nan"),
                        true_speed=float(math.hypot(T[0], T[1])), true_w_m=float(Tm[2]), true_w_h=float(T[2])))
    return out


def field_rms(truth, pred, lw, edge):
    th, ph = at_level(truth["h"], lw), at_level(pred["h"], lw)
    tm, pm = at_level(truth["m"], lw), at_level(pred["m"], lw)
    s = (slice(edge, -edge or None),) * 2
    return dict(f_wind=float(np.sqrt(np.mean((np.hypot(ph[0] - th[0], ph[1] - th[1])[s]) ** 2))),
                f_lift_m=float(np.sqrt(np.mean(((pm[2] - tm[2])[s]) ** 2))),
                f_lift_h=float(np.sqrt(np.mean(((ph[2] - th[2])[s]) ** 2))))


# ------------------------------------------------------------------------------------- цели air-lite (build.py)
def airlite_targets(f, row, edge):
    """Цели air-lite (build.py) на области: механика (U10 ≥ 0,5) — вдоль/поперёк ветра и w, м/с;
    нагрев — добавка (с нагревом − без) вдоль/поперёк, w_conv, θ′. Все высоты, без edge клеток у края."""
    a = math.radians(float(row["wdir"]))
    ex, ey = -math.sin(a), -math.cos(a)
    s = (slice(None), slice(edge, -edge or None), slice(edge, -edge or None))
    mm, hh = f["m"], f["h"]
    out = {}
    if float(row["U10"]) >= 0.5:
        out["t_mpar"] = (mm[0] * ex + mm[1] * ey)[s]
        out["t_mper"] = (-mm[0] * ey + mm[1] * ex)[s]
        out["t_mw"] = mm[2][s]
    du, dv = hh[0] - mm[0], hh[1] - mm[1]
    out["t_cpar"] = (du * ex + dv * ey)[s]
    out["t_cper"] = (-du * ey + dv * ex)[s]
    out["t_cw"] = (hh[2] - mm[2])[s]
    out["t_th"] = hh[3][s]
    return out


class Pooled:
    def __init__(self):
        self.d = {}

    def add(self, t, p):
        for k in t:
            e = self.d.setdefault(k, [0, 0.0, 0.0, 0.0])        # n, Σ(p−t)², Σt, Σt²
            tt, pp = t[k].astype(np.float64).ravel(), p[k].astype(np.float64).ravel()
            e[0] += tt.size; e[1] += float(np.sum((pp - tt) ** 2)); e[2] += float(tt.sum()); e[3] += float(np.sum(tt ** 2))

    def result(self):
        r = {}
        for k, (n, se, s1, s2) in self.d.items():
            var = s2 / n - (s1 / n) ** 2
            rmse = math.sqrt(se / n)
            r[k] = dict(n=n, rmse=rmse, std=math.sqrt(max(var, 0)), skill=1 - rmse ** 2 / var if var > 0 else None)
        return r


def agg(rows, key):
    v = np.array([r[key] for r in rows if np.isfinite(r[key])])
    if v.size == 0:
        return None
    return dict(n=int(v.size), median=float(np.median(v)), p90=float(np.percentile(v, 90)), mean=float(v.mean()))


def summarize(rows, ec):
    out = {}
    for k in METRICS:
        out[k] = agg(rows, k)
    if rows:
        w = np.array([r["wind"] for r in rows]); lm = np.array([r["lift_m"] for r in rows]); lh = np.array([r["lift_h"] for r in rows])
        out["frac_wind_ok"] = float(np.mean(w < ec["wind_ok_ms"]))
        out["frac_lift_m_ok"] = float(np.mean(lm < ec["lift_ok_ms"]))
        out["frac_lift_h_ok"] = float(np.mean(lh < ec["lift_ok_ms"]))
        out["frac_all_ok"] = float(np.mean((w < ec["wind_ok_ms"]) & (lm < ec["lift_ok_ms"]) & (lh < ec["lift_ok_ms"])))
        out["n_points"] = len(rows)
        out["n_cases"] = len({r["case"] for r in rows})
    return out


# ------------------------------------------------------------------------------------------------ ONNX
def export_onnx(model, X, F, path: Path, n_rep, threads):
    import onnxruntime as ort
    m = model.float().cpu().eval()
    xs, fs = torch.from_numpy(X[:1]), torch.from_numpy(F[:1])
    tmp = path.with_name(path.name + ".tmp")
    torch.onnx.export(m, (xs, fs), str(tmp), opset_version=17, input_names=["maps", "nums"], output_names=["out"],
                      dynamo=False)
    os.replace(tmp, path)
    res = dict(path=str(path), opset=17, size_mb=path.stat().st_size / 1e6, inputs=dict(maps=list(xs.shape), nums=list(fs.shape)))
    errs = []
    with torch.no_grad():
        for i in range(min(3, len(X))):
            ref = m(torch.from_numpy(X[i:i + 1]), torch.from_numpy(F[i:i + 1])).numpy()
            so = ort.SessionOptions(); so.intra_op_num_threads = 4
            s = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])
            o = s.run(None, dict(maps=X[i:i + 1], nums=F[i:i + 1]))[0]
            errs.append(float(np.max(np.abs(o - ref))))
    res["ort_vs_torch_max_abs"] = max(errs)
    res["ort_vs_torch_ok"] = max(errs) <= 1e-4
    res["time_ms"] = {}
    for th in threads:
        so = ort.SessionOptions(); so.intra_op_num_threads = int(th); so.inter_op_num_threads = 1
        s = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])
        feed = dict(maps=X[:1], nums=F[:1])
        for _ in range(3):
            s.run(None, feed)
        ts = []
        for _ in range(n_rep):
            t0 = time.perf_counter(); s.run(None, feed); ts.append((time.perf_counter() - t0) * 1000)
        res["time_ms"][str(th)] = dict(median=float(np.median(ts)), min=float(np.min(ts)))
    try:
        cpu = [l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")][0]
    except Exception:  # noqa: BLE001
        cpu = "?"
    res["cpu"] = cpu
    res["onnxruntime"] = ort.__version__
    return res


# ------------------------------------------------------------------------------------------------ eval
def run_eval(run: Path, rep: Path):
    sig = C.Signals()
    cfg = json.loads((run / "config.json").read_text())
    ec = cfg["eval"]
    split = json.loads((run / "split.json").read_text())
    info = json.loads((run / "run_info.json").read_text())
    ds = Dataset(info["dataset_root"])
    prep_dir = Path(info["prep_dir"])
    subs = [run / "main"] + [run / c["dir"] for c in info["curve"]]
    inputs_hash = C.sha(dict(ck=[file_sha(s / "ckpt" / "best.pt") for s in subs], split=split, eval=ec,
                             code=C.code_hash(*CODE_FILES)))
    rep.mkdir(parents=True, exist_ok=True)
    st = C.step_state(rep, inputs_hash)
    if st == "done" and (rep / "metrics.json").exists():
        print("оценка: уже готова — пропуск")
        return C.EXIT_OK
    C.write_manifest(rep, "оценка и отчёт пилота (П3)", inputs_hash, False, run=str(run))
    C.clean_tmp(rep)
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    dev = torch.device("cuda")
    rows_by_id = {r["id"]: r for r in ds.case_rows()}
    agl = ds.agl
    lw = level_weights(agl, ec["agl_key_m"])
    rng = np.random.default_rng(split["seed"])
    tr = list(split["train_ids"])
    tr_eval = sorted(rng.choice(tr, min(MAX_TRAIN_EVAL, len(tr)), replace=False).tolist()) if tr else []
    sets = dict(train=tr_eval, newcond=split["newcond_ids"], holdout_place=split["holdout_place_ids"],
                holdout_proc=split["holdout_proc_ids"])
    hold_all = split["holdout_place_ids"] + split["holdout_proc_ids"]
    n_total = sum(len(v) for v in sets.values()) + len(info["curve"]) * len(hold_all) + 1
    prog = Prog(rep, n_total, "случаев", "оценка")
    done = 0
    # среднее цели по обучению (базовая линия «среднее»)
    ysum, ycount = None, 0
    for cid in split["train_ids"]:
        with np.load(prep_dir / "cases" / f"{cid}.npz") as z:
            y = z["Y"].astype(np.float64)
        ysum = y.mean(axis=(1, 2)) if ysum is None else ysum + y.mean(axis=(1, 2))
        ycount += 1
    ymean = (ysum / max(ycount, 1)).astype(np.float32)
    lock = C.GpuLock(sig)
    t_eval0 = time.time()
    result = dict(sets={}, curve=[], airlite_net={}, per_point=[], per_case={}, ymean=ymean.tolist())
    keep_fields = {}
    fig_pick = pick_figure_cases(sets, rows_by_id, ec["n_slice_figures"])
    with lock:
        model, task = load_net(run / "main", dev)
        for sname, ids in sets.items():
            pts = {p: [] for p in PREDS}
            pooled = Pooled()
            if not ids:
                result["sets"][sname] = None
                continue
            X, F, _, metas = load_arrays(prep_dir, ids, with_y=False)
            Yp = predict(model, X, F, dev)
            for i, cid in enumerate(ids):
                row = rows_by_id[cid]
                z = ds.load(cid)
                truth = dict(m=z["d400_m"].astype(np.float64), h=z["d400_h"].astype(np.float64))
                g = grid_of(row, truth["h"].shape)
                starts = ds.starts(row["loc"])
                preds = dict(net=P.to_physical(Yp[i], metas[i], agl), inflow=P.to_physical(np.zeros_like(Yp[i]), metas[i], agl),
                             mean=P.to_physical(np.broadcast_to(ymean[:, None, None], Yp[i].shape), metas[i], agl))
                for pn, pf in preds.items():
                    kn = key_numbers(truth, pf, starts, g, lw, ec["rms_radius_m"])
                    fr = field_rms(truth, pf, lw, ec["edge_cells"])
                    for si, k in enumerate(kn):
                        k.update(case=cid, loc=row["loc"], start=si, U10=row["U10"], hour=row["hour"], **fr)
                        pts[pn].append(k)
                if sname in ("newcond", "holdout_place"):
                    pooled.add(airlite_targets(truth, row, ec["edge_cells"]), airlite_targets(preds["net"], row, ec["edge_cells"]))
                if cid in fig_pick:
                    keep_fields[cid] = dict(truth=truth, net=preds["net"], hc=z["d400_hc"].astype(np.float32), g=g,
                                            starts=starts, set=sname)
                done += 1
                prog.put(done)
                if sig.signum is not None:
                    lock.release()
                    sig.check()
            result["sets"][sname] = {pn: summarize(pts[pn], ec) for pn in PREDS}
            result["per_point"] += [dict(r, set=sname, pred=pn) for pn in PREDS for r in pts[pn]]
            if sname in ("newcond", "holdout_place"):
                result["airlite_net"][sname] = pooled.result()
        # кривая (в): каждая сеть на отложенных местах
        Xh, Fh, _, mh = load_arrays(prep_dir, hold_all, with_y=False) if hold_all else (None, None, None, None)
        for c in info["curve"]:
            net_c, _ = load_net(run / c["dir"], dev)
            pts = {"holdout_place": [], "holdout_proc": []}
            if hold_all:
                Yp = predict(net_c, Xh, Fh, dev)
                for i, cid in enumerate(hold_all):
                    row = rows_by_id[cid]
                    z = ds.load(cid)
                    truth = dict(m=z["d400_m"].astype(np.float64), h=z["d400_h"].astype(np.float64))
                    g = grid_of(row, truth["h"].shape)
                    pf = P.to_physical(Yp[i], mh[i], agl)
                    fr = field_rms(truth, pf, lw, ec["edge_cells"])
                    s = "holdout_place" if cid in split["holdout_place_ids"] else "holdout_proc"
                    for k in key_numbers(truth, pf, ds.starts(row["loc"]), g, lw, ec["rms_radius_m"]):
                        k.update(case=cid, **fr)
                        pts[s].append(k)
                    done += 1
                    prog.put(done)
            best = json.loads((run / c["dir"] / "manifest.json").read_text()).get("best", {})
            ent = dict(n=c["n"], n_places=c["n_places"], places=c["places"], n_train=len(c["train_ids"]), best=best)
            for s in pts:
                ent[s] = summarize(pts[s], ec) if pts[s] else None
            allp = pts["holdout_place"] + pts["holdout_proc"]
            ent["holdout_all"] = summarize(allp, ec) if allp else None
            ent["holdout_all_field"] = ({k: float(np.mean([p[k] for p in allp])) for k in ("f_wind", "f_lift_m", "f_lift_h")}
                                        if allp else None)
            result["curve"].append(ent)
            del net_c
            torch.cuda.empty_cache()
    t_eval = time.time() - t_eval0
    # ONNX (CPU; замок GPU не нужен)
    Xs, Fs, _, _ = load_arrays(prep_dir, (sets["holdout_place"] or sets["newcond"] or tr_eval)[:3], with_y=False)
    result["onnx"] = export_onnx(model, Xs, Fs, run / "main" / "model.onnx", ec["ort_repeats"], ec["ort_threads"])
    done += 1
    prog.put(done, force=True)
    mm = json.loads((run / "main" / "manifest.json").read_text())
    result["main"] = {k: mm.get(k) for k in ("n_params", "best", "epochs", "n_train", "n_val", "steps_per_epoch",
                                             "t_epoch_median_s", "t_per_sample_ms", "gpu", "torch")}
    result["main"]["history"] = json.loads((run / "main" / "history.json").read_text())
    result["t_eval_s"] = t_eval
    result["n_eval_cases"] = n_total - 1
    result["dataset"] = dict(root=info["dataset_root"], n_cases=len(rows_by_id),
                             status={s: sum(solver_status(r) == s for r in rows_by_id.values()) for s in ("ok", "max", "diverged")},
                             places=sorted({r["loc"] for r in rows_by_id.values()}))
    result["split_sizes"] = {k: len(v) for k, v in split.items() if k.endswith("_ids")}
    result["split"] = dict(holdout_places=split["holdout_places"], holdout_proc=split["holdout_proc"],
                           pool_order=split["pool_order"], seed=split["seed"])
    al = Path(ec["airlite_metrics"])
    al = al if al.is_absolute() else C.PILOT / al
    result["airlite_ref"] = airlite_ref(al)
    result["config_eval"] = ec
    result["config_estimate"] = cfg.get("estimate", {})
    result["config_train"] = cfg["train"]
    result["config_curve"] = cfg.get("curve", {})
    np.savez_compressed(rep / "eval_fields.npz", **flatten_fields(keep_fields))
    C.atomic_write_json(rep / "metrics.json", result)
    C.write_manifest(rep, "оценка и отчёт пилота (П3)", inputs_hash, True, run=str(run), report_built=False)
    print(f"оценка: {n_total - 1} предсказаний за {t_eval:.0f} с; ORT {result['onnx']['time_ms']}", flush=True)
    return C.EXIT_OK


def airlite_ref(path):
    if not path.exists():
        return None
    js = json.loads(path.read_text())
    out = {}
    for t, kinds in js["m"].items():
        for kind, folds in kinds.items():
            for fold in ("место ongudai", "новые условия"):
                if fold in folds:
                    out.setdefault(t, {}).setdefault(kind, {})[fold] = {k: folds[fold].get(k) for k in ("rmse", "skill", "n")}
    return out


def pick_figure_cases(sets, rows, nfig):
    """Случаи для срезов: по набору — с наибольшим U10, затем с наибольшей высотой солнца (днём)."""
    out = []
    for s, n in nfig.items():
        ids = sets.get(s) or []
        byU = sorted(ids, key=lambda i: (-float(rows[i]["U10"]), i))
        bySun = sorted(ids, key=lambda i: (-float(rows[i]["profile"].get("sun_el", 0)), float(rows[i]["U10"]), i))
        got = []
        for i in [x for pair in zip(byU, bySun) for x in pair]:
            if len(got) >= n:
                break
            if i not in got and i not in out:
                got.append(i)
        out += got
    return out


def flatten_fields(kf):
    d = {}
    for cid, v in kf.items():
        d[f"{cid}|truth_h"] = v["truth"]["h"].astype(np.float32)
        d[f"{cid}|truth_m"] = v["truth"]["m"].astype(np.float32)
        d[f"{cid}|net_h"] = v["net"]["h"].astype(np.float32)
        d[f"{cid}|net_m"] = v["net"]["m"].astype(np.float32)
        d[f"{cid}|hc"] = v["hc"]
        d[f"{cid}|meta"] = np.array(json.dumps(dict(g=v["g"], starts=v["starts"], set=v["set"])))
    return d


if __name__ == "__main__":
    cmd, run, rep = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    if cmd == "eval":
        try:
            sys.exit(run_eval(run, rep))
        except C.StopRequested as e:                 # сигнал во время ожидания замка GPU или оценки
            print(f"оценка прервана ({e}); повтор — заново (оценка короткая)", flush=True)
            sys.exit(e.code)
    from .report import build_report
    sys.exit(build_report(run, rep))
