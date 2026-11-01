#!/usr/bin/env python3
"""Печать сводки прогонов control_run: control_show.py out/x.jsonl"""
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    s = r.get("settle", {})
    print(f"== {r['name']}  v={s.get('v_kmh',0):.1f} th={s.get('theta_deg',0):.1f} vy={s.get('vy',0):.2f} T={s.get('thrust_n',0):.0f}")
    for k, v in r.get("roll", {}).items():
        print(f"  roll {k}: rate={v['rate_dps']:.1f} peak={v['rate_peak_dps']:.1f} t={v['t_to']} end={v['bank_end_deg']:.0f} fy={v['fy_max_n']:.0f}")
    for k in ("t3030", "t4545"):
        if k in r:
            v = r[k]; print(f"  {k}: t={v.get('t_s')} hold_err={v.get('hold_err_deg')} b0={v.get('bank_start_deg')} min={v.get('min_bank_deg')}")
    for k in ("push", "pull"):
        if k in r:
            v = r[k]; print(f"  {k}: pitch_rate={v['pitch_rate_dps']:.1f} d2s={v['dtheta_2s']:.1f} fx={v['bar_fx_steady_n']:.0f} fpk={v['bar_f_peak_n']:.0f} v={v['v_end_kmh']:.1f} relx={v['rel_x_end_m']:.3f}")
