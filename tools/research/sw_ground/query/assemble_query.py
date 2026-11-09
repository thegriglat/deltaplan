"""SWG-6: timing.json (SWG4 v2) из сырых прогонов raw/q_*.json (медианы по повторениям) + строки SWG-3 (панели fp64, нить, Пикар;
variant null → 'fp64', err null). assemble_query.py <raw_dir> <swg3_timing.json> <out.json>"""
import glob
import json
import os
import statistics as st
import sys
import tempfile
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "timing"))
import assemble_timing as AT   # noqa: E402  (SWG-3: git_short, cpu_name, gpu_name)

DESC = {
    "above_ground": "опрос только надземных точек (подземные не считаются); элементное ядро CuPy FP64 как SWG-3",
    "vert_interp": "надземные точки; выше 300 м над землёй каждый 2-й уровень по вертикали, остальные — линейная интерполяция u, v; ядро FP64 как SWG-3",
    "fp32": "слитое ядро CUDA FP32 (координаты в центре окна), все точки; решение/LU FP64",
    "fused64": "диагностика: то же слитое ядро в FP64, прямой счёт, все точки (отделяет слияние ядра от точности)",
    "far_cluster": "слитое ядро FP64, дальние панели — узлы октодерева (монополь+диполь), θ=0,5, все точки",
    "far_cluster_t03": "то же, θ=0,3", "far_cluster_t07": "то же, θ=0,7",
    "fp32+above_ground": "FP32 + надземные точки",
    "fp32+above_ground+vert_interp": "FP32 + надземные + интерполяция по вертикали выше 300 м",
    "fp32+above_ground+far_cluster": "FP32 + надземные + дальние узлы (θ=0,5)",
    "fp32+above_ground+far_cluster+vert_interp": "FP32 + надземные + дальние узлы (θ=0,5) + интерполяция по вертикали",
}


def med(xs):
    return float(st.median(xs))


def main():
    raw, s3, out = sys.argv[1:4]
    groups = {}
    for f in sorted(glob.glob(os.path.join(raw, "q_*.json"))):
        d = json.load(open(f))
        groups.setdefault((d["variant"], d["dx"]), []).append(d)
    rows = []
    for (var, dx), ds in sorted(groups.items()):
        d0 = ds[0]
        for stage in ("cold", "wind_change"):
            rs = [[r for r in d["rows"] if r["stage"] == stage][0] for d in ds]
            keys = sorted({k for r in rs for k in r["parts"]})
            parts = {k: round(med([r["parts"][k] for r in rs if k in r["parts"]]), 4) for k in keys}
            ex = rs[0]["extra"]
            errs = [r["err"] for r in rs if r["err"]]
            err = None
            if errs:
                err = dict(ref="fp64 (элементное ядро CuPy, как SWG-3) на надземных точках того же окна и стадии; горизонтальная скорость, вектор (u, v); "
                           "max_rel — по точкам |v_ref| ≥ 1 м/с; допуск игры |Δ| ≤ 0,05 + 2 % |v_ref|",
                           n=errs[0]["n"], rms_rel=max(e["rms_rel"] for e in errs), max_rel=max(e["max_rel"] for e in errs),
                           max_abs_ms=max(e["max_abs_ms"] for e in errs), frac_game_ok=min(e["frac_game_ok"] for e in errs),
                           game_excess_ms=max(e["game_excess_ms"] for e in errs))
            gpu = f"до {d0['gpu_before']} после {d0['gpu_after']}"
            note = (f"{DESC[var]}; медиана {len(ds)} повт. (размах t {min(r['t_total_s'] for r in rs):.1f}–{max(r['t_total_s'] for r in rs):.1f} с); "
                    f"N панелей {d0['N_panels']}, ds_min {d0['ds_min']:g} м, σ 40 м, плотная LU f64; опрошено точек {ex['n_points_queried']} из {d0['n_points']}"
                    + (f"; в среднем на точку {ex['pairs_direct_per_pt']:.0f} панелей прямо + {ex['nodes_per_pt']:.0f} узлов" if "pairs_direct_per_pt" in ex else "")
                    + f"; ошибка — максимум по повторениям; GPU (util %, MiB) {gpu} — чужая загрузка")
            rows.append(dict(method="panels", place="ongudai", window_dx=dx, nx=d0["nx"], ny=d0["ny"], nz=d0["nz"], n_points=ex["n_points_queried"],
                             stage=stage, t_total_s=med([r["t_total_s"] for r in rs]), parts=parts, backend="cupy", threads=None,
                             tol_scale=None, note=note, variant=var, err=err))
    base = json.load(open(s3))
    for r in base["rows"]:
        r = dict(r)
        r["variant"] = "fp64"
        r["err"] = None
        rows.append(r)
    doc = dict(format="swg-timing", version=2, git=AT.git_short(), created=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), task="swg-6",
               machine=dict(cpu=AT.cpu_name(), gpu=AT.gpu_name(), threads=os.cpu_count()), rows=rows)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out) or ".", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out)
    print(len(rows), "строк →", out)


if __name__ == "__main__":
    main()
