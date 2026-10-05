"""S7 (SY-11): оценка сети по контракту S7 v1 и экспорт/проверка ONNX.

Метрика — ошибка ветра на 60 м над рельефом (линейно между 50 и 75 м: веса 0,6 / 0,4), клетки области без 5 клеток у края
(как оценка пилота, `eval.edge_cells`):
  |ΔV| = |(Δu, Δv)| в м/с; относительная = |ΔV| / max(U10, 1 м/с).
Цель кодирована как (поле − профиль притока)/S, S = max(U10, 1) (prep.target), поворот — вращение на k·90° + остаток r: профиль притока
линеен по высоте-интерполяции и вычитается из обоих полей, а поворот не меняет модуль вектора, поэтому
|ΔV| = S·|(Δy∥, Δy⊥)| точно, без обратного преобразования (то, что to_physical даёт то же, проверяет tests/test_recover.py).
Статистика — по клеткам, слитым по случаям группы (медиана, p90), и по случаям (медиана медиан случая). Срезы: поле «с нагревом»
(h, главное, как в П3) и «без» (m); mechanical (w*/U < 0,5) и конвективный (иначе); терцили Fr (S2: U_sat/(N·H), без обрезки) и dθ/dz
(S2 v4: средний градиент от z_i до z_i + 1 км) — пороги по условиям обучающих мест (cache train), чтобы не зависеть от оцениваемой группы.
Базовая линия — профиль притока без поправки (ноль в кодировке цели).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s7_data as D  # noqa: E402

AGL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
NA = len(AGL)
A_KEY = 60.0
EDGE = 5
I50, I75 = AGL.index(50), AGL.index(75)
W50 = (75.0 - A_KEY) / 25.0
W75 = (A_KEY - 50.0) / 25.0
# каналы цели: ·13 + высота; без нагрева (u∥, u⊥, w) = 0..2, с нагревом (u∥, u⊥, w, θ′) = 3..6
CH = dict(m=(0, 1, 2), h=(3, 4, 5))


def at60(y, c):
    """Канал c (порядок [канал][высота]) на 60 м: y (n,91,96,96) -> (n,96,96)."""
    return W50 * y[:, c * NA + I50] + W75 * y[:, c * NA + I75]


def errors(yp, yt, S, field):
    """(|ΔV|, |Δw|) на 60 м, м/с, (n,96-2·EDGE,96-2·EDGE); yp, yt (n,91,96,96) в кодировке цели; S (n,)."""
    cu, cv, cw = CH[field]
    sl = (slice(None), slice(EDGE, -EDGE), slice(EDGE, -EDGE))
    du = (at60(yp, cu) - at60(yt, cu))[sl]
    dv = (at60(yp, cv) - at60(yt, cv))[sl]
    dw = (at60(yp, cw) - at60(yt, cw))[sl]
    s = np.asarray(S)[:, None, None]
    return s * np.hypot(du, dv), s * np.abs(dw)


def base_errors(yt, S, field):
    """Профиль притока без поправки (ноль в кодировке цели): |ΔV|, |Δw| на 60 м."""
    return errors(np.zeros_like(yt), yt, S, field)


def stats(dv, dw, S, U10):
    """dv, dw — (n,h,w) м/с по случаям. -> словарь чисел (пулом клеток и по случаям)."""
    n = len(dv)
    if n == 0:
        return dict(n_cases=0)
    flat = dv.reshape(-1)
    rel = (dv / np.maximum(np.asarray(U10), 1.0)[:, None, None]).reshape(-1)
    cm = np.median(dv.reshape(n, -1), axis=1)
    return dict(n_cases=int(n), median_60m=float(np.median(flat)), p90_60m=float(np.percentile(flat, 90)), mean_60m=float(flat.mean()),
                rel_median_60m=float(np.median(rel)), rel_p90_60m=float(np.percentile(rel, 90)),
                case_median_of_medians_60m=float(np.median(cm)), case_p90_of_medians_60m=float(np.percentile(cm, 90)),
                w_median_60m=float(np.median(dw)), w_p90_60m=float(np.percentile(dw, 90)))


def terciles(vals):
    return [float(np.quantile(vals, 1 / 3)), float(np.quantile(vals, 2 / 3))]


def tercile_label(x, th):
    return np.where(x < th[0], 0, np.where(x < th[1], 1, 2))


def slice_masks(meta, thr):
    """Маски срезов по случаям: all, mechanical, convective, Fr/dθdz терцили (low/mid/high), с учётом порогов обучения `thr`."""
    n = len(meta["case"])
    out = {"all": np.ones(n, bool), "mechanical": meta["mechanical"].astype(bool), "convective": ~meta["mechanical"].astype(bool)}
    fl = tercile_label(meta["froude"], thr["froude"])
    dl = tercile_label(meta["dtheta"], thr["dtheta"])
    for i, nm in enumerate(("low", "mid", "high")):
        out[f"froude_{nm}"] = fl == i
        out[f"dtheta_dz_{nm}"] = dl == i
    return out


def thresholds(train_meta):
    ok = np.isfinite(train_meta["froude"]) & np.isfinite(train_meta["dtheta"])
    return dict(froude=terciles(train_meta["froude"][ok]), dtheta=terciles(train_meta["dtheta"][ok]), n_train_cases=int(ok.sum()))


def predict(model, X, F, device="cpu", bs=8):
    import torch
    model = model.to(device).eval().float()
    out = []
    with torch.no_grad():
        for i in range(0, len(X), bs):
            out.append(model(torch.from_numpy(X[i:i + bs]).to(device), torch.from_numpy(F[i:i + bs]).to(device)).float().cpu().numpy())
    return np.concatenate(out) if out else np.zeros((0, 91, D.NY, D.NX), np.float32)


def evaluate(model, cache, idx, thr, device="cpu", bs=8, chunk=64):
    """Оценка модели на случаях idx кеша -> dict(slices={срез: {field: stats, base_<field>: stats}}, by_place=...).
    Случаи с status 2 (разошлись) в оценку не входят (idx — после cache.select(ok_only=True))."""
    meta = {k: v[idx] for k, v in cache.meta.items()}
    S = np.maximum(meta["u10"], 1.0)
    dv = {f: [] for f in ("h", "m", "bh", "bm")}
    dw = {f: [] for f in ("h", "m", "bh", "bm")}
    for a in range(0, len(idx), chunk):
        sel = idx[a:a + chunk]
        X, F = cache.load_xf(sel)
        yp = predict(model, X, F, device, bs)
        yt = cache.gather_y(sel).astype(np.float32)
        for f in ("h", "m"):
            v, w = errors(yp, yt, S[a:a + chunk], f)
            dv[f].append(v); dw[f].append(w)
            v, w = base_errors(yt, S[a:a + chunk], f)
            dv["b" + f].append(v); dw["b" + f].append(w)
    dv = {k: np.concatenate(v) if v else np.zeros((0, 86, 86)) for k, v in dv.items()}
    dw = {k: np.concatenate(v) if v else np.zeros((0, 86, 86)) for k, v in dw.items()}
    masks = slice_masks(meta, thr)
    res = {}
    for nm, m in masks.items():
        r = {}
        for f, label in (("h", "heat"), ("m", "noheat")):
            r[label] = _clean(stats(dv[f][m], dw[f][m], S[m], meta["u10"][m]))
            r["base_" + label] = _clean(stats(dv["b" + f][m], dw["b" + f][m], S[m], meta["u10"][m]))
        res[nm] = r
    bp = {}
    for rid in np.unique(meta["relief_id"]):
        m = meta["relief_id"] == rid
        bp[str(int(rid))] = dict(n_cases=int(m.sum()), median_60m=float(np.median(dv["h"][m])), p90_60m=float(np.percentile(dv["h"][m], 90)),
                                 base_median_60m=float(np.median(dv["bh"][m])))
    return dict(slices=res, by_place=bp)


def _clean(d):
    return {k: v for k, v in d.items() if v is not None}


def load_model(path, device="cpu", hp=None):
    import torch
    from pilotnn import model as M
    from s7_train import P2
    ck = torch.load(path, map_location="cpu", weights_only=False)
    m = M.build((hp or P2)["model"], 9, 18, 91)
    m.load_state_dict(ck["model"])
    return m.to(device).eval(), ck


def md_table(title, res):
    """Таблица срезов (с нагревом / без нагрева; сеть и профиль притока) в markdown."""
    rows = [f"### {title}", "", "| срез | случаев | с нагревом: медиана, м/с | p90 | отн. медиана | без нагрева: медиана | p90 | профиль притока (с нагревом): медиана | p90 |",
            "|---|---|---|---|---|---|---|---|---|"]
    for nm, r in res["slices"].items():
        h, m, b = r["heat"], r["noheat"], r["base_heat"]
        if not h.get("n_cases"):
            rows.append(f"| {nm} | 0 | | | | | | | |")
            continue
        rows.append(f"| {nm} | {h['n_cases']} | {h['median_60m']:.3f} | {h['p90_60m']:.3f} | {h['rel_median_60m']:.3f} | "
                    f"{m['median_60m']:.3f} | {m['p90_60m']:.3f} | {b['median_60m']:.3f} | {b['p90_60m']:.3f} |")
    return "\n".join(rows) + "\n"


# ------------------------------------------------------------------ ONNX
def export_onnx(model, path, X, F, n_rep=10, threads=(4, 1), meta=None):
    """Экспорт функцией пилота (opset 17, имена maps/nums/out, статический batch 1 — как data/air_nn/model.onnx)."""
    from pilotnn.evaluate import export_onnx as ex
    return ex(model, X, F, Path(path), n_rep, list(threads), meta)


def onnx_io(path):
    import onnxruntime as ort
    s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    f = lambda l: [(i.name, list(i.shape), i.type) for i in l]
    return dict(inputs=f(s.get_inputs()), outputs=f(s.get_outputs()))


def onnx_io_match(path, ref):
    a, b = onnx_io(path), onnx_io(ref)
    return dict(match=a == b, new=a, ref=b)


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weights", required=True, help="best.pt режима val (оценка) / final.pt (экспорт)")
    ap.add_argument("--train-cache", nargs="+", required=True, help="кеш обучающих мест — пороги терцилей")
    ap.add_argument("--holdout-cache", nargs="+", required=True)
    ap.add_argument("--game-cache", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cpu")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    model, ck = load_model(a.weights, a.device)
    tc = D.Cache(a.train_cache)
    thr = thresholds({k: v[tc.select(0)] for k, v in tc.meta.items()})
    res = {}
    for name, dirs, grp in (("holdout", a.holdout_cache, 1), ("game", a.game_cache, 2)):
        c = D.Cache(dirs)
        idx = c.select(grp)
        n_div = int((c.meta["group"] == grp).sum() - len(idx))
        r = evaluate(model, c, idx, thr, a.device)
        r["n_diverged_excluded"] = n_div
        res[name] = r
    head = res["holdout"]["slices"]["all"]["heat"]
    doc = dict(contract="S7 v1", weights=str(a.weights), epoch=int(ck.get("epoch", -1)) + 1 if "epoch" in ck else None, gstep=ck.get("gstep"),
               edge_cells=EDGE, level_m=A_KEY, thresholds=thr,
               # главные числа — отложенные места, поле с нагревом (как П3)
               median_60m=head["median_60m"], p90_60m=head["p90_60m"], rel_median_60m=head["rel_median_60m"],
               game_median_60m=res["game"]["slices"]["all"]["heat"].get("median_60m"), game_rel_median_60m=res["game"]["slices"]["all"]["heat"].get("rel_median_60m"),
               holdout=res["holdout"], game=res["game"])
    (out / "eval_holdout.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False))
    md = ["# Ошибка ветра на 60 м (S7 v1)", "", f"Веса: `{Path(a.weights).name}`, эпоха {doc['epoch']}. Клетки области без 5 у края. Пороги терцилей по обучающим: "
          f"Fr {thr['froude']}, dθ/dz {thr['dtheta']} К/км.", "",
          md_table("Отложенные места (holdout)", res["holdout"]), md_table("Места игры (game)", res["game"])]
    (out / "eval_holdout.md").write_text("\n".join(md))
    print(json.dumps({k: doc[k] for k in ("median_60m", "p90_60m", "rel_median_60m", "game_median_60m", "game_rel_median_60m")}))


if __name__ == "__main__":
    main()
