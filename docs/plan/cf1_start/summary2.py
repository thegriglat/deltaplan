import csv, glob, os, sys
d = sys.argv[1]
tags = sys.argv[2].split(",")
seed_filter = sys.argv[3] if len(sys.argv) > 3 else None
keys = sorted({os.path.basename(p)[:-4].split("_", 1)[1] for p in glob.glob(d + "/*.csv")},
              key=lambda k: (k.split("-")[0], float(k.split("-")[1]), k.split("-")[2], k.split("-")[3]))
print("case,tag,result,t_off,run_m,|bank|max_ground,pitch_cmd_mean,alpha_mean,theta_rng,after: |bank|max,agl_end,end")
for k in keys:
    if seed_filter and k.split("-")[2] != seed_filter:
        continue
    for t in tags:
        p = f"{d}/{t}_{k}.csv"
        if not os.path.exists(p):
            continue
        r = list(csv.DictReader(open(p)))
        if not r:
            continue
        g = [x for x in r if x["mode"] == "0"]
        a = [x for x in r if x["mode"] != "0"]
        off = [x for x in r if x["mode"] == "1"]
        res = "ground"
        if any(x["mode"] == "3" for x in r):
            res = "F:" + [x for x in r if x["mode"] == "3"][0]["fail"]
        elif off:
            res = "TOOK_OFF"
        t_off = float(off[0]["t"]) if off else float("nan")
        run_m = float(off[0]["dx"]) if off else float(r[-1]["dx"])
        bg = max([abs(float(x["bank_deg"])) for x in g] or [0])
        pc = [float(x["pitch_cmd"]) for x in g if float(x["speed"]) > 0.5] or [float(x["pitch_cmd"]) for x in g] or [float('nan')]
        al = [float(x["alpha_deg"]) for x in g if float(x["speed"]) > 0.5] or [float(x["alpha_deg"]) for x in g] or [float('nan')]
        th = [float(x["theta_deg"]) for x in g] or [float('nan')]
        ba = max([abs(float(x["bank_deg"])) for x in a] or [0])
        agl = float(r[-1]["agl"])
        end = r[-1]["land"] or ("mode" + r[-1]["mode"])
        print(f"{k},{t},{res},{t_off:.2f},{run_m:.1f},{bg:.1f},{sum(pc)/len(pc):.2f},{sum(al)/len(al):.1f},"
              f"{min(th):.0f}..{max(th):.0f},{ba:.0f},{agl:.1f},{end}")
