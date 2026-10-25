"""Prints the compact tables of summary.json (PR-8): one line per point, then floor and ref-vs-deep."""
import json
import sys

d = json.load(open(sys.argv[1]))
for s in d["series"]:
    print(s["case"], s["start"], "ref iters", s["ref"]["iters"], "t", round(s["ref"]["t_s"], 1), s["n_cells"])
    for p in s["points"]:
        v = p["dev"]
        L, S, T, D = v["launch"], v["slopes"], v["thermals"], v["domain"]
        r = p["residuals"]
        print(f"  {p['by'][:3]} N={p['N']:3d} t={p['t_s']:5.2f} mom={r['mom_rms']:.1e} div={r['div_rms']:.1e} th={r['th_rms']:.1e}"
              f" | L dw {L['dw_max']:.3f}/{L['dw_rms']:.4f} du {L['du_max']:.3f}/{L['du_rms']:.4f}"
              f" | S dw {S['dw_max']:.3f} dwt {S['dwt_max']:.3f} du {S['du_max']:.3f} | T dw {T['dw_max']:.3f} du {T['du_max']:.3f}"
              f" | D dw {D['dw_max']:.3f} du {D['du_max']:.3f}"
              f" | fl {p['flows']['thermal_w_peak_err']:+.3f} {p['flows']['thermal_w_mean_err']:+.3f} {p['flows']['slope_w_mean_err']:+.3f}")
print("floor f32 vs f64 / ref vs deep")
for c, f in d["floor"].items():
    a = f["dev"]["launch"]
    line = f"  {c}: f32-f64 launch dw {a['dw_max']:.1e} du {a['du_max']:.1e} dom du {f['dev']['domain']['du_max']:.1e} th {f['th_abs_max_domain']:.1e}"
    if f.get("ref_vs_deep"):
        b, g = f["ref_vs_deep"]["launch"], f["ref_vs_deep"]
        line += (f" | ref-deep launch dw {b['dw_max']:.3f}/{b['dw_rms']:.4f} du {b['du_max']:.3f} slopes dwt {g['slopes']['dwt_max']:.3f}"
                 f" thermals dw {g['thermals']['dw_max']:.3f} dom dw {g['domain']['dw_max']:.3f} du {g['domain']['du_max']:.3f}")
    print(line)
