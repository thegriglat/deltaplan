"""Оценка и отчёт пилота (контракты П3 v2/v3): python -m pilotnn.evaluate <eval|report> <каталог прогона> <каталог отчёта>

eval   — предсказания основной сети и сетей кривой, базовые линии, метрики П3 v2, сравнение с целями air-lite,
         признаки рельефа наборов, экспорт ONNX + ORT ↔ PyTorch + время ORT CPU
         → <отчёт>/metrics.json, <отчёт>/eval_fields.npz (поля для картинок).
report — картинки и report.md; вывод ШП-2 — правилом из чисел (config.yaml → eval.shp2), без ручных вставок.

Точки оценки (П3 v2) на высоте a = 60 м над рельефом клетки (линейно между 50 и 75 м):
  (1) область — все клетки без `edge_cells` у края;  (2) гребни — клетки области с tpi_2k случая (h − G_2км(h),
  `prep.tpi`, в исходной системе) ≥ его `ridge_pct`-го процентиля по области;  (3) центры — `plan.json → centers`
  (билинейно по горизонтали; RMS в 1 км — как v1).
Ошибки: ветер — |Δ(u, v)| с нагревом, «ок» при ≤ max(wind_ok_ms; wind_ok_rel·|V_решателя|); подъём — |Δw| без и с
нагревом, «ок» при < lift_ok_ms. Смещение: e = |V_сети| − |V_решателя| (с нагревом), среднее по клеткам области —
по 13 высотам, по корзинам U10 × высотам, на гребнях на 60 м; то же для w (Δw без и с нагревом, знаковое).
Наборы: (г) отложенные горные системы (главное), (б) Онгудай, (б′) отложенные процедурные, (а) новые условия —
места П6 и прежние раздельно, обучающие (до max_train_eval случаев).
П3 v3: все метрики — по группам решений (`conv` сошедшиеся / `nc` несошедшиеся / `all` все): ветер, w с нагревом и
смещение — по статусу `h`, w без нагрева — по `m`, «всё ок» — по обоим (`data.case_groups`); у несошедшихся — отношение
ошибки ветра к `late_spread60_p90` решения.
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
from .data import Datasets, case_groups, solver_status, terrain_features  # noqa: E402
from .train import case_file, load_arrays  # noqa: E402

CODE_FILES = [Path(__file__), Path(P.__file__), Path(M.__file__)]
SETS = ("holdout_sys", "holdout_place", "holdout_proc", "newcond_p6", "newcond_old", "train")
SET_NAMES = dict(holdout_sys="(г) отложенные горные системы", holdout_place="(б) Онгудай",
                 holdout_proc="(б′) отложенные процедурные рельефы", newcond_p6="(а) новые условия: места П6 пула",
                 newcond_old="(а) новые условия: прежние места", train="обучающие (проверка, что учится)")
PREDS = ("net", "inflow", "mean")
PRED_NAMES = dict(net="сеть", inflow="профиль притока", mean="среднее по набору")
METRICS = ("wind", "speed", "lift_m", "lift_h", "rms1km")
AREA = ("wind", "lift_m", "lift_h")
NQ = 101                                   # квантили распределений ошибок (картинка CDF)
CHUNK = 32                                 # случаев на одно взятие замка GPU при оценке


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


def add_pooled(pools, t, p, gr):
    """Цели air-lite по группам: механика (t_m*) — по статусу `m`, θ′ — по `h`, добавка нагрева (t_c*) — по обоим."""
    for k in t:
        g = gr["gm"] if k.startswith("t_m") else gr["gh"] if k == "t_th" else gr["gall"]
        pools[g].add({k: t[k]}, {k: p[k]})


def agg(rows, key):
    v = np.array([r[key] for r in rows if np.isfinite(r[key])])
    if v.size == 0:
        return None
    return dict(n=int(v.size), median=float(np.median(v)), p90=float(np.percentile(v, 90)), mean=float(v.mean()))


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


# ------------------------------------------------------------------------------------- метрики П3 v2 (область)
def u10_bin(U10, edges):
    k = int(np.searchsorted(np.asarray(edges, float), float(U10), side="right")) - 1
    return max(k, 0)


def bin_label(k, edges):
    return f"{edges[k]:g}–{edges[k + 1]:g}" if k + 1 < len(edges) else f"≥ {edges[k]:g}"


GROUPS = ("conv", "nc", "all")             # сошедшиеся / несошедшиеся / все (для вердикта отказа и контроля)
GROUP_NAMES = dict(conv="сошедшиеся", nc="несошедшиеся", all="все")


def _cat(l, dtype=np.float64):
    return np.concatenate(l).astype(dtype) if l else np.zeros(0, dtype)


class _Sub:
    """Накопитель одной группы. Ветер, w с нагревом, смещение e — по статусу решения `h`; w без нагрева — по `m`;
    «всё ок» — по обоим (сошлись и `h`, и `m`)."""

    def __init__(self, n_agl):
        self.cells = {k: [] for k in AREA + ("okw", "allok")}
        self.ridge = {k: [] for k in AREA + ("okw", "allok", "e", "v")}
        z = lambda: np.zeros(n_agl)  # noqa: E731
        self.bias = dict(e=z(), v=z(), wh=z(), n=0.0, wm=z(), nm=0.0)
        self.bins = {}
        self.ch = self.cm = 0


class AreaAcc:
    """Накопитель метрик П3 v2/v3 одного (набора, предсказания): клетки области и гребней на 60 м, смещение; три
    группы — сошедшиеся (`conv`), несошедшиеся (`nc`), все (`all`)."""

    def __init__(self, ec, n_agl):
        self.ec, self.nA = ec, n_agl
        self.edges = list(ec["u10_bins"])
        self.sub = {g: _Sub(n_agl) for g in GROUPS}
        self.cases = []

    def add(self, cid, row, truth, pred, lw, ridge_mask, gr):
        """gr — `data.case_groups(row)`."""
        ec = self.ec
        e = ec["edge_cells"]
        s = (Ellipsis, slice(e, -e or None), slice(e, -e or None))
        th, ph = at_level(truth["h"], lw)[s], at_level(pred["h"], lw)[s]
        tm, pm = at_level(truth["m"], lw)[s], at_level(pred["m"], lw)[s]
        vt = np.hypot(th[0], th[1])
        dw = np.hypot(ph[0] - th[0], ph[1] - th[1])
        okw = dw <= np.maximum(ec["wind_ok_ms"], ec["wind_ok_rel"] * vt)
        dlm, dlh = np.abs(pm[2] - tm[2]), np.abs(ph[2] - th[2])
        lt = ec["lift_ok_ms"]
        allok = okw & (dlm < lt) & (dlh < lt)
        r = ridge_mask
        ev = np.hypot(ph[0], ph[1]) - vt
        f32 = lambda v: v.astype(np.float32)  # noqa: E731
        # смещение по высотам (все 13), клетки области
        Th, Ph = truth["h"][s], pred["h"][s]
        Tm, Pm = truth["m"][s], pred["m"][s]
        VT = np.hypot(Th[0], Th[1])
        E = np.hypot(Ph[0], Ph[1]) - VT
        se, sv = E.sum(axis=(-2, -1)), VT.sum(axis=(-2, -1))
        n = float(E.shape[-1] * E.shape[-2])
        swh, swm = (Ph[2] - Th[2]).sum(axis=(-2, -1)), (Pm[2] - Tm[2]).sum(axis=(-2, -1))
        ub = u10_bin(row["U10"], self.edges)
        for g in (gr["gh"], "all"):
            q = self.sub[g]
            q.ch += 1
            for k, v in (("wind", f32(dw)), ("lift_h", f32(dlh)), ("okw", okw)):
                q.cells[k].append(v.ravel())
            for k, v in (("wind", dw), ("lift_h", dlh), ("okw", okw), ("e", ev), ("v", vt)):
                q.ridge[k].append(f32(v[r]) if k != "okw" else v[r])
            q.bias["e"] += se; q.bias["v"] += sv; q.bias["wh"] += swh; q.bias["n"] += n
            b = q.bins.setdefault(ub, dict(cases=0, e=np.zeros(self.nA), v=np.zeros(self.nA), n=0.0))
            b["cases"] += 1; b["e"] += se; b["v"] += sv; b["n"] += n
        for g in (gr["gm"], "all"):
            q = self.sub[g]
            q.cm += 1
            q.cells["lift_m"].append(f32(dlm).ravel())
            q.ridge["lift_m"].append(f32(dlm[r]))
            q.bias["wm"] += swm; q.bias["nm"] += n
        for g in (gr["gall"], "all"):
            q = self.sub[g]
            q.cells["allok"].append(allok.ravel())
            q.ridge["allok"].append(allok[r])
        self.cases.append(dict(case=cid, loc=row["loc"], U10=float(row["U10"]), frac_wind_ok=float(okw.mean()),
                               wind_median=float(np.median(dw)), e60=float(ev.mean()), v60=float(vt.mean()),
                               gh=gr["gh"], gm=gr["gm"], target_h=gr["target_h"], target_m=gr["target_m"],
                               spread_h=gr["spread_h"]))

    def _res(self, g, with_q):
        q = self.sub[g]
        if not q.ch and not q.cm:
            return None
        lt = self.ec["lift_ok_ms"]
        res = dict(n_cases=q.ch, n_cases_m=q.cm)
        for name, d in (("area", q.cells), ("ridge", q.ridge)):
            st = {}
            if d["wind"]:
                okw = _cat(d["okw"], bool)
                st["n_points"] = int(okw.size)
                st["frac_wind_ok"] = float(okw.mean())
                for k in ("wind", "lift_h"):
                    v = _cat(d[k])
                    st[k] = dict(median=float(np.median(v)), p90=float(np.percentile(v, 90)), mean=float(v.mean()))
                    if with_q and name == "area":
                        st[k]["q"] = np.percentile(v, np.linspace(0, 100, NQ)).astype(float).round(5).tolist()
                st["frac_lift_h_ok"] = float(np.mean(_cat(d["lift_h"]) < lt))
                if name == "ridge":
                    e, v = _cat(d["e"]), _cat(d["v"])
                    st["e_mean"], st["v_mean"] = float(e.mean()), float(v.mean())
            if d["lift_m"]:
                v = _cat(d["lift_m"])
                st["n_points_m"] = int(v.size)
                st["lift_m"] = dict(median=float(np.median(v)), p90=float(np.percentile(v, 90)), mean=float(v.mean()))
                if with_q and name == "area":
                    st["lift_m"]["q"] = np.percentile(v, np.linspace(0, 100, NQ)).astype(float).round(5).tolist()
                st["frac_lift_m_ok"] = float(np.mean(v < lt))
            if d["allok"]:
                st["n_points_all"] = int(sum(a.size for a in d["allok"]))
                st["frac_all_ok"] = float(_cat(d["allok"], bool).mean())
            res[name] = st or None
        n = max(q.bias["n"], 1.0)
        nm = max(q.bias["nm"], 1.0)
        res["bias"] = dict(e=(q.bias["e"] / n).tolist(), v=(q.bias["v"] / n).tolist(),
                           w_m=(q.bias["wm"] / nm).tolist(), w_h=(q.bias["wh"] / n).tolist())
        res["bias_bins"] = {bin_label(k, self.edges): dict(cases=b["cases"], e=(b["e"] / max(b["n"], 1.0)).tolist(),
                                                            v=(b["v"] / max(b["n"], 1.0)).tolist())
                            for k, b in sorted(q.bins.items())}
        mine = [c for c in self.cases if g == "all" or c["gh"] == g]
        res["targets_h"] = {t: sum(c["target_h"] == t for c in mine) for t in sorted({c["target_h"] for c in mine})}
        mine_m = [c for c in self.cases if g == "all" or c["gm"] == g]
        res["targets_m"] = {t: sum(c["target_m"] == t for c in mine_m) for t in sorted({c["target_m"] for c in mine_m})}
        if g == "nc":
            # ошибка ветра сети относительно собственного разброса решения: медиана по случаям (решение h не сошлось,
            # у него есть late_spread60_p90 > 0); у целей «last» (v1) разброса нет — в отношение не входят
            rt = np.array([c["wind_median"] / c["spread_h"] for c in mine if c["spread_h"]], float)
            res["spread_ratio"] = (dict(n=int(rt.size), median=float(np.median(rt)), p90=float(np.percentile(rt, 90)))
                                   if rt.size else dict(n=0, median=None, p90=None))
        return res

    def result(self, with_q=True):
        res = {g: self._res(g, with_q) for g in GROUPS}
        res["n_cases"] = self.sub["all"].ch
        return res


def ridge_mask(hc, ec):
    """Гребни: клетки области (без края) с tpi_2k ≥ ridge_pct-го процентиля по области (tpi — в исходной системе)."""
    e = ec["edge_cells"]
    t = P.tpi(hc, P.TPI_SIGMAS_M[0])[e:-e or None, e:-e or None]
    return t >= np.percentile(t, ec["ridge_pct"])


def summarize(rows, ec):
    """Центры (v1-точки) — ключевые числа по списку точек, три группы; «ок» ветра — по правилу П3 v2.
    Группы точек: gh (ветер, подъём с нагревом), gm (подъём без нагрева), gall («всё ок»)."""
    out = {}
    lt = ec["lift_ok_ms"]
    for g in GROUPS:
        pick = lambda which: [r for r in rows if g == "all" or r[which] == g]  # noqa: E731
        rh, rmm, ra = pick("gh"), pick("gm"), pick("gall")
        if not rh and not rmm:
            out[g] = None
            continue
        d = {k: agg(rh, k) for k in ("wind", "speed", "rms1km", "lift_h")}
        d["lift_m"] = agg(rmm, "lift_m")
        if rh:
            w = np.array([r["wind"] for r in rh]); vt = np.array([r["true_speed"] for r in rh])
            d["frac_wind_ok"] = float(np.mean(w <= np.maximum(ec["wind_ok_ms"], ec["wind_ok_rel"] * vt)))
            d["frac_lift_h_ok"] = float(np.mean(np.array([r["lift_h"] for r in rh]) < lt))
            d["n_points"] = len(rh)
            d["n_cases"] = len({r["case"] for r in rh})
        if rmm:
            d["frac_lift_m_ok"] = float(np.mean(np.array([r["lift_m"] for r in rmm]) < lt))
            d["n_points_m"] = len(rmm)
        if ra:
            w = np.array([r["wind"] for r in ra]); vt = np.array([r["true_speed"] for r in ra])
            okw = w <= np.maximum(ec["wind_ok_ms"], ec["wind_ok_rel"] * vt)
            ok = okw & (np.array([r["lift_m"] for r in ra]) < lt) & (np.array([r["lift_h"] for r in ra]) < lt)
            d["frac_all_ok"] = float(ok.mean())
            d["n_points_all"] = len(ra)
        out[g] = d
    return out


# ------------------------------------------------------------------------------------------------ eval
def hold_groups(loc, p6, ec):
    """Группы (г) для разбивки отчёта: система и корзина уклона slope_p50 из индекса П6."""
    r = p6.get(loc)
    if not r:
        return []
    e = list(ec.get("slope_bins", [0.12, 0.3]))
    k = int(np.searchsorted(np.asarray(e), float(r["slope_p50"]), side="right"))
    lab = (f"< {e[0]:g}" if k == 0 else f"≥ {e[-1]:g}" if k == len(e) else f"{e[k - 1]:g}–{e[k]:g}")
    return [f"система {r['system']}", f"уклон p50 {lab}"]


def eval_sets(split, ec, seed):
    rng = np.random.default_rng(seed)
    tr = list(split["train_ids"])
    n_tr = int(ec.get("max_train_eval", 60))
    tr_eval = sorted(rng.choice(tr, min(n_tr, len(tr)), replace=False).tolist()) if tr else []
    return dict(holdout_sys=split["holdout_sys_ids"], holdout_place=split["holdout_place_ids"],
                holdout_proc=split["holdout_proc_ids"], newcond_p6=split["newcond_p6_ids"],
                newcond_old=split["newcond_old_ids"], train=tr_eval)


def terrain_table(dss, rows_by_id, split, p6):
    """Признаки рельефа мест (уклон 400 м p50/p95, размах): места П6 — из index.csv, прочие — из d400_hc."""
    places = {}
    first = {}
    for cid, r in sorted(rows_by_id.items()):
        first.setdefault(r["loc"], cid)
    groups = {}
    for l in split["p6_pool"]:
        groups[l] = "П6 пул"
    for l in split["holdout_sys"]:
        groups[l] = f"(г) {p6[l]['system']}"
    for l in split["holdout_places"]:
        groups[l] = "(б) Онгудай"
    for l in split["holdout_proc"]:
        groups[l] = "(б′) отложенные процедурные"
    for l in split["others"]:
        groups[l] = ("прежние: встроенные" if not l[:2] in ("s_", "p_") else
                     "прежние: синтетика" if l.startswith("s_") else "прежние: процедурные")
    for l, cid in first.items():
        if l in p6:
            f = {k: float(p6[l][k]) for k in ("slope_p50", "slope_p95", "relief_m", "h_mean")}
            f["src"] = "П6 index.csv"
        else:
            f = terrain_features(dss.load(cid)["d400_hc"].astype(np.float64))
            f["src"] = "d400_hc"
        f["group"] = groups.get(l, "?")
        places[l] = f
    tab = {}
    for g in sorted({f["group"] for f in places.values()}):
        mine = [f for f in places.values() if f["group"] == g]
        tab[g] = dict(n_places=len(mine), **{k: dict(median=float(np.median([f[k] for f in mine])),
                                                      min=float(min(f[k] for f in mine)),
                                                      max=float(max(f[k] for f in mine)))
                                             for k in ("slope_p50", "slope_p95", "relief_m")})
    return dict(groups=tab, places=places)


def run_eval(run: Path, rep: Path):
    sig = C.Signals()
    cfg = json.loads((run / "config.json").read_text())
    ec = cfg["eval"]
    split = json.loads((run / "split.json").read_text())
    info = json.loads((run / "run_info.json").read_text())
    p6 = (C.read_json(run / "p6.json", {}) or {}).get("places", {})
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    prep = info["prep_dirs"]
    curve_subs = [run / c["dir"] for c in info["curve"] if not c["is_main"]]
    subs = [run / "main"] + curve_subs
    inputs_hash = C.sha(dict(ck=[file_sha(s / "ckpt" / "best.pt") for s in subs], split=split, eval=ec,
                             code=C.code_hash(*CODE_FILES)))
    rep.mkdir(parents=True, exist_ok=True)
    st = C.step_state(rep, inputs_hash)
    if st == "done" and (rep / "metrics.json").exists():
        print("оценка: уже готова — пропуск")
        return C.EXIT_OK
    C.write_manifest(rep, "оценка и отчёт пилота (П3 v2)", inputs_hash, False, run=str(run))
    C.clean_tmp(rep)
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    dev = torch.device("cuda")
    rows_by_id = {r["id"]: r for r in dss.case_rows()}
    agl = dss.agl
    lw = level_weights(agl, ec["agl_key_m"])
    sets = eval_sets(split, ec, split["seed"])
    curve_sets = ("holdout_sys", "holdout_place")
    n_total = sum(len(v) for v in sets.values()) + len(curve_subs) * sum(len(sets[s]) for s in curve_sets) + 1
    prog = Prog(rep, n_total, "случаев", "оценка")
    done = 0
    # среднее цели по обучению (базовая линия «среднее»)
    ysum, ycount = None, 0
    for cid in split["train_ids"]:
        with np.load(case_file(prep, cid)) as z:
            y = z["Y"].astype(np.float64)
        ysum = y.mean(axis=(1, 2)) if ysum is None else ysum + y.mean(axis=(1, 2))
        ycount += 1
    ymean = (ysum / max(ycount, 1)).astype(np.float32)
    lock = C.GpuLock(sig)
    t_eval0 = time.time()
    t_gpu = 0.0
    result = dict(sets={}, centers={}, curve=[], airlite_net={}, per_point=[], ymean=ymean.tolist())
    keep_fields = {}
    fig_pick = pick_figure_cases(sets, rows_by_id, ec["n_slice_figures"])
    ridges = {}

    def truth_of(cid):
        z = dss.load(cid)
        return z, dict(m=z["d400_m"].astype(np.float64), h=z["d400_h"].astype(np.float64))

    def predict_chunks(model, ids):
        """Предсказания кусками: замок GPU — только на прогон сети (метрики на CPU — без замка)."""
        nonlocal t_gpu
        for i0 in range(0, len(ids), CHUNK):
            part = ids[i0:i0 + CHUNK]
            X, F, _, metas = load_arrays(prep, part, with_y=False)
            with lock:
                t0 = time.perf_counter()
                Yp = predict(model, X, F, dev)
                t_gpu += time.perf_counter() - t0
            yield part, Yp, metas
            if sig.signum is not None:
                sig.check()

    model, task = load_net(run / "main", dev)
    pooled_nc = {g: Pooled() for g in GROUPS[:2]}
    pooled_hp = {g: Pooled() for g in GROUPS[:2]}
    for sname, ids in sets.items():
        if not ids:
            result["sets"][sname] = None
            result["centers"][sname] = None
            continue
        acc = {p: AreaAcc(ec, len(agl)) for p in PREDS}
        gacc = {}                                         # (г): разбивка по системам и уклону (сеть и приток)
        pts = {p: [] for p in PREDS}
        for part, Yp, metas in predict_chunks(model, ids):
            for i, cid in enumerate(part):
                row = rows_by_id[cid]
                z, truth = truth_of(cid)
                hc = z["d400_hc"].astype(np.float64)
                if cid not in ridges:
                    ridges[cid] = ridge_mask(hc, ec)
                rm = ridges[cid]
                gr = case_groups(row)
                g = grid_of(row, truth["h"].shape)
                starts = dss.starts(row["loc"])
                preds = dict(net=P.to_physical(Yp[i], metas[i], agl),
                             inflow=P.to_physical(np.zeros_like(Yp[i]), metas[i], agl),
                             mean=P.to_physical(np.broadcast_to(ymean[:, None, None], Yp[i].shape), metas[i], agl))
                for pn, pf in preds.items():
                    acc[pn].add(cid, row, truth, pf, lw, rm, gr)
                    kn = key_numbers(truth, pf, starts, g, lw, ec["rms_radius_m"])
                    for si, k in enumerate(kn):
                        k.update(case=cid, loc=row["loc"], start=si, U10=row["U10"], hour=row["hour"], gh=gr["gh"], gm=gr["gm"],
                                 gall=gr["gall"])
                        pts[pn].append(k)
                if sname == "holdout_sys":
                    for gname in hold_groups(row["loc"], p6, ec):
                        for gp in ("net", "inflow"):
                            gacc.setdefault(gname, {}).setdefault(gp, AreaAcc(ec, len(agl))).add(
                                cid, row, truth, preds[gp], lw, rm, gr)
                if sname in ("newcond_p6", "newcond_old"):
                    add_pooled(pooled_nc, airlite_targets(truth, row, ec["edge_cells"]),
                               airlite_targets(preds["net"], row, ec["edge_cells"]), gr)
                elif sname == "holdout_place":
                    add_pooled(pooled_hp, airlite_targets(truth, row, ec["edge_cells"]),
                               airlite_targets(preds["net"], row, ec["edge_cells"]), gr)
                if cid in fig_pick:
                    keep_fields[cid] = dict(truth=truth, net=preds["net"], hc=hc.astype(np.float32), g=g,
                                            starts=starts, set=sname, ridge=rm)
                done += 1
                prog.put(done)
        result["sets"][sname] = {pn: acc[pn].result() for pn in PREDS}
        result["sets"][sname]["per_case"] = acc["net"].cases
        if gacc:
            result["sets"][sname]["groups"] = {g: {pn: trim(a.result(with_q=False)) for pn, a in d.items()}
                                               for g, d in sorted(gacc.items())}
        result["centers"][sname] = {pn: summarize(pts[pn], ec) for pn in PREDS}
        result["per_point"] += [dict(r, set=sname, pred=pn) for pn in PREDS for r in pts[pn]]
    result["airlite_net"] = dict(newcond={g: p.result() for g, p in pooled_nc.items()},
                                 holdout_place={g: p.result() for g, p in pooled_hp.items()})
    # кривая (в): сети точек на (г) и (б); точка полного пула = основная сеть (числа — из наборов выше)
    for c in info["curve"]:
        ent = dict(n=c["n"], n_places=c["n_places"], is_main=c["is_main"], curve_places=c["curve_places"],
                   n_train=len(c["train_ids"]))
        if c["is_main"]:
            for s in curve_sets:
                ent[s] = trim(result["sets"][s]["net"]) if result["sets"].get(s) else None
            ent["best"] = json.loads((run / "main" / "manifest.json").read_text()).get("best", {})
        else:
            net_c, _ = load_net(run / c["dir"], dev)
            for s in curve_sets:
                ids = sets[s]
                if not ids:
                    ent[s] = None
                    continue
                acc = AreaAcc(ec, len(agl))
                for part, Yp, metas in predict_chunks(net_c, ids):
                    for i, cid in enumerate(part):
                        z, truth = truth_of(cid)
                        acc.add(cid, rows_by_id[cid], truth, P.to_physical(Yp[i], metas[i], agl), lw, ridges[cid],
                                case_groups(rows_by_id[cid]))
                        done += 1
                        prog.put(done)
                ent[s] = trim(acc.result(with_q=False))
            ent["best"] = json.loads((run / c["dir"] / "manifest.json").read_text()).get("best", {})
            del net_c
            torch.cuda.empty_cache()
        result["curve"].append(ent)
    t_eval = time.time() - t_eval0 - lock.waited          # без ожидания замка GPU
    # ONNX (CPU; замок GPU не нужен)
    src = (sets["holdout_sys"] or sets["holdout_place"] or sets["newcond_p6"] or sets["newcond_old"] or sets["train"])[:3]
    Xs, Fs, _, _ = load_arrays(prep, src, with_y=False)
    result["onnx"] = export_onnx(model, Xs, Fs, run / "main" / "model.onnx", ec["ort_repeats"], ec["ort_threads"])
    done += 1
    prog.put(done, force=True)
    mm = json.loads((run / "main" / "manifest.json").read_text())
    result["main"] = {k: mm.get(k) for k in ("n_params", "best", "epochs", "n_train", "n_val", "steps_per_epoch",
                                             "t_epoch_median_s", "t_per_sample_ms", "gpu", "torch")}
    result["main"]["history"] = json.loads((run / "main" / "history.json").read_text())
    result["t_eval_s"] = t_eval
    result["t_eval_gpu_s"] = t_gpu
    result["gpu_lock_wait_s"] = lock.waited
    result["n_eval_cases"] = n_total - 1
    result["agl"] = list(agl)
    result["datasets"] = [dict(d, n_rows=sum(r["ds"] == d["name"] for r in rows_by_id.values()),
                               status={s: sum(solver_status(r) == s for r in rows_by_id.values() if r["ds"] == d["name"])
                                       for s in ("ok", "max", "diverged")},
                               places=sorted({r["loc"] for r in rows_by_id.values() if r["ds"] == d["name"]}))
                          for d in info["datasets"]]
    result["split_sizes"] = {k: len(v) for k, v in split.items() if k.endswith("_ids")}
    result["split"] = {k: split[k] for k in ("seed", "holdout_places", "holdout_sys", "holdout_proc", "pool_order",
                                             "curve_order", "curve_base", "p6_pool", "others", "val_is_train")}
    result["eval_sizes"] = {k: len(v) for k, v in sets.items()}
    result["p6_index"] = info.get("p6_index")
    result["p6_systems"] = {l: p6[l]["system"] for l in split["holdout_sys"]}
    result["terrain"] = terrain_table(dss, rows_by_id, split, p6)
    al = Path(ec["airlite_metrics"])
    al = al if al.is_absolute() else C.PILOT / al
    result["airlite_ref"] = airlite_ref(al)
    result["config_eval"] = ec
    result["refuse_baselines"] = dict(
        used=["inflow", "mean"], names=[PRED_NAMES["inflow"], PRED_NAMES["mean"]], excluded=["регрессия air-lite"],
        why="отказ сравнивает медиану ошибки ветра сети на (г) (все случаи) с наименьшей из медиан двух базовых линий "
            "(профиль притока без поправки, среднее по обучению); регрессия air-lite не входит: она на окнах 100 м и "
            "старых фолдах («место ongudai», «новые условия»), на отложенных системах и области 400 м её нет")
    result["groups_note"] = dict(
        conv="сошедшиеся: статус решения «ok», цель — конечное состояние (final)",
        nc="несошедшиеся: статус «max», цель — late_mean (П1 v3) или last (набор v1)",
        by="ветер, w с нагревом и смещение — по статусу решения h; w без нагрева — по m; «всё ок» — сошлись и h, и m",
        all="все случаи: только для вердикта отказа и контроля")
    result["config_estimate"] = cfg.get("estimate", {})
    result["config_train"] = cfg["train"]
    result["config_curve"] = cfg.get("curve", {})
    result["config_split"] = cfg["split"]
    result["profile"] = info.get("profile", "")
    np.savez_compressed(rep / "eval_fields.npz", **flatten_fields(keep_fields))
    C.atomic_write_json(rep / "metrics.json", result)
    C.write_manifest(rep, "оценка и отчёт пилота (П3 v2)", inputs_hash, True, run=str(run), report_built=False)
    print(f"оценка: {n_total - 1} предсказаний за {t_eval:.0f} с (сеть на GPU {t_gpu:.0f} с); ORT {result['onnx']['time_ms']}",
          flush=True)
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


def trim(r):
    """Результат AreaAcc без лишнего (для разбивок и кривой): по группам — число случаев, область, гребни, смещение."""
    return {g: ({k: v for k, v in r[g].items() if k in ("n_cases", "n_cases_m", "area", "ridge", "bias", "bias_bins",
                                                          "spread_ratio", "targets_h", "targets_m")} if r[g] else None)
            for g in GROUPS} | dict(n_cases=r["n_cases"])


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
        d[f"{cid}|ridge"] = v["ridge"].astype(np.uint8)
        e = (v["hc"].shape[0] - v["ridge"].shape[0]) // 2
        d[f"{cid}|meta"] = np.array(json.dumps(dict(g=v["g"], starts=v["starts"], set=v["set"], edge=e)))
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
