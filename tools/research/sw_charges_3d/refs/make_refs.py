"""SWD-1: поля Пикара (air3d, постановка Б1: nom и adv1) для ASK_TU03B, PERD_NE, PERD_SW → out/refs/<case>.h5 (SWD1),
значения в точках и ротор → out/refs/_cache/<case>_<variant>.json; сборка points.json/.csv — `assemble`.

  py refs/make_refs.py run [case[:variant] ...]   прогоны (продолжение: готовые группы пропускаются), GPU, ~10 мин
  py refs/make_refs.py assemble                   points.json + points.csv из кэша
Решатель и модули случаев не меняются (импорт: cases/askervein.py, cases/perdigao.py, air3d/*; стиль — cases/b1/ctl.py).
"""
from __future__ import annotations

import csv
import json
import math
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import points as P   # noqa: E402

PD, AK = P.PD, P.AK
sys.path.insert(0, str(P.RES / "air3d"))
sys.path.insert(0, str(P.RES / "morris"))
import synth as SY   # noqa: E402

OUT = HERE.parent / "out/refs"
CACHE = OUT / "_cache"
VARIANTS = {"nom": None, "adv1": {"adv2": False}}
SCALE = 0.002            # м/с на единицу int16: ошибка квантования ≤ 0,001 м/с
INTERP = ("линейно по z вдоль колонны клеток Пикара (synth.agl): z = земля Пикара + z_agl; ниже центра первой воздушной клетки "
          "— её значение; по x, y — центры клеток (без интерполяции)")


def git_rev():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=P.ROOT, text=True).strip()
    except Exception:
        return "unknown"


def mod_of(case):
    return AK if case == "ASK_TU03B" else PD


def clean(x):
    if isinstance(x, (np.floating, float)):
        x = float(x)
        return None if not math.isfinite(x) else x
    if isinstance(x, np.integer):
        return int(x)
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [clean(v) for v in x]
    return x


def run_picard(case, variant):
    mod = mod_of(case)
    sub = P.CASES[case]["sub"]
    r = mod.run_one({}, sub, mod.DX_NOM, ctl=VARIANTS[variant], keep=True)
    if "_S" not in r:
        raise RuntimeError(f"{case} {variant}: {r.get('status')} {r.get('err')}")
    return r


def quant(a):
    raw = np.full(a.shape, -32768, "i2")
    ok = np.isfinite(a)
    raw[ok] = np.clip(np.rint(a[ok] / SCALE), -32767, 32767).astype("i2")
    return raw


def write_group(h, case, variant, S, r):
    g = S.g
    mod = mod_of(case)
    u, v, w, _ = S.centers()
    base = 0.0 if case == "ASK_TU03B" else PD.BASE
    gname = f"picard_{variant}"
    if gname in h:
        del h[gname]
    grp = h.create_group(gname)
    x = (g.x0 + (np.arange(g.nx) + 0.5) * g.dx)
    y = (g.y0 + (np.arange(g.ny) + 0.5) * g.dx)
    grp["x"] = x
    grp["y"] = y
    zg = (S.hc + base).astype("f4")
    grp["z_ground"] = zg
    ztop = g.z_bot + g.nz * g.dz - g.dz
    levels = []
    fields = {k: [] for k in "uvw"}
    for zl in P.Z_LEVELS:
        valid = (S.hc + zl) <= ztop
        if valid.mean() < 0.99:
            continue
        levels.append(zl)
        for k, F in zip("uvw", (u, v, w)):
            a = SY.agl(S, F, float(zl)).astype("f8")
            a[~valid] = np.nan
            fields[k].append(a)
    grp["z_agl"] = np.array(levels, "f4")
    for k in "uvw":
        arr = np.stack(fields[k])
        d = grp.create_dataset(k, data=quant(arr), chunks=(1, g.ny, g.nx), compression="gzip", compression_opts=4)
        d.attrs["scale"] = SCALE
        d.attrs["offset"] = 0.0
        d.attrs["units"] = "m/s"
        d.attrs["interp"] = INTERP
    grp.attrs["interp"] = INTERP
    prm = dict(r["params"])
    prm.update(case=case, variant=variant, dx=r["dx"], ctl=r.get("ctl"), geo=r.get("geo"), scheme="nom: 2-й порядок переноса "
               "(общая схема C10 v3); adv1: adv2=False, 1-й порядок — схема игры", sponge_side_m=mod.geometry()["sponge_side"],
               sponge_top_m=mod.geometry()["sponge_top"], z_ground_frame="асл" + ("" if case == "ASK_TU03B" else f" (hc + BASE {PD.BASE:g} м)"))
    grp.attrs["params"] = json.dumps(clean(prm), ensure_ascii=False)
    grp.attrs["status"] = str(r["status"])
    grp.attrs["iters"] = int(r["iters"])
    grp.attrs["wall_s"] = float(r["t"])
    grp.attrs["dx"] = float(r["dx"])
    if case == "ASK_TU03B":
        grp.attrs["U_ref"], grp.attrs["z_ref"] = AK.U10_IN, 10.0
        grp.attrs["U_ref_note"] = "U10 фона (приток): модель на RS 10 м = 8,895 м/с данных"
    else:
        sub = P.CASES[case]["sub"]
        grp.attrs["U_ref"], grp.attrs["z_ref"] = PD.U10_IN[sub], 10.0
        grp.attrs["U_ref_note"] = "U10 фона (приток); U100 мачты " + PD.case_inputs(sub)["ref"] + f" = {PD.case_inputs(sub)['u100']:.2f} м/с"
    grp.attrs["levels_dropped"] = [int(z) for z in P.Z_LEVELS if z not in levels]


def ensure_file(case):
    import h5py
    OUT.mkdir(parents=True, exist_ok=True)
    f = OUT / f"{case}.h5"
    R = P.terrain_raster(case)
    ex, ey = P.wind_to(case)
    with h5py.File(f, "a") as h:
        h.attrs.update({"format": "sw3d-ref", "version": 1, "case": case, "git": git_rev(),
                        "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "wind_to": [ex, ey],
                        "wind_from_deg": float(P.wind_from(case))})
        if "terrain" in h:
            del h["terrain"]
        t = h.create_group("terrain")
        t["x"], t["y"] = R["x"], R["y"]
        t.create_dataset("z", data=R["z"], chunks=True, compression="gzip", compression_opts=4)
        t.create_dataset("z0", data=R["z0"], chunks=True, compression="gzip", compression_opts=4)
        t.attrs.update({"dx": R["dx"], "source": R["source"], "smoothing": R["smoothing"]})
    return f


# ---------------------------------------------------------------- значения в точках и ротор
def pts_for_eval(case):
    """Все положения, где нужно поле Пикара: мачты, синтетические, опорная, RS на уровнях мачт (Askervein dS)."""
    ev = {}

    def add(key, x, y, z):
        ev[key] = (float(x), float(y), float(z))
    nm = P.norm_point(case)
    add("norm", nm["x"], nm["y"], nm["z_agl"])
    for i, m in enumerate(P.masts(case)):
        add(f"m{i}", m["x"], m["y"], m["z_agl"])
        if case == "ASK_TU03B":
            add(f"rs@{m['z_agl']:g}", P.RS_ASK[0], P.RS_ASK[1], m["z_agl"])
    for name, s in P.synthetic(case).items():
        for z in P.Z_SYN:
            add(f"syn:{name}:{z:g}", s["x"], s["y"], z)
    return ev


def eval_points(S, ev):
    keys = list(ev)
    x = np.array([ev[k][0] for k in keys])
    y = np.array([ev[k][1] for k in keys])
    z = np.array([ev[k][2] for k in keys])
    hs = PD.surface_at(S, x, y)
    zt = hs + z
    u, v, w, _ = S.centers()
    uu, vv, ww = (PD.sample(S, F, x, y, zt) for F in (u, v, w))
    return {k: dict(u=float(a), v=float(b), w=float(c), speed=float(math.sqrt(a * a + b * b + c * c)),
                    ground=float(h) + (0.0 if True else 0.0))
            for k, a, b, c, h in zip(keys, uu, vv, ww, hs)}


def rotor_line(S, u, v, ex, ey, tr):
    """Критерий SWD5: u∥ < −0,5 м/с на z_agl 15 м, самый длинный участок > 50 м вдоль разреза (шаг 10 м); глубина —
    наибольший z_agl области u∥ < −0,5 (шаг 15 м от 15 до 600 м), связной с этим участком."""
    from scipy import ndimage
    L0 = math.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"])
    s = np.arange(0.0, L0 + 1e-9, 10.0)
    px = tr["x0"] + s * (tr["x1"] - tr["x0"]) / L0
    py = tr["y0"] + s * (tr["y1"] - tr["y0"]) / L0
    ux = (tr["x1"] - tr["x0"]) / L0
    uy = (tr["y1"] - tr["y0"]) / L0
    if ux * ex + uy * ey < 0:
        px, py = px[::-1], py[::-1]
    hs = PD.surface_at(S, px, py)
    zl = np.arange(P.ROTOR_Z, 600.0 + 1e-9, 15.0)
    up = np.full((len(zl), len(s)), np.nan)
    for k, zz in enumerate(zl):
        up[k] = PD.sample(S, u, px, py, hs + zz) * ex + PD.sample(S, v, px, py, hs + zz) * ey
    inv = np.nan_to_num(up, nan=0.0) < P.ROTOR_U
    row0 = inv[0]
    best = cur = bi = 0
    for i, f in enumerate(row0):
        cur = cur + 1 if f else 0
        if cur > best:
            best, bi = cur, i
    L = best * 10.0
    present = L > P.ROTOR_LMIN
    depth = 0.0
    if present:
        lab, _ = ndimage.label(inv)
        comp = lab == lab[0, bi]
        depth = float(zl[np.where(comp.any(axis=1))[0].max()])
    return dict(transect=tr["name"], present=bool(present), L_m=float(L if present else 0.0), depth_m=float(depth if present else 0.0),
                u_par_min=float(np.nanmin(up[0])))


def process(case, variant, r):
    S = r.pop("_S")
    ev = pts_for_eval(case)
    vals = eval_points(S, ev)
    ex, ey = P.wind_to(case)
    u, v, w, _ = S.centers()
    rot = [rotor_line(S, u, v, ex, ey, tr) for tr in P.transects(case)]
    import h5py
    f = ensure_file(case)
    with h5py.File(f, "a") as h:
        write_group(h, case, variant, S, r)
    import model as M
    M.free(S)
    CACHE.mkdir(parents=True, exist_ok=True)
    meta = dict(case=case, variant=variant, status=r["status"], iters=r["iters"], t=r["t"], n_cells=r.get("geo", {}).get("n_cells"),
                U10_in=r.get("inputs", {}).get("u10_in"))
    (CACHE / f"{case}_{variant}.json").write_text(json.dumps(clean(dict(meta=meta, vals=vals, rotor=rot)), ensure_ascii=False))
    return meta, rot


def cmd_run(argv):
    import h5py
    want = set(argv)
    for case in P.CASES:
        for variant in VARIANTS:
            tag = f"{case}:{variant}"
            if want and tag not in want and case not in want:
                continue
            f = OUT / f"{case}.h5"
            if (CACHE / f"{case}_{variant}.json").exists() and f.exists():
                with h5py.File(f, "r") as h:
                    if f"picard_{variant}" in h:
                        print(tag, "готово — пропуск", flush=True)
                        continue
            t0 = time.perf_counter()
            r = run_picard(case, variant)
            meta, rot = process(case, variant, r)
            print(f"{tag}: {meta['status']} {meta['iters']} it, решатель {meta['t']:.1f} с, всего {time.perf_counter() - t0:.0f} с; "
                  f"ротор { [(x['transect'], x['L_m']) for x in rot] }", flush=True)


# ---------------------------------------------------------------- points.json
def cmd_assemble():
    rows, norm, trs, rotor = [], {}, [], []
    for case in P.CASES:
        nm = P.norm_point(case)
        norm[case] = dict(name=nm["name"], x=nm["x"], y=nm["y"], z_agl=nm["z_agl"], source=nm["source"])
        trs += [clean(t) for t in P.transects(case)]
        cache = {}
        for variant in VARIANTS:
            fn = CACHE / f"{case}_{variant}.json"
            if fn.exists():
                cache[variant] = json.loads(fn.read_text())
        ms = P.masts(case)
        syn = P.synthetic(case)
        mod_note = "air3d Б1 (cases/b1/ctl.py)"

        def prow(ev_key, x, y, z, name, point, variant, vals, extra_note=""):
            d = vals[ev_key]
            nv = vals["norm"]["speed"]
            zin = z < (AK.MIN_AGL if case == "ASK_TU03B" else PD.MIN_AGL)
            row = dict(case=case, name=name, point=point, x=x, y=y, z_agl=z, ref_kind=f"picard_{variant}",
                       ref_source=f"{mod_note} {variant}: tools/research/sw_charges_3d/out/refs/{case}.h5 (picard_{variant}); "
                                  f"значение в точке — PD.sample (билинейно по столбцам, линейно по z над землёй Пикара)"
                                  + ("; ниже 1·dz над землёй — значение первой клетки (ненадёжно)" if zin else "") + extra_note,
                       ref_reliability="модель ±15 %", ref_err=None, u=d["u"], v=d["v"], w=d["w"], speed=d["speed"],
                       s_norm=d["speed"] / nv, dS=None)
            if case == "ASK_TU03B":
                rs = vals.get(f"rs@{z:g}")
                row["dS"] = d["speed"] / rs["speed"] - 1.0 if rs else None
            return row

        for i, m in enumerate(ms):
            dS = m["dS"]
            rows.append(dict(case=case, name=m["name"], point=m["point"], x=m["x"], y=m["y"], z_agl=m["z_agl"], ref_kind="mast",
                             ref_source=m["ref_source"], ref_reliability="измерение", ref_err=m["ref_err"], u=m["u"], v=m["v"],
                             w=m["w"], speed=m["speed"], s_norm=m["speed"] / nm["speed"], dS=dS))
            for variant, c in cache.items():
                rows.append(prow(f"m{i}", m["x"], m["y"], m["z_agl"], m["name"], m["point"], variant, c["vals"]))
        for variant, c in cache.items():
            for pname, s in syn.items():
                for z in P.Z_SYN:
                    rows.append(prow(f"syn:{pname}:{z:g}", s["x"], s["y"], z, f"P_{pname}_0", pname, variant, c["vals"],
                                     f"; положение: {pname} на линии вдоль ветра через {'вершину HT' if case == 'ASK_TU03B' else 'гребень NE/SW гряды'}"
                                     f", земля {s['ground']:.0f} м асл"))
        # ротор
        if case == "ASK_TU03B":
            rotor.append(dict(case=case, transect="wind_HT", source="masts", present=None, L_m=None, depth_m=None,
                              criterion=f"u∥ < {P.ROTOR_U} м/с на z_agl {P.ROTOR_Z:g} м на отрезке > {P.ROTOR_LMIN:g} м",
                              ref_source="Askervein: измерений обратного течения за холмом нет (мачты на 10 м и профиль HT, Taylor & Teunissen 1987)"))
        else:
            ml = P.menke_ref(case)
            for k in (1, 2, 3):
                rotor.append(dict(case=case, transect=f"menke_T{k}", source="menke2019", present=True, L_m=ml[k], depth_m=157.0,
                                  criterion="нулевой контур среднего u∥ по периодам с рециркуляцией, ±50 м; средняя глубина 157 м над дном",
                                  ref_source="Menke et al. 2019, ACP 19, 2713, Рис. 8 (menke2019/fig8_zones_approx.csv, по рисунку ±50 м), "
                                             "Рис. 8 и текст (глубина 157 ± 30 м); условная статистика по периодам с рециркуляцией"))
        for variant, c in cache.items():
            for rr in c["rotor"]:
                rotor.append(dict(case=case, transect=rr["transect"], source=f"picard_{variant}", present=rr["present"],
                                  L_m=rr["L_m"], depth_m=rr["depth_m"],
                                  criterion=f"u∥ < {P.ROTOR_U} м/с на z_agl {P.ROTOR_Z:g} м, участок > {P.ROTOR_LMIN:g} м вдоль разреза; "
                                            f"глубина — max z_agl связной области u∥ < {P.ROTOR_U} м/с",
                                  ref_source=f"{CACHE.name}/{case}_{variant}.json (поле Пикара {variant})"))
    doc = dict(format="sw3d-points", version=1, git=git_rev(), created=time.strftime("%Y-%m-%dT%H:%M:%S%z"), norm=norm, rows=rows,
               transects=trs, rotor=rotor)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "points.json").write_text(json.dumps(clean(doc), ensure_ascii=False, indent=1))
    cols = ["case", "name", "point", "x", "y", "z_agl", "ref_kind", "ref_reliability", "ref_err", "u", "v", "w", "speed", "s_norm", "dS", "ref_source"]
    with open(OUT / "points.csv", "w", newline="") as fh:
        wr = csv.writer(fh)
        wr.writerow(cols)
        for r in rows:
            wr.writerow([r[c] for c in cols])
    print("points.json:", len(rows), "строк,", len(trs), "разрезов,", len(rotor), "строк ротора")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        cmd_run(sys.argv[2:])
    elif cmd == "assemble":
        cmd_assemble()
    else:
        raise SystemExit(__doc__)
