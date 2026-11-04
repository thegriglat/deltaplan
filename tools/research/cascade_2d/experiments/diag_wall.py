"""CSD-4, механизм: чем линейная интерполяция B400 лучше каскада у земли? Контрольный прогон (только диагностика,
CASCADE_WALL_NOLIMIT=1): наклон у нижней клетки = u - 0 (стенка - сосед на клетку ниже), без ограничителя.
V1/V3 от P400 -> $DATA/fields_diag/<C>; E_u, E_w против P25 рядом со штатным V1/V3 и B400. -> out/diag_wall.json"""
import json, os, subprocess, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.abspath(os.path.join(HERE, ".."))
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d"))
B = f"{CD}/cascade_rs/target/release/cascade"
res = {}
for C in ["C0", "C1", "C2", "C3", "C4"]:
    d = f"{DATA}/fields_diag/{C}"; os.makedirs(d, exist_ok=True)
    env = dict(os.environ, CASCADE_WALL_NOLIMIT="1")
    for V in ("V1", "V3"):
        subprocess.run([B, "descend", "--parent", f"{DATA}/fields/{C}/picard_none_d400.json", "--case", C, "--variant", V,
                        "--threads", "1", "--out-dir", d, "--runs-dir", tempfile.mkdtemp()], check=True, env=env, capture_output=True)
    with tempfile.TemporaryDirectory() as td:
        subprocess.run([f"{CD}/py", f"{CD}/metrics/metrics.py", "--case", C, "--fields", d, "--baselines", "400", "--out", td],
                       check=True, capture_output=True)
        m = json.load(open(f"{td}/{C}.json"))
    base = json.load(open(f"{CD}/out/metrics/{C}.json"))["rows"]
    pick = lambda rows, var, p: next(r for r in rows if r["variant"] == var and r["dx"] in (25, 400) and r["parent_dx"] == p and r["seed"] in (None, 1))
    res[C] = {"B400": dict(E_u=pick(base, "B400", None)["E_u"], E_w=pick(base, "B400", None)["E_w"])}
    for V in ("V1", "V3"):
        r = pick(m["rows"], V, 400); s = pick(base, V, 400)
        res[C][V + "_nolimit"] = dict(E_u=r["E_u"], E_w=r["E_w"], max_rel_div=r["max_rel_div"])
        res[C][V + "_штатный"] = dict(E_u=s["E_u"], E_w=s["E_w"], max_rel_div=s["max_rel_div"])
    print(C, {k: round(v["E_u"], 3) for k, v in res[C].items()})
json.dump(res, open(f"{CD}/out/diag_wall.json", "w"), indent=1, ensure_ascii=False)
