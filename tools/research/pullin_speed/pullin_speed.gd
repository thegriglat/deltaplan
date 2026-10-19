extends Node
## VM-1: что ограничивает Vmax на полном «на себя». Установившийся полный «на себя» (рампа 6 с, среднее 50–70 с)
## на модели игры (PendulumModel) с правками только в экземпляре модели — configs/ не меняется.
## godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=<json> --wings=a,b|all [--cases=base,hang,...]
## VM-4 (VM-К5 v2, порт в игру): --cases=vm4 — normal, full (добор pull_full), release_smooth (Shift отпущен, мышь/ручка
## −1 → 0 за 0,5 с), release_smooth_normal (то же с обычного полного «на себя», справочно), release_1p8 (с min(1,8·Vтрим, V full) ввод 0 скачком); конфиги игры как есть.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const G := 9.81
const T_RAMP := 6.0
const T_END := 70.0
const T_AVG := 50.0

var retrim_ok := true
var _args := {"out": "", "wings": "all", "cases": "base,hang,retrim,force,slope,cda,vgproxy,pullshift",
	"relaxed": "", "turb": ""}


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
	if "vm4" in cases:
		out.merge(_vm4(w))
	if "turb" in cases:
		out["turb"] = _turb(w)
	if "pullshift" in cases:
		for p in [0.6, 0.8, 1.0, 1.2]:
			out["pull%.2f" % p] = _run(w, {"pull_m": p, "fmax": 1.0e6})
	return out


# ---------------------------------------------------------------- VM-4 (VM-К5): порт в игру
## VM-12 (VM-К7 v2): --relaxed=0/1 переопределяет arms.release_event в модели (0 — до правки, 1 — после; пусто — конфиг);
## --cases=turb --turb=<json полей> — болтанка σ 1 м/с, поля из turb_fields.py (как VM-6 sc=turb), 40 с, BankHold.

const T_REL := 30.0


## Модель игры как есть (конфиги после порта), эталонная масса, ρ = 1,225, штиль; сброс на трим.
func _game_model(w: String) -> PendulumModel:
	var m := S.make(w)
	if String(_args.relaxed) != "":
		m.arms.release_event = String(_args.relaxed) == "1"
	S.reset(m)
	return m


## Полный «на себя» (рампа 6 с, 70 с), pull_full — добор; среднее, СКО V за 50–70 с, макс. |bar_force| за весь разгон.
func _vm4_pull(m: PendulumModel, full: bool) -> Dictionary:
	var inp := S.input(0.0)
	inp.pull_full = full
	var vs := PackedFloat64Array()
	var fmax := 0.0
	var po := 0.0
	for i in int(T_END / DT):
		inp.pitch = -clampf(m.time_s / T_RAMP, 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if not S.finite(m):
			break
		fmax = maxf(fmax, m.telemetry.bar_force.length())
		if m.time_s > T_AVG:
			vs.append(S.airspeed(m) * 3.6)
			po += m.telemetry.pull_over
	var mean := 0.0
	for v in vs:
		mean += v
	mean /= maxi(vs.size(), 1)
	var var_ := 0.0
	for v in vs:
		var_ += (v - mean) * (v - mean)
	return {"finite": S.finite(m), "V_kmh": mean, "V_std_kmh": sqrt(var_ / maxi(vs.size(), 1)), "bar_force_max_n": fmax,
		"pull_over_mean": po / maxi(vs.size(), 1), "alpha_deg": rad_to_deg(m.alpha), "theta_deg": rad_to_deg(m.theta),
		"tgt_fwd_m": m.arms.target_b.x - m.arms.neutral_rel.x}


## 30 с после отпускания: каждый шаг ctrl.call(m) → ControlInput. Переворот — как VM-2/VM-3: тангаж киля < −60°
## или |α| > 90° в любой момент, или средняя V за 25–30 с вне ±10 % трима. Перегрузка — |сила полос| / (M·g), как VM-3.
func _vm4_release(m: PendulumModel, ctrl: Callable, v_trim: float) -> Dictionary:
	var th_min := INF
	var a_max := 0.0
	var g_max := 0.0
	var load_max := 0.0
	var v_tail := 0.0
	var k := 0
	var t0 := m.time_s
	var v0 := S.airspeed(m)
	var blow := false
	for i in int(round(T_REL / DT)):
		m.step(DT, ctrl.call(m), Callable(), Callable())
		if not S.finite(m):
			blow = true
			break
		var t := m.time_s - t0
		th_min = minf(th_min, rad_to_deg(m.theta))
		a_max = maxf(a_max, absf(rad_to_deg(m.alpha)))
		g_max = maxf(g_max, m.strips.force.length() / (m.mass * G))
		load_max = maxf(load_max, m.load.load_factor)
		if t >= 25.0:
			v_tail += S.airspeed(m)
			k += 1
	var v_end := v_tail / maxi(k, 1)
	var returned := not blow and k > 0 and absf(v_end - v_trim) <= 0.10 * v_trim
	var tuck := blow or th_min < -60.0 or a_max > 90.0 or not returned
	return {"V0_kmh": v0 * 3.6, "V_end_kmh": v_end * 3.6, "theta_min_deg": th_min, "alpha_abs_max_deg": a_max,
		"g_max": g_max, "load_max": load_max, "returned": returned, "blowup": blow, "tuck": tuck}


func _vm4(w: String) -> Dictionary:
	var out := {}
	var m := _game_model(w)
	var tr := m.solve_trim()
	var v_trim := float(tr.V)
	out["vm4_trim"] = {"V_kmh": v_trim * 3.6, "alpha_deg": rad_to_deg(float(tr.alpha)),
		"passport_kmh": float(Config.get_config("wings/" + w).trim_speed_kmh), "nl_on": m.strips.nl_on}
	out["normal"] = _vm4_pull(m, false)
	# справочно (не VM-К5): тот же плавный выход с обычного полного «на себя» без Shift (решение пользователя 10:34)
	out["release_smooth_normal"] = _vm4_release_keys(m, false, v_trim)
	# full, затем release_smooth на той же модели
	m = _game_model(w)
	out["full"] = _vm4_pull(m, true)
	out["release_smooth"] = _vm4_release_keys(m, true, v_trim)
	# release_1p8: установившаяся V = min(1,8·Vтрим, V full) на постоянном pitch с добором, затем ввод 0 скачком
	var v_full := float(out.full.V_kmh) / 3.6
	var v_tgt := minf(1.8 * v_trim, v_full)
	var p := -1.0
	var it := 0
	if v_tgt < v_full - 0.5:
		# постоянный pitch под цель: секущие по установившейся V (среднее за 40–50 с)
		var p0 := -clampf((v_tgt * v_tgt - v_trim * v_trim) / maxf(v_full * v_full - v_trim * v_trim, 1.0), 0.05, 1.0)
		var f0 := _vm4_steady(w, p0) - v_tgt
		var p1 := clampf(p0 + 0.15 * signf(f0), -1.0, -0.02)  # медленнее цели — сильнее на себя
		var f1 := _vm4_steady(w, p1) - v_tgt
		p = p1
		for _k in 8:
			it += 1
			if absf(f1) < 0.005 * v_tgt or absf(f1 - f0) < 1.0e-6:
				break
			var p2 := clampf(p1 - f1 * (p1 - p0) / (f1 - f0), -1.0, -0.02)
			p0 = p1
			f0 = f1
			p1 = p2
			f1 = _vm4_steady(w, p1) - v_tgt
			p = p1
	m = _game_model(w)
	var inp := S.input(0.0)
	inp.pull_full = true
	var vs := 0.0
	var nv := 0
	for i in int(T_END / DT):
		inp.pitch = p * clampf(m.time_s / T_RAMP, 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if m.time_s > T_AVG:
			vs += S.airspeed(m)
			nv += 1
	var p_hold := p
	var zero := S.input(0.0)
	var r8 := _vm4_release(m, func(_m: PendulumModel) -> ControlInput: return zero, v_trim)
	r8["V_target_kmh"] = v_tgt * 3.6
	r8["V_hold_kmh"] = vs / maxi(nv, 1) * 3.6
	r8["pitch_hold"] = p_hold
	r8["secant_iter"] = it
	out["release_1p8"] = r8
	return out


## Установившаяся воздушная скорость на постоянном pitch с добором (рампа 6 с, среднее за 40–50 с), м/с.
func _vm4_steady(w: String, p: float) -> float:
	var m := _game_model(w)
	var inp := S.input(0.0)
	inp.pull_full = true
	var vs := 0.0
	var n := 0
	for i in int(50.0 / DT):
		inp.pitch = p * clampf(m.time_s / T_RAMP, 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if m.time_s > 40.0:
			vs += S.airspeed(m)
			n += 1
	return vs / maxi(n, 1)


## Плавный выход (VM-К5 v2): модификатор отпущен в начале (предел возвращается по VM-К3 v2), pitch линейно −1 → 0
## за T_HAND с — пилот возвращает мышь/ручку рукой (через ControlInput, как мышь/стик); 30 с.
const T_HAND := 0.5


func _vm4_release_keys(m: PendulumModel, _full: bool, v_trim: float) -> Dictionary:
	var inp := S.input(-1.0)
	inp.pull_full = false
	var t0 := m.time_s
	var ctrl := func(mm: PendulumModel) -> ControlInput:
		inp.pitch = -clampf(1.0 - (mm.time_s - t0) / T_HAND, 0.0, 1.0)
		return inp
	var rs := _vm4_release(m, ctrl, v_trim)
	rs["hand_s"] = T_HAND
	return rs


# ---------------------------------------------------------------- VM-12 (VM-К7 v2): болтанка

## 20 зёрен по 40 с: поле — turb_fields.py (24 моды, оси игры), крен держит BankHold, тангаж 0. Переворот — |крен| > 60°,
## тангаж киля < −60° или развал (как VM-6 sc=turb).
func _turb(w: String) -> Dictionary:
	var fields: Array = JSON.parse_string(FileAccess.get_file_as_string(String(_args.turb)))
	var rows: Array = []
	var n_up := 0
	for fld: Dictionary in fields:
		var m := _game_model(w)
		var off := S.reset(m)
		var tb := S.Turbulence.new(fld, off)
		var bh := S.BankHold.new(0.0, 1.5, 0.8, 0.3)
		var inp := S.input()
		var phi := 0.0
		var th_min := 0.0
		var blow := false
		for i in int(round(40.0 / DT)):
			inp.roll = bh.roll(m)
			m.step(DT, inp, tb.air, Callable())
			if not S.finite(m) or S.airspeed(m) > 80.0:
				blow = true
				break
			phi = maxf(phi, absf(rad_to_deg(m.bank)))
			th_min = minf(th_min, rad_to_deg(m.theta))
		var up := blow or phi > 60.0 or th_min < -60.0
		n_up += int(up)
		rows.append({"seed": int(fld.seed), "phi_max_deg": phi, "theta_min_deg": th_min, "blowup": blow, "upset": up})
	return {"upsets": n_up, "n": rows.size(), "rows": rows}
