#!/usr/bin/env python3
"""Инварианты TT-К1 v1 по configs/tow_tug.json."""
import json, os, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
cfg = json.load(open(os.path.join(ROOT, "configs", "tow_tug.json")))
tp = json.load(open(os.path.join(ROOT, "tools", "blender", "trike_params.json")))["dims"]
errs = []
def err(m): errs.append(m)
def isnum(x): return isinstance(x, (int, float)) and not isinstance(x, bool)

if cfg.get("contract") != "TT-К1 v1": err("contract != TT-К1 v1")
if not cfg.get("_doc"): err("нет _doc")
if not isinstance(cfg.get("wing"), str): err("wing не строка")
SPEC = {
 "cart": ["empty_mass_kg", "pilot_mass_kg", "fuel_kg", "mass_kg", "cg_below_hang_m", "cda_m2", "arms_force_max_n", "tow_hook", "tow_hook_on"],
 "engine": ["name", "gear_ratio", "power_max_kw", "prop_d_m", "prop_blades", "prop_rpm_idle", "prop_rpm_max", "thrust_tilt_deg"],
 "thrust": ["v_ms", "full_n", "idle_n", "rpm_full"],
 "ground": ["keel_angle_deg", "rotate_deg", "rolling_crr", "wheel_base_agl_m"],
 "tow": ["tow_speed_kmh", "slack_speed_ms", "glider_hold_agl_m", "rotate_speed_kmh", "power_reduce_agl_m", "climb_limit_ms", "circuit_start_agl_m", "circuit_bank_deg"],
 "away": ["throttle", "turn_deg", "turn_s", "away_s"],
}
for blk, keys in SPEC.items():
    b = cfg.get(blk)
    if not isinstance(b, dict): err("нет блока " + blk); continue
    for k in keys:
        if k not in b: err("%s.%s нет" % (blk, k)); continue
        v = b[k]
        if blk == "thrust":
            if not (isinstance(v, list) and v and all(isnum(x) for x in v)): err("thrust.%s не числовой список" % k)
            continue
        if k == "tow_hook":
            if not (isinstance(v, list) and len(v) == 3 and all(isnum(x) for x in v)): err("tow_hook не [x,y,z]")
        elif k in ("name", "tow_hook_on"):
            if not isinstance(v, str): err("%s.%s не строка" % (blk, k))
        elif not isnum(v): err("%s.%s не число" % (blk, k))
        if not b.get(k + "_doc") and not b.get("_doc") and not (blk == "engine" and k.startswith("prop_rpm") and b.get("prop_rpm_doc")):
            err("%s.%s без _doc" % (blk, k))
if cfg.get("cart", {}).get("tow_hook_on") not in ("pilot", "hang"): err("tow_hook_on")
t = cfg.get("thrust", {})
if not t.get("_doc"): err("thrust без _doc")
n = len(t.get("v_ms", []))
for k in ("full_n", "idle_n", "rpm_full"):
    if len(t.get(k, [])) != n: err("thrust.%s длина != v_ms" % k)
v = t.get("v_ms", [])
if any(v[i] >= v[i+1] for i in range(len(v)-1)): err("v_ms не возрастает")
if v and (v[0] != 0 or v[-1] < 30): err("v_ms должна идти от 0 до >=30")
if any(not (f >= i >= 0) for f, i in zip(t.get("full_n", []), t.get("idle_n", []))): err("full_n>=idle_n>=0")
c = cfg.get("cart", {})
if all(isnum(c.get(k)) for k in ("empty_mass_kg", "pilot_mass_kg", "fuel_kg", "mass_kg")):
    if abs(c["mass_kg"] - (c["empty_mass_kg"] + c["pilot_mass_kg"] + c["fuel_kg"])) > 0.5: err("mass_kg != сумма")
e = cfg.get("engine", {})
for k in ("prop_rpm_idle", "prop_rpm_max"):
    if isnum(e.get(k)) and abs(e[k] - tp[k]["value"]) > 0.01 * tp[k]["value"]: err(k + " != trike_params ±1%")
if isnum(e.get("prop_d_m")) and abs(e["prop_d_m"] - tp["prop_d"]["value"]) > 0.01: err("prop_d")
ts = cfg.get("tow", {}).get("tow_speed_kmh")
if not (isnum(ts) and 55 <= ts <= 65): err("tow_speed_kmh вне [55;65]")
wp = os.path.join(ROOT, "configs", "wings", str(cfg.get("wing")) + ".json")
if os.path.exists(wp): pass
else: print("предупреждение: %s ещё нет (TT-2) — проверка wing пропущена" % wp)
if errs:
    print("\n".join("ОШИБКА: " + x for x in errs)); sys.exit(1)
print("TT-К1 ok")
