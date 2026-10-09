"""python -I aggregate.py : суммы по местам из results/godot_*.jsonl -> results/godot_summary.json"""
import json, collections, os
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
rows = []
for lv in (3, 19, 22):
    for l in open(f"{R}/godot_l{lv}.jsonl"):
        d = json.loads(l); d["lvl"] = lv; d.setdefault("Q", 32); rows.append(d)
S = collections.defaultdict(lambda: collections.defaultdict(float))
def acc(key, place, b, w=0, r=0, e=0):
    k = S[key]; k[place] += b; k["w_ms"] += w; k["r_ms"] += r; k["maxerr"] = max(k["maxerr"], e)
for d in rows:
    p, lv, Q = d["place"], d["lvl"], d["Q"]
    f = d["f32_zstd"]; 
    if Q == 32: acc(f"f32 zstd{lv} (как сейчас при lvl{lv})", p, f["bytes"], f["write_ms"], f["read_ms"])
    ds = d["delta_shuffle"]
    acc(f"int q1/{int(Q)} avg-pred+shuffle+zstd{lv}", p, ds["bytes"], ds["encode_gd_ms"] + ds["zstd_write_ms"], ds["zstd_read_ms"] + ds["decode_gd_ms"], ds["max_err"] + (0 if Q == 32 else 0))
    if lv == 3:
        w = d["webp_lossless_rgb24"]; acc(f"webp lossless 24bit q1/{int(Q)}", p, w["bytes"], w["write_ms"], w["read_ms"])
        if Q == 32:
            x = d["png_rgb24"]; acc("png rgb24 q1/32", p, x["bytes"], x["write_ms"], x["read_ms"])
            x = d["exr_rf"]; acc("exr float32 (zip)", p, x["bytes"], x["write_ms"], x["read_ms"])
            x = d["exr_rh"]; acc("exr half", p, x["bytes"], x["write_ms"], x["read_ms"], x["max_err"])
out = {}
print(f"{'вариант':45s} " + " ".join(f"{p:>8s}" for p in ["altai","ongudai","aushkul","askarovo"]) + "   MB/место  write_s  read_s(на место, 2 слоя)")
for k, v in sorted(S.items(), key=lambda kv: sum(kv[1][p] for p in ["altai","ongudai","aushkul","askarovo"])):
    ps = [v[p] / 1e6 for p in ["altai","ongudai","aushkul","askarovo"]]
    avg = sum(ps) / 4
    out[k] = {"MB": dict(zip(["altai","ongudai","aushkul","askarovo"], ps)), "avg_MB": avg, "write_s": v["w_ms"] / 4000, "read_s": v["r_ms"] / 4000, "maxerr_vs_input": v["maxerr"]}
    print(f"{k:45s} " + " ".join(f"{x:8.2f}" for x in ps) + f"   {avg:7.2f}  {v['w_ms']/4000:6.2f}  {v['r_ms']/4000:6.3f}  err {v['maxerr']:.3f}")
json.dump(out, open(f"{R}/godot_summary.json", "w"), indent=1, ensure_ascii=False)
