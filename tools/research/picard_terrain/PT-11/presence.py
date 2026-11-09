"""PT-11 (2): присутствие рельефа в поле до/после через dp-stand sample (--model formula).
  python3 presence.py plan   <случай>   # направление ветра (far-точки случая, «после», t=0) + гребни -> plan_<случай>.json
  python3 presence.py run    <случай>   # sample по точкам плана: «до» и «после», все моменты -> sample_<вар>_<случай>.csv
  python3 presence.py analyze <случай>  # таблицы -> presence_<случай>.json
Разрез «vertical» заменён сеткой точек по линии ветра на z_agl (тот же ops::sample_slice, что у slice)."""
import csv, io, json, os, subprocess, sys
from pathlib import Path
import numpy as np
from terrain import Terrain, crest_lines

H = Path.home()
VAR = {
    "base": (H / "worktrees/deltaplan/picard-terrain-PT-11-base", H / ".cache/dp-target/PT-11-base/release/dp-stand"),
    "after": (H / "worktrees/deltaplan/picard-terrain-PT-11", H / ".cache/dp-target/PT-11-after/release/dp-stand"),
}
OUTD = VAR["after"][0] / "tools/research/picard_terrain/out/PT-11/presence"
CASES = {"ongudai_strong": "ongudai", "ongudai_storm": "ongudai", "synth_strong": "synthetic"}
SET = os.environ.get("PT11_SET", "")  # "" - все гребни (массивы), "mod" - умеренные гряды (подъём 80-400 м, ориентир 1-3 км)
SUF = ("_" + SET) if SET else ""
ZAGL = [10, 30, 60, 100]
ROT_AGL = [10 + 20 * k for k in range(15)]  # 10..290
ROT_S = list(range(-500, 3001, 100))
SLOPE_S = list(range(-2000, 1, 100))


def stand(var, case, extra, timeout=3000):
    root, exe = VAR[var]
    cmd = [str(exe), "sample", "--case", f"tests/fixtures/wind/cases/{case}.json", "--model", "formula",
           "--timeout", "900", "--mode", "mean"] + extra
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise SystemExit(f"stand rc={r.returncode}: {r.stderr[-1000:]}")
    return r.stdout


def plan(case):
    OUTD.mkdir(parents=True, exist_ok=True)
    root = VAR["after"][0]
    cj = json.load(open(root / f"tests/fixtures/wind/cases/{case}.json"))
    place = CASES[case]
    base_plan = OUTD / f"plan_{case}.json"
    if SET and base_plan.exists():  # направление уже определено прогоном полного набора
        p0 = json.load(open(base_plan))
        u = np.array(p0["wind_to"]); sp = p0["far_mean_speed"]; nfar = p0["n_far"]
    else:
        out = stand("after", case, ["--time", "0"])
        rows = list(csv.DictReader(io.StringIO(out)))
        tags = cj["point_tags"]
        far = [i for i, t in enumerate(tags) if t == "far"]
        v = np.array([[float(rows[i]["vx"]), float(rows[i]["vz"])] for i in far])
        m = v.mean(0)
        sp = float(np.hypot(*m)); u = m / sp; nfar = len(far)
    ter = Terrain(root, place)
    focus = cj["focuses"][0]
    center, radius = (focus[0], focus[2]), 6000.0
    if SET == "mod":
        crests = crest_lines(ter, center, radius, (u[0], u[1]), up_len=3000.0, down_len=3000.0, min_gain=80.0, max_gain=400.0, min_drop=40.0, n_max=4, min_sep=1500.0)
    else:
        crests = crest_lines(ter, center, radius, (u[0], u[1]))
    p = dict(case=case, place=place, wind_to=[float(u[0]), float(u[1])], far_mean_speed=sp,
             wind_from_deg=float((np.degrees(np.arctan2(-u[0], u[1]))) % 360), n_far=nfar, crests=crests)
    # compass from: north=-z, east=+x: from = atan2(-ux, -(-uz))... (запись для справки)
    json.dump(p, open(OUTD / f"plan_{case}{SUF}.json", "w"), indent=1, ensure_ascii=False)
    print(json.dumps(p, ensure_ascii=False))


def build_points(case):
    root = VAR["after"][0]
    p = json.load(open(OUTD / f"plan_{case}{SUF}.json"))
    ter = Terrain(root, p["place"])
    ux, uz = p["wind_to"]
    pts, meta = [], []
    for ci, c in enumerate(p["crests"]):
        def add(kind, s, agl):
            x, z = c["x"] + ux * s, c["z"] + uz * s
            y = float(ter.height(x, z)) + agl
            pts.append((x, y, z)); meta.append((ci, kind, s, agl))
        # плоскость-ориентир: минимум рельефа на наветренном участке [-4000,-1500]
        ss = np.arange(-3000 if SET == "mod" else -4000, -999 if SET == "mod" else -1499, 100)
        hh = ter.height(c["x"] + ux * ss, c["z"] + uz * ss)
        s_ref = float(ss[int(np.argmin(hh))])
        c["s_ref"] = s_ref
        for a in ZAGL:
            add("crest", 0, a); add("plain", s_ref, a)
        for s in SLOPE_S:
            add("slope", s, 30)
        for s in ROT_S:
            for a in ROT_AGL:
                add("rot", s, a)
    return p, pts, meta


def run(case):
    p, pts, meta = build_points(case)
    json.dump(dict(meta=meta, crests=p["crests"]), open(OUTD / f"points_{case}{SUF}.json", "w"))
    arg = ";".join(f"{x:.2f},{y:.2f},{z:.2f}" for x, y, z in pts)
    assert len(arg) < 125000, len(arg)
    for var in ("base", "after"):
        out = stand(var, case, ["--points", arg])
        (OUTD / f"sample_{var}_{case}{SUF}.csv").write_text(out)
        print(var, len(out.splitlines()) - 1, "rows", flush=True)


def load(var, case):
    rows = list(csv.DictReader(open(OUTD / f"sample_{var}_{case}{SUF}.csv")))
    return rows


def analyze(case):
    p = json.load(open(OUTD / f"plan_{case}{SUF}.json"))
    pm = json.load(open(OUTD / f"points_{case}{SUF}.json"))
    meta = pm["meta"]
    ux, uz = p["wind_to"]
    res = dict(case=case, wind_to=p["wind_to"], wind_from_deg=p["wind_from_deg"], crests=[])
    nan = {}
    S = {}
    for var in ("base", "after"):
        rows = load(var, case)
        n = len(meta)
        times = sorted({float(r["t"]) for r in rows}, key=float)
        arr = {}
        bad = 0
        for t in times:
            rr = [r for r in rows if float(r["t"]) == t]
            a = np.array([[float(r[k]) for k in ("vx", "vy", "vz", "sigma")] for r in rr])
            bad += int((~np.isfinite(a)).sum())
            arr[t] = a
        nan[var] = bad
        S[var] = arr
    res["nan"] = nan
    res["moments"] = sorted(S["after"].keys())
    for ci, c in enumerate(pm["crests"]):
        cr = dict(x=c["x"], z=c["z"], h=c["h"], gain=c["gain"], drop=c["drop"], s_ref=c["s_ref"], moments={})
        for t in res["moments"]:
            mm = {}
            for var in ("base", "after"):
                a = S[var][t]
                idx = lambda kind: [k for k, m in enumerate(meta) if m[0] == ci and m[1] == kind]
                sp = lambda k: float(np.hypot(a[k, 0], a[k, 2]))
                # разгон
                spd = {}
                for agl in ZAGL:
                    kc = [k for k in idx("crest") if meta[k][3] == agl][0]
                    kp = [k for k in idx("plain") if meta[k][3] == agl][0]
                    spd[agl] = dict(crest=sp(kc), plain=sp(kp), S=sp(kc) / max(sp(kp), 1e-9))
                # w вдоль склона
                ks = idx("slope")
                w = np.array([a[k, 1] for k in ks])
                slope_mean_w, slope_max_w = float(w.mean()), float(w.max())
                # ротор
                kr = idx("rot")
                un, ag, ss = [], [], []
                for k in kr:
                    un.append(a[k, 0] * ux + a[k, 2] * uz); ag.append(meta[k][3]); ss.append(meta[k][2])
                un, ag, ss = np.array(un), np.array(ag), np.array(ss)
                lee = ss >= 0
                neg = lee & (un < 0)
                frac = float(neg.sum() / lee.sum())
                rot = dict(frac=frac, min_u=float(un[lee].min()), present=bool(frac > 0.01),
                           height_m=float(ag[neg].max()) if neg.any() else 0.0,
                           length_m=float(ss[neg].max() - ss[neg].min() + 100) if neg.any() else 0.0)
                mm[var] = dict(speed=spd, slope_w_mean=slope_mean_w, slope_w_max=slope_max_w, rotor=rot)
            cr["moments"][str(t)] = mm
        res["crests"].append(cr)
    json.dump(res, open(OUTD / f"presence_{case}{SUF}.json", "w"), indent=1)
    print(json.dumps(res["nan"]), "crests", len(res["crests"]))


if __name__ == "__main__":
    {"plan": plan, "run": run, "analyze": analyze}[sys.argv[1]](sys.argv[2])
