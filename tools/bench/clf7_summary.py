#!/usr/bin/env python3
"""CLF-7: сводка цены облаков main против поля облачности (справка, без порога).
    python3 tools/bench/clf7_summary.py <out_dir_с_main_и_field> > docs/perf/data/clf7_summary.json
Проход облаков — «Process Post Transparent Compositor Effects»; кадр GPU — gpu_ms строки base/base2; медиана по отметкам 2/30/60 с."""
import glob, json, os, statistics as st, sys
P = "Process Post Transparent Compositor Effects"
run = sys.argv[1]
out = {"passes": P, "agg": "медиана по отметкам 2/30/60 с (base и base2 вместе, 6 замеров)", "hour": 13.5,
       "weather": "--hour=12 --temp=30 --wind=3, мир +5400 с (13:30), --air-start (старт в воздухе)",
       "marks": "2:chase 30:chase 60:chase", "location": "ongudai"}
cov = []
for side in ("main", "field"):
    for preset in ("medium", "high"):
        cl, fr, nc = [], [], []
        for f in glob.glob(f"{run}/{side}/{preset}_ongudai_*.jsonl"):
            if "air_chunks" in f:
                continue
            for l in open(f):
                r = json.loads(l)
                if r.get("exp") == "_cloud_field" and side == "field" and r["info"].get("coverage_mean") is not None:
                    cov.append(r["info"]["coverage_mean"])
                if r.get("exp") in ("base", "base2"):
                    cl.append(r["passes"].get(P, 0)); fr.append(r["gpu_ms"])
                if r.get("exp") == "noclouds":
                    nc.append(r["gpu_ms"])
        k = f"{preset}_{side}"
        out[f"cloud_pass_ms_{k}"] = round(st.median(cl), 3) if cl else None
        out[f"frame_gpu_ms_{k}"] = round(st.median(fr), 3) if fr else None
        out[f"frame_gpu_ms_noclouds_{k}"] = round(st.median(nc), 3) if nc else None
        out[f"n_{k}"] = len(cl)
for p in ("medium", "high"):
    a, b = out[f"cloud_pass_ms_{p}_main"], out[f"cloud_pass_ms_{p}_field"]
    out[f"cloud_pass_ratio_{p}"] = round(b / a, 3) if a and b else None
out["coverage_mean"] = round(st.mean(cov), 3) if cov else None
print(json.dumps(out, ensure_ascii=False, indent=1))
