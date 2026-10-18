extends Node
## VM-1: что ограничивает Vmax на полном «на себя». Установившийся полный «на себя» (рампа 6 с, среднее 50–70 с)
## на модели игры (PendulumModel) с правками только в экземпляре модели — configs/ не меняется.
## godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=<json> --wings=a,b|all [--cases=base,hang,...]

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const G := 9.81
const T_RAMP := 6.0
const T_END := 70.0
const T_AVG := 50.0

var retrim_ok := true
var _args := {"out": "", "wings": "all", "cases": "base,hang,retrim,force,slope,cda,vgproxy,pullshift"}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	var names: Array = []
	if String(_args.wings) == "all":
		var da := DirAccess.open("res://configs/wings")
		for f in da.get_files():
			if f.ends_with(".json"):
				var w := f.get_basename()
				if Config.get_config("wings/" + w).has("pendulum"):
					names.append(w)
		names.sort()
	else:
		names = String(_args.wings).split(",")
	var cases := String(_args.cases).split(",")
	var res := {}
	for w: String in names:
		res[w] = _wing(w, cases)
		print("%s: base Vmax %.1f" % [w, res[w].base.V_kmh if res[w].has("base") else -1.0])
	var f := FileAccess.open(String(_args.out), FileAccess.WRITE)
	f.store_string(JSON.stringify({"wings": res}, " ", false))
	f.close()
	get_tree().quit(0)


## opt: hang_cm (сдвиг подвески вперёд, см), retrim (подобрать dcm0 под паспортный трим), slope_mul, cda_mul,
## wash_mul, dcm0_mul, pull_m, fmax.
func _model(w: String, opt: Dictionary) -> PendulumModel:
	var wing: Dictionary = Config.get_config("wings/" + w).duplicate(true)
	if opt.has("wash_mul"):
		wing.pendulum.washout_deg = float(wing.pendulum.washout_deg) * float(opt.wash_mul)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var app := {}
	if opt.has("hang_cm"):
		app["hang_shift_cm"] = float(opt.hang_cm)
	var m := PendulumModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}}, app)
	if opt.has("slope_mul"):
		m.strips.lift_slope *= float(opt.slope_mul)
	if opt.has("cda_mul"):
		var c := float(m.pendulum.pilot_cda_m2) * float(opt.cda_mul)
		m.pendulum.pilot_cda_m2 = c
		m._pilot_cda = c
		m.strips.cd_pilot_share = c / m.area
		m.strips.build_cd_table()
	if opt.has("dcm0_mul"):
		m.strips.dcm0 *= float(opt.dcm0_mul)
	if opt.has("retrim"):
		retrim_ok = _retrim(m, float(wing.trim_speed_kmh))
	if opt.has("pull_m"):
		m.arms.shift_x_pull = float(opt.pull_m)
	if opt.has("fmax"):
		m.arms.force_max = float(opt.fmax)
	S.reset(m)
	return m


## dcm0 такой, что руки без усилия дают паспортный трим (секущие).
func _retrim(m: PendulumModel, v_kmh: float) -> bool:
	var x0 := m.strips.dcm0
	var f0 := _trim_v(m) - v_kmh
	var x1 := x0 + 0.01
	m.strips.dcm0 = x1
	var f1 := _trim_v(m) - v_kmh
	for _i in 12:
		if absf(f1) < 0.005 or absf(f1 - f0) < 1.0e-9:
			break
		var x2 := x1 - f1 * (x1 - x0) / (f1 - f0)
		x0 = x1
		f0 = f1
		x1 = x2
		m.strips.dcm0 = x1
		f1 = _trim_v(m) - v_kmh
	return absf(f1) < 0.05 and absf(m.strips.dcm0) < 1.0


func _trim_v(m: PendulumModel) -> float:
	return float(m.solve_trim().V) * 3.6


## Kn = −dCm_H/dCL около подвески (доля средней хорды) на триме; CL — по подъёмной = вес·cos γ.
func _kn(m: PendulumModel) -> float:
	var st := m.solve_trim()
	var a: float = st.alpha
	var da := deg_to_rad(0.5)
	var out: Array = []
	for aa in [a - da, a + da]:
		var s := m.glide_balance(aa, float(st.V))
		var q := 0.5 * m.rho * float(s.V) * float(s.V)
		var cl := m.mass * G * cos(float(s.gamma)) / (q * m.area)
		out.append([float(s.M) / (q * m.area * m.strips.chord_mean), cl])
	return -(out[1][0] - out[0][0]) / (out[1][1] - out[0][1])


func _full_pull(m: PendulumModel) -> Dictionary:
	var inp := S.input(0.0)
	var acc := {}
	var k := 0
	var lo := INF
	var hi := -INF
	for i in int(T_END / DT):
		inp.pitch = -clampf(m.time_s / T_RAMP, 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if not S.finite(m):
			break
		if m.time_s > T_AVG:
			var v := S.airspeed(m) * 3.6
			var s := {"V_kmh": v, "theta_deg": rad_to_deg(m.theta), "alpha_deg": rad_to_deg(m.alpha),
				"bar_x": m.bar_force_wing.x, "bar_y": m.bar_force_wing.y, "n": m.strap_tension / (m.pilot_mass * G),
				"phi_deg": rad_to_deg(m.arms.phi), "tgt_x": m.arms.target_b.x, "rel_x": m.arms.neutral_rel.x,
				"sink": m._vel.z, "stall": m.stall_amount()}
			for key: String in s:
				acc[key] = float(acc.get(key, 0.0)) + float(s[key])
			k += 1
			lo = minf(lo, v)
			hi = maxf(hi, v)
	var r := {"finite": S.finite(m), "V_p2p": hi - lo, "t_end": m.time_s}
	for key: String in acc:
		r[key] = float(acc[key]) / maxi(k, 1)
	return r


func _run(w: String, opt: Dictionary) -> Dictionary:
	retrim_ok = true
	var m := _model(w, opt)
	if not retrim_ok:
		return {"failed": true}
	var tr := m.solve_trim()
	var r := _full_pull(m)
	r["trim_V_kmh"] = float(tr.V) * 3.6
	r["dcm0"] = m.strips.dcm0
	r["kn"] = _kn(m)
	r["hang_len"] = m.arms.neutral_rel.length()
	return r


func _wing(w: String, cases: PackedStringArray) -> Dictionary:
	var out := {}
	var wing: Dictionary = Config.get_config("wings/" + w)
	out["cfg"] = {"trim": wing.trim_speed_kmh, "full_pull": wing.full_pull_speed_kmh,
		"cg_minus_hang_m": float(wing.pendulum.cg_x_from_nose_m) - float(wing.pendulum.hang_from_nose_m),
		"group": wing.group, "wind_class": wing.wind_class}
	if "base" in cases:
		out["base"] = _run(w, {})
	if "hang" in cases:
		for c in [3.0, -3.0]:
			out["hang%+d" % int(c)] = _run(w, {"hang_cm": c})
	if "retrim" in cases:
		var cgm := float(out.cfg.cg_minus_hang_m)
		for c in [4.0, 2.0, 0.0, -2.0, -4.0, -6.0, -8.0, -10.0, -12.0, -16.0]:
			out["retrim%+d" % int(c)] = _run(w, {"hang_cm": c, "retrim": true})
		# «ЦМ + 2,5 см»: подвеска на 2,5 см впереди ЦМ модели масс
		var c25 := -(cgm - 0.025) * 100.0
		var r := _run(w, {"hang_cm": c25, "retrim": true})
		r["hang_cm"] = c25
		out["cg25"] = r
	if "force" in cases:
		out["fmax"] = _run(w, {"fmax": 1.0e6})
	if "slope" in cases:
		for s in [0.9, 1.1]:
			out["slope%.1f" % s] = _run(w, {"slope_mul": s, "retrim": true})
	if "cda" in cases:
		for s in [0.5, 2.0]:
			out["cda%.1f" % s] = _run(w, {"cda_mul": s})
	if "vgproxy" in cases:
		out["wash0.5"] = _run(w, {"wash_mul": 0.5})
		out["dcm0x0.5"] = _run(w, {"dcm0_mul": 0.5})
		out["wash0.5_dcm0x0.5"] = _run(w, {"wash_mul": 0.5, "dcm0_mul": 0.5})
	if "pullcons" in cases:
		# согласованный момент: плечо реакции на штанге bar_depth вместо длины подвески L (концы линий сил сходятся в ЦМ пилота)
		var bar_d := -float(wing.pendulum.bar_z_m)
		var L := float(Config.get_config("pendulum").get("chain", {}).get("links", 3)) * 0.0 + 1.2
		var pc := 0.45 * L / bar_d
		var r := _run(w, {"pull_m": pc})
		r["pull_m"] = pc
		r["bar_depth_m"] = bar_d
		out["pullcons"] = r
	if "pullshift" in cases:
		for p in [0.6, 0.8, 1.0, 1.2]:
			out["pull%.2f" % p] = _run(w, {"pull_m": p, "fmax": 1.0e6})
	return out
