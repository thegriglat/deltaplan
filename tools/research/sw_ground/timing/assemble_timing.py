"""Сборка timing.json (SWG4 v1) из сырых прогонов: out/swg-3/raw/panels_*.json и picard_*.json → медианы по повторениям.
  assemble_timing.py <raw_dir> <out.json>
"""
import glob
import json
import os
import statistics as st
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


def med(xs):
    return float(st.median(xs))


def git_short():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def cpu_name():
    for ln in open("/proc/cpuinfo"):
        if ln.startswith("model name"):
            return ln.split(":", 1)[1].strip()
    return "?"


def gpu_name():
    try:
        return subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def panel_rows(raw):
    groups = {}
    for f in sorted(glob.glob(os.path.join(raw, "panels*.json"))):
        d = json.load(open(f))
        groups.setdefault((d["method"], d["dx"]), []).append(d)
    out = []
    for (method, dx), ds in sorted(groups.items()):
        d0 = ds[0]
        for stage in ("cold", "wind_change"):
            rs = [[r for r in d["rows"] if r["stage"] == stage][0] for d in ds]
            for r in rs:       # в t_total_s замер «чистого potential» (отдельный вызов velocity) входил — вычитаем
                r["t_total_s"] -= r.get("pure") or 0.0
            keys = sorted({k for r in rs for k in r["parts"]})
            parts = {k: med([r["parts"][k] for r in rs if k in r["parts"]]) for k in keys}
            ex = rs[0]["extra"]
            pure = [r["pure"] for r in rs if r.get("pure") is not None]
            gpu = "; ".join(f"до {d['gpu_before']} после {d['gpu_after']}" for d in ds[:1])
            note = (f"медиана {len(ds)} повт. (свежий процесс на повторение; размах t = {min(r['t_total_s'] for r in rs):.1f}–{max(r['t_total_s'] for r in rs):.1f} с); "
                    f"N панелей {d0['N_panels']}, ds_min {d0['ds_min']:g} м, σ 40 м, z0 {d0['z0']:g} м (медиана растра), фон log, плотная LU f64 на GPU (память {d0['mem_gb']:.1f} ГБ); "
                    f"подземных точек {100 * ex['under_frac']:.1f} % (NaN); "
                    + (f"чистый potential (velocity, без JH) {med(pure):.1f} с; " if pure else "")
                    + (f"нить: хребтов {ex.get('rotor_ridges')}, кандидатов {ex.get('rotor_candidates')}, поставлено {ex.get('rotor_placed')}; " if "rotor" in parts else "")
                    + f"GPU (util %, MiB) {gpu} — чужая загрузка")
            out.append(dict(method=method, place="ongudai", window_dx=dx, nx=d0["nx"], ny=d0["ny"], nz=d0["nz"], n_points=d0["n_points"],
                            stage=stage, t_total_s=med([r["t_total_s"] for r in rs]), parts={k: round(v, 4) for k, v in parts.items()},
                            backend="cupy", threads=None, tol_scale=None, note=note))
    return out


def picard_rows(raw):
    out = []
    for f in sorted(glob.glob(os.path.join(raw, "picard_*.json"))):
        pass
    groups = {}
    for f in sorted(glob.glob(os.path.join(raw, "picard_*.json"))):
        d = json.load(open(f))
        groups.setdefault((d["threads"], d["tol_scale"]), []).append(d)
    nzs = {100: 62, 50: 112}
    for (thr, tol), ds in sorted(groups.items()):
        for stage, key in (("cold", "cold"), ("wind_change", "wind_change")):
            for dx in (100, 50):
                ws = []
                for d in ds:
                    w = [w for w in d[key]["windows"] if int(round(w["dx"])) == dx]
                    if not w:
                        break
                    ws.append((w[0], d[key]))
                if not ws:
                    continue
                names = ["prep", "bc_start", "solve", "field"]
                parts = {n: med([w["secs"][i] for w, _ in ws]) for i, n in enumerate(names)}
                t = med([w["t_s"] for w, _ in ws])
                area = med([sum(r["passes"][-1]["secs"]) for _, r in ws])
                wall = med([r["wall_s"] for _, r in ws])
                it = ws[0][0]["iters"]
                note = (f"только окно {dx} м (поле Пикара = Formula dp-air, пара mech+heat; окно после области); область того же прохода {area:.1f} с, "
                        f"стена load_place→Ready (область + оба окна) {wall:.1f} с; итерации окна mech/heat {it[0]}/{it[1]}; "
                        f"{'тёплый старт окна' if ws[0][0]['warm'] else 'холодный старт окна от родителя'}; случай: Онгудай, ясно, 24 °C, ветер 7,5 м/с с 151° "
                        f"({'→ 9 м/с с 181°' if stage == 'wind_change' else ''}); считает ещё нагрев и фазы — не то же поле, что панели; "
                        f"медиана {len(ws)} повт.; размах t {min(w['t_s'] for w, _ in ws):.1f}–{max(w['t_s'] for w, _ in ws):.1f} с")
                out.append(dict(method="picard", place="ongudai", window_dx=dx, nx=64, ny=64, nz=nzs[dx], n_points=64 * 64 * nzs[dx], stage=stage,
                                t_total_s=t, parts={k: round(v, 4) for k, v in parts.items()}, backend="rust", threads=thr, tol_scale=tol, note=note))
    return out


def main():
    raw, out = sys.argv[1], sys.argv[2]
    thr = os.cpu_count()
    doc = dict(format="swg-timing", version=1, git=git_short(), created=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), task="swg-3",
               machine=dict(cpu=cpu_name(), gpu=gpu_name(), threads=thr), rows=panel_rows(raw) + picard_rows(raw))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out) or ".", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out)
    print(len(doc["rows"]), "строк →", out)


if __name__ == "__main__":
    main()
