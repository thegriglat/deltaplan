import csv, glob, os, sys
d = os.path.expanduser("~/cf1out")
tags = sys.argv[1:] or sorted({os.path.basename(f).rsplit("_", 1)[0].replace("_run", "") for f in glob.glob(d + "/*_idle.csv")})
print("tag,scen,result,t_end,dx_end,max|bank|,min_feet,max|wm|,alpha_rng,theta_rng,|wind|max,w_rng")
for t in tags:
    for sc in ["idle", "walk", "run_neutral", "run_pull", "run_push"]:
        p = f"{d}/{t}_{sc}.csv"
        if not os.path.exists(p) or os.path.getsize(p) == 0:
            continue
        rows = list(csv.DictReader(open(p)))
        if not rows:
            continue
        last = rows[-1]
        mode = int(last["mode"])
        res = {0: "ground", 1: "TOOK_OFF", 3: "FAILED:" + last["fail"]}.get(mode, str(mode))
        f = lambda k: [float(r[k]) for r in rows if r[k] not in ("<null>", "", "null")]
        fl = f("feet_load"); wm = f("wind_moment")
        a = f("alpha_deg"); th = f("theta_deg")
        wind = [(float(r["wu"])**2 + float(r["wv"])**2) ** 0.5 for r in rows]
        ww = f("ww")
        print(f"{t},{sc},{res},{float(last['t']):.2f},{float(last['dx']):.2f},{max(abs(x) for x in f('bank_deg')):.2f},"
              f"{min(fl) if fl else float('nan'):.2f},{max(abs(x) for x in wm) if wm else float('nan'):.0f},"
              f"{min(a):.1f}..{max(a):.1f},{min(th):.1f}..{max(th):.1f},{max(wind):.2f},{min(ww):.2f}..{max(ww):.2f}")
