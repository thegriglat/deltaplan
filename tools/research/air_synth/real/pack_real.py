#!/usr/bin/env python3
"""SY-6: вырезки П6 v3 (terrain_cut.py, пилот air-nn) -> корпус S1 v2 + сводка out/real_summary.json.

  pack_real.py pack  [--data DIR] [--out CORPUS_ROOT]   # tiles/v3 -> real/p6v3, ref_* -> real/game, сводка
  pack_real.py clean [--data DIR]                       # удалить raw/, tiles/, work/ (только после complete + проверки)

g100 = блочное среднее 4×4 узлов h (25 м) по области ±19 200 м (узлы 32…1567), g400 = блочное среднее 4×4 g100;
проверка g400 = hc400 П6 <= 1e-6 м до квантования. Корпусной писатель — ../corpus/corpus_io.py (SY-1).
"""
import argparse, csv, hashlib, json, os, shutil, sys, time
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "corpus"))
import corpus_io as cio  # noqa: E402

PILOT = HERE.parents[1] / "air_nn_pilot"
REF_TABLE = PILOT / "figures/p2_terrain_v3/systems_table.json"
REF_FEATS = PILOT / "figures/p2_terrain_v3/features_ref.json"
GAME = ["askarovo", "aushkul", "altai", "ongudai"]
I0, N = 32, 1536     # область ±19 200 м на сетке 25 м (узел 800 — центр, начало −20 000 м)


def data_dir(a):
    return Path(a.data or os.environ.get("AIR_NN_DATA") or "/home/greg/sy6_data")


def grids(h):
    """h (1601,1601) float32 -> (z100 float64 (384,384), z400 float64 (96,96))."""
    s = np.asarray(h, np.float64)[I0:I0 + N, I0:I0 + N]
    z100 = s.reshape(384, 4, 384, 4).mean(axis=(1, 3))
    z400 = z100.reshape(96, 4, 96, 4).mean(axis=(1, 3))
    return z100, z400


LO, HI = cio.OFFSET_M - 32768 * cio.SCALE_M, cio.OFFSET_M + 32767 * cio.SCALE_M
CLIPPED = []   # места, где узлы вне диапазона int16 контракта S1 v3 (выбросы Terrarium) — обрезаны, записано в сводку


def relief_from(npz_path, place):
    """-> (dict для corpus_io.write_reliefs, max |g400 − hc400| до квантования).
    Выброс вне диапазона кодировки (контракт: ошибка записи) обрезается на уровне g100 до границы диапазона и
    фиксируется в CLIPPED; g400 тогда считается из обрезанного g100 и от hc400 П6 отличается (записано)."""
    d = np.load(npz_path)
    z100, z400 = grids(d["h"])
    n_out = int(((z100 < LO) | (z100 > HI)).sum())
    if n_out:
        CLIPPED.append(dict(name=place["name"], cells_g100=n_out, g100_min=float(z100.min()), g100_max=float(z100.max())))
        z100 = np.clip(z100, LO, HI)
    err = float(np.abs(cio.block_mean(z100, 4) - d["hc400"]).max())
    if n_out:
        CLIPPED[-1]["g400_vs_hc400_max_abs_m"] = err
        err = 0.0
    else:
        assert err <= 1e-6, (npz_path, err)
    return dict(z100=z100, place=place), err


def agg(rows, label):
    g = lambda k: np.array([float(r[k]) for r in rows])
    return dict(group=label, n=len(rows), slope_p50_med=float(np.median(g("slope_p50"))),
                slope_p50_min=float(g("slope_p50").min()), slope_p50_max=float(g("slope_p50").max()),
                slope_p95_med=float(np.median(g("slope_p95"))), relief_med=float(np.median(g("relief_m"))),
                relief_min=float(g("relief_m").min()), relief_max=float(g("relief_m").max()))


def compare_v3(rows):
    """Состав по системам и частям против p2_terrain_v3/systems_table.json (n точно, числа 1e-6 относительно)."""
    mine = [agg([r for r in rows if r["part"] == "pool"], "пул")]
    for s in sorted({r["system"] for r in rows if r["part"] == "holdout"}):
        mine.append(agg([r for r in rows if r["part"] == "holdout" and r["system"] == s], f"отложено: {s}"))
    ref = {x["group"]: x for x in json.loads(REF_TABLE.read_text())}
    det, ok = [], True
    for m in mine:
        r = ref.get(m["group"])
        if r is None:
            det.append(dict(group=m["group"], error="нет в эталоне")); ok = False; continue
        diff = {k: abs(m[k] - r[k]) for k in m if k != "group"}
        good = m["n"] == r["n"] and all(v <= 1e-6 * max(1.0, abs(r[k])) for k, v in diff.items() if k != "n")
        ok &= good
        det.append(dict(group=m["group"], n_mine=m["n"], n_ref=r["n"], max_abs_diff=max(diff.values()), match=bool(good)))
    for g in ref:
        if g.startswith("отложено") and g not in {m["group"] for m in mine}:
            det.append(dict(group=g, error="нет у нас")); ok = False
    return ok, mine, det


def cmd_pack(a):
    t0 = time.time()
    dd = data_dir(a)
    tiles = dd / "pilot/tiles/v3"
    man = json.loads((tiles / "manifest.json").read_text())
    assert man.get("complete"), "tiles/v3 не complete"
    rows = list(csv.DictReader(open(tiles / "index.csv")))
    rows.sort(key=lambda r: r["id"])
    out_root = Path(a.out or os.environ.get("AIR_SYNTH_DATA") or os.path.expanduser("~/air_synth_data")) / "real"
    reliefs, errs = [], []
    for k, r in enumerate(rows):
        rel, e = relief_from(tiles / "cut" / f"{r['id']}.npz", dict(
            name=r["id"], lat_deg=float(r["lat"]), lon_deg=float(r["lon"]), system=r["system"], part=r["part"],
            stratum=r["stratum"], source="terrarium z%s" % r["zoom"], zoom=int(r["zoom"]),
            src_spacing_m=float(r["src_spacing_m"]), source_sha256=r["sha256"]))
        reliefs.append(rel); errs.append(e)
    p6 = out_root / "p6v3"
    shutil.rmtree(p6, ignore_errors=True)
    cio.write_reliefs(str(p6), reliefs, generator_version="real-p6v3", corpus_seed=0, command="pack_real.py pack",
                      git_commit=man.get("commit") or "")
    # места игры тем же конвейером (ref_* в work/cut_all)
    cd = dd / "pilot/tmp/terrain_v3/cut_all"
    greliefs, gerr = [], []
    for k, n in enumerate(GAME):
        f = json.loads((cd / f"ref_{n}.json").read_text())
        loc = json.loads((HERE.parents[3] / f"configs/locations/{n}.json").read_text())
        rel, e = relief_from(cd / f"ref_{n}.npz", dict(
            name=n, lat_deg=loc["center_lat"], lon_deg=loc["center_lon"], system="game", part="game", stratum="game",
            source="terrarium z%d" % f["zoom"], zoom=f["zoom"], src_spacing_m=f["src_spacing_m"], source_sha256=f["sha256"]))
        greliefs.append(rel); gerr.append(e)
    gp = out_root / "game"
    shutil.rmtree(gp, ignore_errors=True)
    cio.write_reliefs(str(gp), greliefs, generator_version="real-game", corpus_seed=0, command="pack_real.py pack",
                      git_commit=man.get("commit") or "")
    # чтение корпуса обратно: h400 = hc400 в пределах квантования (0,075 м), place заполнены
    c = cio.Corpus(str(p6))
    qerr = max(float(np.abs(c.h400(k, np.float64) - np.load(tiles / "cut" / f"{rows[k]['id']}.npz")["hc400"]).max())
               for k in range(len(rows)) if rows[k]['id'] not in {x['name'] for x in CLIPPED})
    assert len(c) == len(rows) and qerr <= cio.SCALE_M / 2 + 1e-9, (len(c), qerr)
    assert all(c.place(k)["name"] == rows[k]["id"] for k in range(len(rows)))
    c.close()
    # сводка
    ok, mine, det = compare_v3(rows)
    by_sys, by_part = {}, {}
    for r in rows:
        by_sys.setdefault(r["system"], {}).setdefault(r["part"], 0)
        by_sys[r["system"]][r["part"]] += 1
        by_part[r["part"]] = by_part.get(r["part"], 0) + 1
    size = lambda d: sum(f.stat().st_size for f in Path(d).rglob("*") if f.is_file())
    summ = dict(n_places=len(rows), n_game=len(GAME), by_part=by_part, by_system=by_sys, systems_table=mine,
                systems_match_v3=bool(ok), clipped_places=CLIPPED, match_v3_details=det,
                holdout_systems=sorted({r["system"] for r in rows if r["part"] == "holdout"}),
                g400_vs_hc400_max_abs_m=max(errs + gerr), readback_h400_vs_hc400_max_abs_m=qerr, corpus_path=str(p6), game_corpus_path=str(gp),
                corpus_bytes=size(p6), game_corpus_bytes=size(gp), raw_deleted=False,
                cut_manifest=dict(commit=man.get("commit"), code_dirty=man.get("code_dirty"),
                                  config_sha256=man.get("config_sha256"), seeds=man.get("seeds")),
                pack_seconds=round(time.time() - t0, 1))
    # доп. сверка справочных вырезок с пилотом (Онгудай, Алтай — Terrarium)
    ref = json.loads(REF_FEATS.read_text())
    rc = {}
    for n in GAME:
        f = json.loads((cd / f"ref_{n}.json").read_text())
        r = ref.get("ref_" + n + "_terrarium")
        if r:
            rc[n] = max(abs(f[k] - r[k]) for k in r)
    summ["ref_cuts_max_abs_diff_vs_pilot"] = rc
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out/real_summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1))
    shutil.copy(tiles / "index.csv", HERE / "out/index_p6v3.csv")
    print(json.dumps({k: summ[k] for k in ("n_places", "by_part", "systems_match_v3", "g400_vs_hc400_max_abs_m", "corpus_bytes")}, ensure_ascii=False))


def cmd_clean(a):
    dd = data_dir(a) / "pilot"
    freed = 0
    for sub in ("raw", "tiles", "tmp"):
        p = dd / sub
        if p.exists():
            freed += sum(f.stat().st_size for f in p.rglob("*") if f.is_file() and f.stat().st_nlink == 1 or f.is_file())
            shutil.rmtree(p)
    sp = HERE / "out/real_summary.json"
    s = json.loads(sp.read_text())
    s["raw_deleted"] = True
    s["raw_freed_bytes_est"] = freed
    sp.write_text(json.dumps(s, ensure_ascii=False, indent=1))
    print("удалено, ~", freed // 10**6, "МБ")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["pack", "clean"])
    ap.add_argument("--data"); ap.add_argument("--out")
    a = ap.parse_args()
    {"pack": cmd_pack, "clean": cmd_clean}[a.cmd](a)
