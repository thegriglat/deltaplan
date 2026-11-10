"""PT-11b: разгон на гребне и ротор в окнах 100/50 м у фокуса на гребне, до (f44c66b4a) и после (HEAD), и тот же гребень без фокуса (400 м).
  python3 pt11b.py run  [имя ...]   # sample (+timing t=0) по гребням: фокус на гребне / без фокуса, до/после -> out/PT-11b/raw/
  python3 pt11b.py analyze          # таблицы -> out/PT-11b/table.csv, summary.json
Точки и метрики те же, что в PT-11 (presence.py): S(z_agl 10/30/60/100), w на склоне, ротор за гребнем.
"""
import csv, io, json, os, subprocess, sys
from pathlib import Path
import numpy as np
from terrain import Terrain

H = Path.home()
ME = Path(__file__).resolve().parent
OUT = ME.parent / "out" / "PT-11b"
RAW = OUT / "raw"
PLANS = ME.parent / "out" / "PT-11" / "presence"
ROOT = H / "worktrees/deltaplan/picard-terrain-PT-11b"       # конфиги, фикстуры (одинаковы с f44c66b4a: git diff пуст)
VAR = {"before": H / ".cache/dp-target/PT-11-base/release/dp-stand", "after": H / ".cache/dp-target/PT-11-after/release/dp-stand"}
CASE = {"ongudai_strong": "ongudai", "synth_strong": "synthetic"}
ZAGL = [10, 30, 60, 100]
ROT_AGL = [10 + 20 * k for k in range(15)]
ROT_S = list(range(-500, 3001, 100))
SLOPE_S = list(range(-2000, 1, 100))
FOCUS_DAGL = 30.0  # фокус на гребне: высота над землёй, м (как точка полёта пилота)
NWIN = 64


def crest_list():
    """(имя, случай, набор, индекс, гребень) - все гребни PT-11 (strong: массивы и умеренные гряды)."""
    L = []
    for case in CASE:
        for suf, kind in (("", "massif"), ("_mod", "mod")):
            p = json.load(open(PLANS / f"plan_{case}{suf}.json"))
            for i, c in enumerate(p["crests"]):
                L.append(dict(name=f"{case}_{kind}{i}", case=case, place=CASE[case], kind=kind, idx=i, crest=c, wind_to=p["wind_to"]))
    return L


def points_for(item, ter):
    ux, uz = item["wind_to"]; c = item["crest"]
    pts, meta = [], []

    def add(kind, s, agl):
        x, z = c["x"] + ux * s, c["z"] + uz * s
        pts.append((x, float(ter.height(x, z)) + agl, z)); meta.append((kind, s, agl))
    lo, hi = (-3000, -999) if item["kind"] == "mod" else (-4000, -1499)
    ss = np.arange(lo, hi, 100)
    hh = ter.height(c["x"] + ux * ss, c["z"] + uz * ss)
    s_ref = float(ss[int(np.argmin(hh))])
    for a in ZAGL:
        add("crest", 0, a); add("plain", s_ref, a)
    for s in SLOPE_S:
        add("slope", s, 30)
    for s in ROT_S:
        for a in ROT_AGL:
            add("rot", s, a)
    return pts, meta, s_ref


def stand(var, sub, case_file, extra, place, timeout=3000):
    cmd = [str(VAR[var]), sub, "--configs", "configs", "--place", f"tests/fixtures/wind/places/{place}.json", "--case", str(case_file), "--model", "formula", "--timeout", "900"] + extra
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise SystemExit(f"stand {var} {sub} rc={r.returncode}: {r.stderr[-800:]}")
    return r.stdout


SEL = ["ongudai_strong_massif0", "ongudai_strong_massif1", "ongudai_strong_massif2", "synth_strong_massif0", "ongudai_strong_mod0", "synth_strong_mod2"]
TIME = ["--time", "0"]  # один момент (t=0): время счёта под замком cpu (квота 1 ядро) ~2 мин на загрузку поля


def write_case(item, mode):
    ter = Terrain(ROOT, item["place"])
    base = json.load(open(ROOT / f"tests/fixtures/wind/cases/{item['case']}.json"))
    c = item["crest"]
    cj = dict(base)
    cj["focuses"] = [[c["x"], float(ter.height(c["x"], c["z"])) + FOCUS_DAGL, c["z"], 1.0]] if mode == "focus" else []
    cdir = ME / "cases"; cdir.mkdir(exist_ok=True)
    cf = cdir / f"{item['name']}_{mode}.json"
    json.dump(cj, open(cf, "w"))
    return cf


def run_focus(item):
    name = item["name"]
    ter = Terrain(ROOT, item["place"])
    pts, meta, s_ref = points_for(item, ter)
    arg = ";".join(f"{x:.2f},{y:.2f},{z:.2f}" for x, y, z in pts)
    assert len(arg) < 125000
    RAW.mkdir(parents=True, exist_ok=True)
    json.dump(dict(meta=meta, s_ref=s_ref, crest=item["crest"], wind_to=item["wind_to"]), open(RAW / f"{name}_points.json", "w"))
    cf = write_case(item, "focus")
    for var in ("before", "after"):
        f = RAW / f"{name}_focus_{var}.csv"
        if not (f.exists() and f.stat().st_size > 0):
            f.write_text(stand(var, "sample", cf, ["--mode", "mean", "--points", arg] + TIME, item["place"]))
        print(name, "focus sample", var, flush=True)
    g = RAW / f"{name}_focus_after_timing.jsonl"
    if not (g.exists() and g.stat().st_size > 0):
        g.write_text(stand("after", "timing", cf, ["--threads", "8"] + TIME, item["place"]))
    print(name, "timing done", flush=True)


def run_nofocus(case):
    """без фокуса (400 м): одно поле на случай, точки всех выбранных гребней подряд."""
    items = [it for it in crest_list() if it["case"] == case and it["name"] in SEL]
    pts_all, offs = [], {}
    for it in items:
        ter = Terrain(ROOT, it["place"])
        pts, meta, _ = points_for(it, ter)
        offs[it["name"]] = [len(pts_all), len(pts)]
        pts_all += pts
    arg = ";".join(f"{x:.2f},{y:.2f},{z:.2f}" for x, y, z in pts_all)
    assert len(arg) < 125000, len(arg)
    json.dump(offs, open(RAW / f"{case}_nofocus_offsets.json", "w"))
    cf = write_case(items[0], "nofocus"); 
    for var in ("before", "after"):
        f = RAW / f"{case}_nofocus_{var}.csv"
        if not (f.exists() and f.stat().st_size > 0):
            f.write_text(stand(var, "sample", cf, ["--mode", "mean", "--points", arg] + TIME, items[0]["place"]))
        print(case, "nofocus", var, flush=True)


def run(names):
    RAW.mkdir(parents=True, exist_ok=True)
    for it in crest_list():
        if it["name"] in SEL and (not names or it["name"] in names):
            run_focus(it)
    if not names:
        for case in CASE:
            run_nofocus(case)


def window_info(name, var="after"):
    """окна из timing t=0 (фокус на гребне, «после»): [(dx, x0, y0)] и win_s."""
    d = json.loads(open(RAW / f"{name}_focus_after_timing.jsonl").read().splitlines()[-1])
    ws = d["windows"] or [w for p in d["passes"] for w in p["windows"]]
    return [dict(dx=w["dx"], x0=w["x0"], y0=w["y0"]) for w in ws], sum(p["win_s"] or 0 for p in d["passes"]), d["windows_error"]


def inside(wins, dx_sel, x, z, margin_cells=5):
    for w in wins:
        if abs(w["dx"] - dx_sel) < 1e-6:
            side = NWIN * w["dx"]; m = margin_cells * w["dx"]
            y = -z  # окна в (x, y=-z) (formula.rs plan_windows)
            return bool(w["x0"] + m <= x <= w["x0"] + side - m and w["y0"] + m <= y <= w["y0"] + side - m)
    return False


def load(f, sl=None):
    rows = list(csv.DictReader(open(f)))
    ts = sorted({float(r["t"]) for r in rows})
    A = {}
    for t in ts:
        a = np.array([[float(r[k]) for k in ("x", "y", "z", "vx", "vy", "vz")] for r in rows if float(r["t"]) == t])
        A[t] = a if sl is None else a[sl[0]:sl[0] + sl[1]]
    return A


def metrics(a, meta, wt, in50, in100):
    """a: [n,6] (x,y,z,vx,vy,vz). Возвращает S по z_agl, w склона, ротор (все точки и внутри окна 50 м)."""
    ux, uz = wt
    sp = lambda k: float(np.hypot(a[k, 3], a[k, 5]))
    res = {}
    S = {}
    for z in ZAGL:
        kc = [k for k, m in enumerate(meta) if m[0] == "crest" and m[2] == z][0]
        kp = [k for k, m in enumerate(meta) if m[0] == "plain" and m[2] == z][0]
        S[z] = sp(kc) / max(sp(kp), 1e-9)
    res["S"] = S
    ks = [k for k, m in enumerate(meta) if m[0] == "slope"]
    w = np.array([a[k, 4] for k in ks])
    res["slope_w_mean"] = float(w.mean())
    ks50 = [k for k in ks if in50[k]]
    res["slope_w_mean_win50"] = float(np.mean([a[k, 4] for k in ks50])) if ks50 else float("nan")
    kr = [k for k, m in enumerate(meta) if m[0] == "rot"]
    for tag, sel in (("all", kr), ("win50", [k for k in kr if in50[k]]), ("win100", [k for k in kr if in100[k]])):
        sel = [k for k in sel if meta[k][1] >= 0]
        if not sel:
            res["rotor_" + tag] = dict(n=0, frac=0.0, min_u=float("nan"), present=False, height_m=0.0, length_m=0.0)
            continue
        un = np.array([a[k, 3] * ux + a[k, 5] * uz for k in sel]); ag = np.array([meta[k][2] for k in sel]); ss = np.array([meta[k][1] for k in sel])
        neg = un < 0
        res["rotor_" + tag] = dict(n=len(sel), frac=float(neg.mean()), min_u=float(un.min()), present=bool(neg.mean() > 0.01),
                                   height_m=float(ag[neg].max()) if neg.any() else 0.0,
                                   length_m=float(ss[neg].max() - ss[neg].min() + 100) if neg.any() else 0.0)
    return res


def analyze():
    out_rows, nan, summ_items = [], 0, []
    for it in crest_list():
        name = it["name"]
        if name not in SEL or not (RAW / f"{name}_focus_after_timing.jsonl").exists():
            continue
        pm = json.load(open(RAW / f"{name}_points.json")); meta = pm["meta"]
        wins = {"after": window_info(name)}
        offs = json.load(open(RAW / f"{it['case']}_nofocus_offsets.json"))[name]
        data = {}
        for mode in ("focus", "nofocus"):
            for var in ("before", "after"):
                data[(mode, var)] = load(RAW / (f"{name}_focus_{var}.csv" if mode == "focus" else f"{it['case']}_nofocus_{var}.csv"), None if mode == "focus" else offs)
                for A in data[(mode, var)].values():
                    nan += int((~np.isfinite(A)).sum())
        # те же точки в обоих полях (проверка)
        geo_same = bool(np.allclose(data[("focus", "after")][0.0][:, :3], data[("nofocus", "after")][0.0][:, :3], atol=0.01))
        xs = np.array([[x, z] for x, z in zip(next(iter(data[("focus", "after")].values()))[:, 0], next(iter(data[("focus", "after")].values()))[:, 2])])
        in50 = [inside(wins["after"][0], 50.0, x, z) for x, z in xs]
        in100 = [inside(wins["after"][0], 100.0, x, z) for x, z in xs]
        crest_in50 = [in50[k] for k, m in enumerate(meta) if m[0] == "crest"]
        plain_in50 = [in50[k] for k, m in enumerate(meta) if m[0] == "plain"]
        for t in sorted(data[("focus", "after")].keys()):
            for mode in ("focus", "nofocus"):
                m = {var: metrics(data[(mode, var)][t], meta, it["wind_to"], in50, in100) for var in ("before", "after")}
                for z in ZAGL:
                    row = dict(name=name, case=it["case"], kind=it["kind"], idx=it["idx"], gain=it["crest"]["gain"], t=t, mode=mode, z_agl=z,
                               S_before=m["before"]["S"][z], S_after=m["after"]["S"][z])
                    for tag in ("all", "win50", "win100"):
                        for v in ("before", "after"):
                            r = m[v]["rotor_" + tag]
                            row.update({f"rot_{tag}_frac_{v}": r["frac"], f"rot_{tag}_minu_{v}": r["min_u"], f"rot_{tag}_h_{v}": r["height_m"], f"rot_{tag}_len_{v}": r["length_m"], f"rot_{tag}_n": r["n"]})
                    for v in ("before", "after"):
                        row[f"slope_w_{v}"] = m[v]["slope_w_mean"]; row[f"slope_w50_{v}"] = m[v]["slope_w_mean_win50"]
                    out_rows.append(row)
        summ_items.append(dict(name=name, windows_after=wins["after"][0], win_s=wins["after"][1],
                               windows_error=wins["after"][2], geo_same=geo_same, crest_in50=bool(crest_in50[0]) if crest_in50 else None,
                               n_in50=int(sum(in50)), n_in100=int(sum(in100)), n_pts=len(in50), crest_all_in50=bool(all(crest_in50)), plain_in50=bool(any(plain_in50))))
    OUT.mkdir(parents=True, exist_ok=True)
    keys = list(out_rows[0].keys())
    with open(OUT / "table.csv", "w", newline="") as f:
        w = csv.DictWriter(f, keys); w.writeheader(); w.writerows(out_rows)
    json.dump(summ_items, open(OUT / "windows_check.json", "w"), indent=1)
    summarize(out_rows, summ_items, nan)


def ratios(rows, mode):
    r = [((x["S_after"] - 1) / (x["S_before"] - 1), x["z_agl"]) for x in rows if x["mode"] == mode and x["S_before"] > 1.05]
    return r


def summarize(rows, items, nan):
    s = dict(nan_count=nan, n_crests=len(items))
    for mode, key in (("focus", "win"), ("nofocus", "400")):
        r = ratios(rows, mode)
        v = np.array([a for a, _ in r])
        s[f"crest_speedup_{key}_after_over_before_median"] = float(np.median(v))
        s[f"crest_speedup_{key}_after_over_before_min"] = float(v.min())
        s[f"crest_speedup_{key}_n"] = len(r)
        s[f"crest_speedup_{key}_median_by_z_agl"] = {str(z): float(np.median([a for a, zz in r if zz == z])) for z in ZAGL}
        s[f"S_{key}_median_before_after_by_z_agl"] = {str(z): [float(np.median([x["S_before"] for x in rows if x["mode"] == mode and x["z_agl"] == z])),
                                                              float(np.median([x["S_after"] for x in rows if x["mode"] == mode and x["z_agl"] == z]))] for z in ZAGL}
    # ротор: случай = (гребень, момент); присутствует, если доля u_par<0 за гребнем > 0.01
    for mode, key in (("focus", "win"), ("nofocus", "400")):
        for tag in ("win50", "all"):
            if mode == "nofocus" and tag == "win50":
                tg = "win50"  # те же точки (внутри 50 м-квадрата вокруг гребня) в поле 400 м
            cases = {}
            for x in rows:
                if x["mode"] == mode and x["z_agl"] == 10:
                    cases[(x["name"], x["t"])] = (x[f"rot_{tag}_frac_before"], x[f"rot_{tag}_frac_after"], x[f"rot_{tag}_minu_before"], x[f"rot_{tag}_minu_after"])
            b = sum(1 for v in cases.values() if v[0] > 0.01); a = sum(1 for v in cases.values() if v[1] > 0.01)
            lost = sum(1 for v in cases.values() if v[0] > 0.01 and v[1] <= 0.01); new = sum(1 for v in cases.values() if v[0] <= 0.01 and v[1] > 0.01)
            s[f"rotor_{key}_{tag}"] = dict(cases=len(cases), before=b, after=a, lost=lost, new=new,
                                          frac_before_mean=float(np.mean([v[0] for v in cases.values()])), frac_after_mean=float(np.mean([v[1] for v in cases.values()])),
                                          minu_before_median=float(np.median([v[2] for v in cases.values()])), minu_after_median=float(np.median([v[3] for v in cases.values()])))
    w = s["rotor_win_win50"]
    s["rotor_win_before_count"] = w["before"]; s["rotor_win_after_count"] = w["after"]; s["rotor_win_lost"] = w["lost"]
    json.dump(s, open(OUT / "summary_part.json", "w"), indent=1)
    print(json.dumps(s, indent=1))


if __name__ == "__main__":
    if sys.argv[1] == "run":
        run(set(sys.argv[2:]))
    else:
        analyze()
