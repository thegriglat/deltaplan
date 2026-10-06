"""Таблица признаков всех случаев (контракт P6 v2): `$AIR_SYNTH_DATA/phase/features_<plan>.h5`, набор `features` (N,) составной.

    features.py --plan $AIR_SYNTH_DATA/phase/ap_v1 --results $AIR_SYNTH_DATA/phase/ap_v1__s1-74644c4 [--workers 16]

Поля: все `cases` P3 + `order` P3 (f_*) + `bubble` P3 (bub_*, только SEPARATION, иначе NaN) + метрики слоёв
`layer_metrics` (th_*, sl_*, lee_*) + из плана `shape`, `slope`, `h_m`, `h_over_zi`, `variant`, `relief_name`,
`ref_case_id`, `ref400_case_id`, `mech_case_id` + `w100_sl_*`, `w100_lee_*` (окно 100 м серии SEPARATION) +
`ref_iou_th/sl/lee` (совпадение карт слоёв с ref_case_id). Описание с единицами — атрибут `p6_names` (JSON).

ref_case_id — холодный случай той же конфигурации: по `Line.ref_line_id` плана (P2) — случай опорной линии с тем же
Fr (±1 %), иначе −1. Это даёт: SWEEP, RELAX, SEPARATION dx = 400 → GRID той же формы/s/H/h_z_i и Fr (у RELAX
точки 0,2; 0,25; 0,7023… в GRID нет → −1); ENVELOPE → SEPARATION dx = 100 той же формы/s/Fr (эталон; его `fields/f` —
поле области 400 м, решённое 2-м порядком переноса, само окно — в w100_*); ENVELOPE_REAL → та же (место, условия,
решение h/m) без огибающей. Дополнительно у ENVELOPE `ref400_case_id` — SEPARATION dx = 400 без огибающей (та же
сетка и схема, что у ENVELOPE: «что изменила огибающая»).

mech_case_id — «близнец» с H = 0 (та же линия по всем полям, кроме нагрева; холодный старт; тот же Fr): его w —
w_mech для w_conv термиков и для вертикали склонов/подветра (как в игре). Нет — −1 (th_wconv_src = 2).

CPU, пул процессов по частям P3 (часть читается потоково целиком, поля близнецов — точечно из других частей).
"""
from __future__ import annotations

import argparse
import datetime
import json
import multiprocessing as mp
import os
import subprocess
import sys
import time
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import layer_metrics as LM  # noqa: E402
import phase_io as PIO  # noqa: E402

pb = PIO.pb
FR_TOL = 0.01
SER_SEPARATION, SER_ENVELOPE, SER_ENVELOPE_REAL = pb.SEPARATION, pb.ENVELOPE, pb.ENVELOPE_REAL
WIN_GROUPS = ("sl_", "lee_")

CASES_DESC = {
    "case_id": "номер случая (P2)", "line_id": "линия плана", "k": "номер точки в линии", "series": "серия (enum P2)",
    "relief_id": "рельеф плана", "fr": "целевое Fr = U_sat/(N·h), 1", "froude_table": "Fr по conditions.derive, 1",
    "u10": "ветер на 10 м, м/с", "u_sat": "ветер насыщения профиля, м/с", "wdir_from_deg": "направление «откуда», °",
    "n_bv": "частота Брента–Вяйсяля N, 1/с", "z_i_agl_m": "z_i над базой рельефа, м",
    "heat_flux_wm2": "поток явного тепла, Вт/м²", "zi_over_L": "−z_i/L, 1", "dx_m": "шаг сетки линии, м",
    "start_case_id": "случай тёплого старта (−1 — холодный)", "status": "0 ok, 1 max, 2 diverged", "iters": "итераций",
    "target": "0 final, 1 late_mean", "late_n": "снимков в позднем среднем", "late_spread60_p90": "разброс поздних снимков p90, м/с",
    "resid_final": "невязка в конце", "resid_rel_final": "относительная невязка в конце", "seconds": "стенное время / случай, с",
    "batch_size": "размер пакета", "cond_id": "строка S2 (−1 — override)", "envelope_angle_deg": "угол огибающей, °",
    "envelope_wall": "граница огибающей (enum P2)",
}
PLAN_DESC = {
    "shape": "форма рельефа (HILL, RIDGE, STEP_UP, STEP_DOWN, CORPUS)", "slope": "крутизна s = max|∇z| формы (план), 1",
    "h_m": "высота формы h (план), м", "h_over_zi": "h/z_i линии (0 — из S2), 1", "variant": "вариант линии (план)",
    "relief_name": "имя рельефа (план)", "ref_case_id": "холодный случай той же конфигурации (Line.ref_line_id, тот же Fr ±1 %), −1 — нет",
    "ref400_case_id": "ENVELOPE: SEPARATION dx = 400 без огибающей той же формы/s/Fr, −1 — нет",
    "mech_case_id": "близнец с H = 0 (w_mech), −1 — нет",
    "ref_iou_th": "IoU карт источников термиков (±1 клетка) с ref_case_id, 1 (NaN — нет ref)",
    "ref_iou_sl": "IoU карт подъёма у склона (w слоя 50–300 м > 1 м/с) с ref_case_id, 1",
    "ref_iou_lee": "IoU карт подветренной зоны (признак ≥ ½ на 25 м) с ref_case_id, 1",
}
BUBBLE_DESC = "P3 bubble (только SEPARATION, иначе NaN): "
ORDER_DESC = "P3 order — phase_stats.field_features по итоговому полю: "


def git_commit():
    try:
        return subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "--short=8", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def line_key(ln, drop_heat=True):
    nm = ln.numerics.SerializeToString(deterministic=True)
    return (ln.relief_id, round(ln.h_over_zi, 6), round(ln.n_bv_s, 6), round(ln.wdir_from_deg, 3), nm,
            ln.conditions, ln.cond_id) + (() if drop_heat else (round(ln.heat_flux_wm2, 3),))


def build_plan_index(plan_dir):
    """План → {case_id: dict(line, relief, fr, ref_case_id, ref400_case_id, mech_case_id)}."""
    plan, _, lines, rel, cases = PIO.load_plan(plan_dir)
    by_line = {}
    for c in cases:
        by_line.setdefault(c.line_id, []).append(c)

    def match(line_id, fr):
        for c in by_line.get(line_id, []):
            if abs(c.fr / fr - 1.0) <= FR_TOL:
                return c.case_id
        return -1

    cold0 = {}                                   # ключ без нагрева → холодные линии с H = 0
    for ln in plan.lines:
        if ln.start == pb.COLD and ln.heat_flux_wm2 == 0.0:
            cold0.setdefault(line_key(ln), []).append(ln.line_id)
    sep400 = {}
    for ln in plan.lines:
        if ln.series == SER_SEPARATION and ln.numerics.dx_m == 400.0:
            sep400.setdefault((ln.relief_id, round(ln.h_over_zi, 6), round(ln.n_bv_s, 6), round(ln.wdir_from_deg, 3),
                               round(ln.heat_flux_wm2, 3)), []).append(ln.line_id)
    out = {}
    for c in cases:
        ln = lines[c.line_id]
        ref = match(ln.ref_line_id, c.fr) if ln.ref_line_id >= 0 else -1
        ref400 = -1
        if ln.series == SER_ENVELOPE:
            for lid in sep400.get((ln.relief_id, round(ln.h_over_zi, 6), round(ln.n_bv_s, 6),
                                   round(ln.wdir_from_deg, 3), round(ln.heat_flux_wm2, 3)), []):
                ref400 = match(lid, c.fr)
                if ref400 >= 0:
                    break
        mech = -1
        if ln.heat_flux_wm2 != 0.0:
            for lid in cold0.get(line_key(ln), []):
                mech = match(lid, c.fr)
                if mech >= 0:
                    break
        out[c.case_id] = dict(line=ln, relief=rel[ln.relief_id], fr=c.fr, ref=ref, ref400=ref400, mech=mech)
    return plan, out


def scan_results(res_dir):
    """case_id → (часть, строка, status) по наборам cases всех частей."""
    idx = {}
    for p in PIO.parts(res_dir):
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
        for r, (cid, st) in enumerate(zip(c["case_id"], c["status"])):
            idx[int(cid)] = (str(p), r, int(st))
    return idx


# ------------------------------------------------------------------ работник
_G = {}


def _init(plan_dir, res_dir, index):
    _G["plan"], _G["pi"] = build_plan_index(plan_dir)
    _G["index"] = index
    _G["files"] = {}


def _h5(path):
    fs = _G["files"]
    if path not in fs:
        if len(fs) >= 8:
            fs.pop(next(iter(fs))).close()
        fs[path] = h5py.File(path, "r")
    return fs[path]


def _w_of(case_id):
    p, r, st = _G["index"][case_id]
    if st == 2:
        return None
    return np.asarray(_h5(p)["fields/f"][r, 2], np.float32)


def _pack(m):
    return np.packbits(m.ravel())


def process_part(path):
    rows = []
    with h5py.File(path, "r") as h:
        c = h["cases"][:]
        F = h["fields/f"]
        hc_all = h["inputs/hc"][:]
        hf_all = h["inputs/heat_flux"][:].astype(np.float32)
        hbl_all = h["inputs/hbl"][:].astype(np.float32)
        heff_all = h["inputs/h_eff"][:] if "inputs/h_eff" in h else None
        order = h["order"][:]
        bub = h["bubble"][:] if "bubble" in h else None
        win = {}
        if "window" in h:
            wc = h["window/case_id"][:]
            for q, cid in enumerate(wc):
                win[int(cid)] = q
        for r in range(c.shape[0]):
            cid = int(c["case_id"][r])
            info = _G["pi"][cid]
            ln, rl = info["line"], info["relief"]
            case = {n: c[n][r].item() for n in c.dtype.names}
            case.update(h_m=float(rl.h_m), slope=float(rl.slope), shape=pb.Shape.Name(rl.shape))
            if heff_all is not None and case["envelope_angle_deg"] > 0:
                case["h_eff"] = np.asarray(heff_all[r], np.float64)
            f = np.asarray(F[r], np.float32)
            wm = None
            if info["mech"] >= 0 and info["mech"] in _G["index"]:
                wm = _w_of(info["mech"])
            mech_used = info["mech"] if wm is not None else -1
            met = LM.layer_metrics(f, hc_all[r], hf_all[r], hbl_all[r], case, w_mech=wm)
            masks = LM.layer_masks(f, hc_all[r], hf_all[r], case, w_mech=wm) if case["status"] != 2 else None
            row = {n: c[n][r] for n in c.dtype.names}
            for n in order.dtype.names:
                row[n] = float(order[n][r])
            if bub is not None and case["series"] == SER_SEPARATION:
                for n in bub.dtype.names:
                    row["bub_" + n] = float(bub[n][r])
            row.update(met)
            if cid in win:
                q = win[cid]
                shp = h["window/shape"][q]
                wf = np.asarray(h["window/fields"][q], np.float32)[:, :, :shp[2], :shp[3]]
                whc = np.asarray(h["window/hc"][q], np.float64)[:shp[2], :shp[3]]
                wcase = dict(case)
                wcase.pop("h_eff", None)
                wmet = LM.slope_lee_metrics(wf, whc, wcase, dx=100.0, x0=float(h["window/x0_m"][q]),
                                            y0=float(h["window/y0_m"][q]), groups=WIN_GROUPS)
                for k, v in wmet.items():
                    row["w100_" + k] = v
            row.update(shape=case["shape"], slope=case["slope"], h_m=case["h_m"], h_over_zi=float(ln.h_over_zi),
                       variant=ln.variant, relief_name=rl.name, ref_case_id=info["ref"],
                       ref400_case_id=info["ref400"], mech_case_id=mech_used)
            pk = None if masks is None else {k: _pack(v) for k, v in masks.items()}
            rows.append((cid, row, pk))
    return rows


# ------------------------------------------------------------------ сборка
def descriptions(names, order_names, bub_names):
    d = {}
    for n in names:
        if n in CASES_DESC:
            d[n] = "P3 cases: " + CASES_DESC[n]
        elif n in PLAN_DESC:
            d[n] = PLAN_DESC[n]
        elif n in LM.NAMES:
            d[n] = LM.NAMES[n]
        elif n.startswith("w100_") and n[5:] in LM.NAMES:
            d[n] = "окно 100 м (SEPARATION dx = 100, window/fields), иначе NaN: " + LM.NAMES[n[5:]]
        elif n in order_names:
            d[n] = ORDER_DESC + n
        elif n.startswith("bub_") and n[4:] in bub_names:
            d[n] = BUBBLE_DESC + n[4:]
        else:
            d[n] = n
    return d


def build_table(rows, case_dtype, order_names, bub_names):
    met_names = [k for k in LM.NAMES if k.startswith(LM.GROUPS)]
    win_names = ["w100_" + k for k in LM.NAMES if k.startswith(WIN_GROUPS)]
    fields = [(n, case_dtype[n]) for n in case_dtype.names]
    fields += [(n, "f4") for n in order_names]
    fields += [("bub_" + n, "f4") for n in bub_names]
    fields += [(n, "f4") for n in met_names + win_names]
    fields += [("shape", "S12"), ("slope", "f4"), ("h_m", "f4"), ("h_over_zi", "f4"), ("variant", "S16"),
               ("relief_name", "S32"), ("ref_case_id", "i8"), ("ref400_case_id", "i8"), ("mech_case_id", "i8"),
               ("ref_iou_th", "f4"), ("ref_iou_sl", "f4"), ("ref_iou_lee", "f4")]
    dt = np.dtype(fields)
    tab = np.zeros(len(rows), dt)
    for n in dt.names:
        if dt[n].kind == "f":
            tab[n] = np.nan
    for q, (_, row, _) in enumerate(rows):
        for k, v in row.items():
            if k in dt.names:
                tab[k][q] = v.encode() if isinstance(v, str) else v
    return tab


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--plan", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--out", default=None, help="по умолчанию $AIR_SYNTH_DATA/phase/features_<plan>.h5 (P6 v2)")
    ap.add_argument("--workers", type=int, default=max(1, min(16, (os.cpu_count() or 2) - 2)))
    ap.add_argument("--limit-parts", type=int, default=0, help="только первые N частей (проба)")
    a = ap.parse_args(argv)
    t0 = time.time()
    plan_dir, res_dir = Path(a.plan).expanduser(), Path(a.results).expanduser()
    plan, pi = build_plan_index(plan_dir)
    index = scan_results(res_dir)
    parts = [str(p) for p in PIO.parts(res_dir)]
    if a.limit_parts:
        parts = parts[:a.limit_parts]
    with h5py.File(parts[0], "r") as h:
        case_dtype = h["cases"].dtype
        order_names = list(h["order"].dtype.names)
    bub_names = ["has_reverse", "L_over_h", "H_over_h", "urev_over_U", "xc_over_h", "zc_over_h", "area_rev_frac",
                 "shadow_angle_deg", "fr_local", "slope_lee"]
    rows = []
    with mp.get_context("fork").Pool(a.workers, initializer=_init, initargs=(plan_dir, res_dir, index)) as pool:
        for n, got in enumerate(pool.imap_unordered(process_part, parts, chunksize=1)):
            rows.extend(got)
            if (n + 1) % 50 == 0:
                print(f"частей {n + 1}/{len(parts)}, {time.time() - t0:.0f} с", flush=True)
    rows.sort(key=lambda x: x[0])
    tab = build_table(rows, case_dtype, order_names, bub_names)
    # IoU карт с опорным случаем
    pos = {cid: q for q, (cid, _, _) in enumerate(rows)}
    n_ref = 0
    for q, (cid, row, pk) in enumerate(rows):
        ref = row["ref_case_id"]
        if ref < 0 or ref not in pos or pk is None or rows[pos[ref]][2] is None:
            continue
        rk = rows[pos[ref]][2]
        for g in ("th", "sl", "lee"):
            tab["ref_iou_" + g][q] = LM.iou(np.unpackbits(pk[g]).astype(bool), np.unpackbits(rk[g]).astype(bool))
        n_ref += 1
    data = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data")))
    out = Path(a.out) if a.out else data / "phase" / f"features_{plan.name}.h5"
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".h5.tmp")
    desc = descriptions(tab.dtype.names, order_names, bub_names)
    with h5py.File(tmp, "w") as h:
        h.create_dataset("features", data=tab, compression="gzip", compression_opts=4, shuffle=True)
        h.attrs.update(contract="P6 v2", plan=str(plan_dir), results=str(res_dir), git_commit=git_commit(),
                       p6_names=json.dumps(desc, ensure_ascii=False), created=datetime.datetime.now().isoformat(timespec="seconds"),
                       command="features.py " + " ".join(argv if argv is not None else sys.argv[1:]),
                       n_cases=len(tab), n_parts=len(parts), seconds=round(time.time() - t0, 1))
    os.replace(tmp, out)
    print(json.dumps(dict(out=str(out), n=len(tab), n_ref_iou=n_ref, n_ref=int((tab["ref_case_id"] >= 0).sum()),
                          n_mech=int((tab["mech_case_id"] >= 0).sum()), seconds=round(time.time() - t0, 1),
                          mb=round(out.stat().st_size / 1e6, 2)), ensure_ascii=False))


if __name__ == "__main__":
    main()
