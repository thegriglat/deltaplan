"""CSD-4: вердикт по K0-K5 (критерии зафиксированы в docs/plan/cascade-2d.md до опытов) для варианта V3, старт 400 (основной)
и 200 (проверка). Читает out/metrics/C*.json, out/runs, out/levels.json, out/timing, F1 из $CASCADE2D_DATA.
Пишет out/verdict.json и out/tables.md."""
import glob, json, os, re, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(CD, "metrics")); sys.path.insert(0, os.path.join(CD, "contract"))
import metrics as M, cascade2d_io as io
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d"))
OUT = os.path.join(CD, "out")
CASES = ["C0", "C1", "C2", "C3", "C4"]
J = lambda p: json.load(open(p))
mets = {C: J(f"{OUT}/metrics/{C}.json") for C in CASES}
levels = J(f"{OUT}/levels.json")

def row(C, var, dx=25, par=None, seed=None):
    for r in mets[C]["rows"]:
        if r["variant"] == var and r["dx"] == dx and r["parent_dx"] == par and (seed is None or r["seed"] == seed):
            return r
    raise KeyError((C, var, dx, par, seed))

def run(C, name):
    return J(f"{OUT}/runs/{C}/{name}.run.json")

res = {"variant": "V3", "start": 400, "cases": {}}
for C in CASES:
    m = mets[C]; Er = m["E_ref"]; B4 = row(C, "B400", 400); V = row(C, "V3", 25, 400); V2s = row(C, "V3", 25, 200)
    P25 = run(C, "picard_none_d25"); rv = run(C, "cascade_V3_d25_from400"); rq = run(C, "cascade_V3_d25_from400.query")
    tim = [float(re.search(r"work=([\d.]+)s", l).group(1)) for l in open(f"{OUT}/timing/{C}_V3_from400.txt") if "work=" in l]
    T_desc = float(np.median(tim))
    d = {"E_ref": Er["E_u"], "E_w_ref": Er["E_w"], "B400": dict(E_u=B4["E_u"], E_w=B4["E_w"]),
         "V3_400": dict(E_u=V["E_u"], E_w=V["E_w"], E_u_lee=V["E_u_lee"], dS=V["dS"]["mean"], r_w=V["r_w"], L_rec=V["L_rec"],
                        L_rec_ref=V["L_rec_ref"], w_max=V["w_max"], F_up=V["F_up"], max_speed=V["max_speed"]),
         "V3_200": dict(E_u=V2s["E_u"], E_w=V2s["E_w"]),
         "ref": dict(L_rec=Er["L_rec_ref"], w_max=V["w_max_ref"], F_up=V["F_up_ref"], max_speed=Er["max_speed"], dS_B400=B4["dS"]["mean"])}
    # K1
    lv = rv["balance"]["levels"]
    par = run(C, "picard_none_d400")["balance"]["max_rel_div"]
    d["K1"] = dict(max_rel_div=rv["balance"]["max_rel_div"], per_level={str(l["dx"]): l["max_rel_div"] for l in lv},
                   parent_rel_div=par, P25_rel_div=P25["balance"]["max_rel_div"],
                   lost_flux=int(re.search(r"lost_flux_faces=(\d+)", rv["notes"]).group(1)),
                   wall_parent_open_sub=int(re.search(r"wall_parent_open_sub=(\d+)", rv["notes"]).group(1)))
    d["K1"]["pass"] = d["K1"]["max_rel_div"] <= 1e-5
    # K3
    Tp = P25["time"]["per_row_s"]
    d["K3"] = dict(T_desc=T_desc, T_desc_all=tim, T_P25_row=Tp, ratio=T_desc / Tp, time_pass=T_desc <= 0.1 * Tp,
                   rss_mb=rv["memory"]["peak_rss_mb"], rss_V1_mb=run(C, "cascade_V1_d25_from400")["memory"]["peak_rss_mb"],
                   arrays_mb=rv["memory"]["arrays_mb"], P25_rss_row_mb=P25["memory"]["peak_rss_mb"] / P25["ny"],
                   query_us=rq["query"]["us_per_point"], query_diff=rq["query"]["max_abs_diff_vs_full"],
                   query_warm_us=float(re.search(r"warm \(shared cache\) ([\d.]+)", rq["notes"]).group(1)))
    d["K3"]["query_pass"] = d["K3"]["query_us"] <= 20
    d["K3"]["mem_pass_process"] = d["K3"]["rss_mb"] <= 0.5 * d["K3"]["P25_rss_row_mb"]
    d["K3"]["mem_pass_V1_process"] = d["K3"]["rss_V1_mb"] <= 0.5 * d["K3"]["P25_rss_row_mb"]
    # K4
    cand = []
    for k in (400, 200, 100, 50):
        Tk = run(C, f"picard_none_d{k}")["time"]["per_row_s"]
        Bk = row(C, f"B{k}", k)
        cand.append(dict(k=k, T_row=Tk, E_u=Bk["E_u"], E_w=Bk["E_w"], cheaper_than_desc=Tk <= T_desc,
                         cheaper_than_P400_plus_desc=Tk <= T_desc + run(C, "picard_none_d400")["time"]["per_row_s"]))
    d["K4"] = dict(candidates=cand)
    d["K4"]["pass"] = all(V["E_u"] < c["E_u"] for c in cand if c["cheaper_than_P400_plus_desc"])
    # K5
    nanfree = True
    for f in glob.glob(f"{DATA}/fields/{C}/cascade_V3_d*_from*.json"):
        if ".run." in f: continue
        _, a = io.read_f1(f); nanfree &= all(np.isfinite(x).all() for x in a.values())
    bit = True; nb = 0
    for f in glob.glob(f"{DATA}/fields/{C}/cascade_V*_d*_from400.bin"):
        g = f.replace("/fields/", "/fields_t8/")
        if os.path.exists(g):
            nb += 1; bit &= open(f, "rb").read() == open(g, "rb").read()
    lev = levels[C]["V3_from400"]
    eu = [lev[k]["E_u"] for k in ("200", "100", "50", "25")]
    d["K5"] = dict(finite=bool(nanfree), max_speed_ratio=V["max_speed"] / P25_max if (P25_max := Er["max_speed"]) else None,
                   E_u_levels=dict(zip(("200", "100", "50", "25"), eu)), growth=[eu[i + 1] / eu[i] for i in range(3)],
                   bitwise_1v8_threads=bool(bit), bin_files_compared=nb, bitwise_query=d["K3"]["query_diff"] == 0.0,
                   E_u_start200=V2s["E_u"], E_u_start400=V["E_u"])
    d["K5"]["pass"] = (d["K5"]["finite"] and d["K5"]["max_speed_ratio"] <= 1.5 and max(d["K5"]["growth"]) <= 1.5
                       and d["K5"]["bitwise_1v8_threads"] and d["K5"]["bitwise_query"] and V2s["E_u"] <= V["E_u"])
    res["cases"][C] = d

# K0: C0, E_u и ложный |w| в ROI
rm, ra = io.read_f1(f"{DATA}/fields/C0/picard_none_d25.json")
cm, ca = io.read_f1(f"{DATA}/fields/C0/cascade_V3_d25_from400.json"); cm, ca = M.to_ref_grid(cm, ca, rm, ra)
xs, _ = M.centers(rm); zag = M.z_agl(rm, ra); U = mets["C0"]["U_ref"]
roi = (ra["cell"] > 0) & (zag > 0) & (zag <= 300) & (abs(xs[None, :]) <= 3 * 500)
_, wc = M.cell_vel(ca); _, wr = M.cell_vel(ra)
c0 = res["cases"]["C0"]
res["K0"] = dict(E_u=c0["V3_400"]["E_u"], E_u_B400=c0["B400"]["E_u"], false_w_max=float(np.abs(wc[roi]).max() / U),
                 false_w_ref_P25=float(np.abs(wr[roi]).max() / U))
res["K0"]["pass"] = res["K0"]["E_u"] <= res["K0"]["E_u_B400"] + 0.01 and res["K0"]["false_w_max"] <= 0.02
# K2
for C in ("C1", "C2", "C3", "C4"):
    d = res["cases"][C]; V = d["V3_400"]; B = d["B400"]
    info = B["E_u"] >= 2 * d["E_ref"]
    k2 = dict(informative=bool(info), E_u_ok=V["E_u"] <= 0.7 * B["E_u"], E_w_ok=V["E_w"] <= 0.7 * B["E_w"])
    if C in ("C1", "C4"):
        k2["dS_ok"] = V["dS"] <= 0.5 * d["ref"]["dS_B400"]; k2["r_w_ok"] = 0.7 <= V["r_w"] <= 1.3
    if C in ("C2", "C4"):
        k2["E_u_lee_ok"] = V["E_u_lee"] <= 0.7 * mets[C]["rows"][[r["variant"] for r in mets[C]["rows"]].index("B400")]["E_u_lee"]
        k2["L_rec_ok"] = (V["L_rec"] is not None and V["L_rec_ref"] is not None and abs(V["L_rec"] - V["L_rec_ref"]) <= 0.3 * V["L_rec_ref"])
    if C == "C3":
        k2["w_max_ok"] = abs(V["w_max"] - d["ref"]["w_max"]) <= 0.3 * d["ref"]["w_max"]
        k2["F_up_ok"] = abs(V["F_up"] - d["ref"]["F_up"]) <= 0.3 * d["ref"]["F_up"]
    k2["pass"] = bool(info and all(v for k, v in k2.items() if k.endswith("_ok")))
    d["K2"] = k2
tgt = ["C1", "C2", "C3"]
k2n = sum(res["cases"][C]["K2"]["pass"] for C in tgt)
res["summary"] = dict(
    K0=res["K0"]["pass"], K1=all(res["cases"][C]["K1"]["pass"] for C in CASES),
    K2_cases_passed=k2n, K2_target_cases=tgt,
    K3_time=all(res["cases"][C]["K3"]["time_pass"] for C in CASES),
    K3_query=all(res["cases"][C]["K3"]["query_pass"] for C in CASES),
    K3_mem_process=all(res["cases"][C]["K3"]["mem_pass_process"] for C in CASES),
    K4=all(res["cases"][C]["K4"]["pass"] for C in CASES), K5=all(res["cases"][C]["K5"]["pass"] for C in CASES))
s = res["summary"]
K3 = s["K3_time"] and s["K3_query"]
if (not s["K1"]) and False: pass
if (not s["K1"]) or k2n == 0 or not (s["K3_time"] or s["K3_query"]):
    verdict = "не имеет"
elif s["K0"] and s["K1"] and s["K5"] and k2n >= 2 and K3 and s["K4"]:
    verdict = "имеет смысл"
else:
    verdict = "при условиях"
res["verdict"] = verdict
json.dump(res, open(f"{OUT}/verdict.json", "w"), indent=1, ensure_ascii=False)
print(json.dumps(res["summary"], ensure_ascii=False), res["K0"], verdict)
for C in CASES:
    d = res["cases"][C]
    print(C, "K1", d["K1"]["max_rel_div"], d["K1"]["pass"], "| K2", d.get("K2"), "| K3", {k: d["K3"][k] for k in ("T_desc", "ratio", "rss_mb", "query_us")}, "| K4", d["K4"]["pass"], "| K5", {k: d["K5"][k] for k in ("finite", "max_speed_ratio", "growth", "bitwise_1v8_threads", "pass")})
