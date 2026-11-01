extends Node
## PFT-1: продольный канал «Маятника». Режимы: steady (трим при вводе 0 / руки отпущены / сдвиг подвески),
## xtest (X и отдача штанги из установившихся режимов). Без окна, штиль, плотность постоянная.
## godot --headless --path . res://tools/research/pilot-feedback-trim/longitudinal/trim_batch.tscn -- \
##   --mode=steady --wings=sport,training --out=tools/research/pilot-feedback-trim/longitudinal/out/x.json [--mass=ref]
const DT := 1.0 / 120.0
var _a := {"mode": "steady", "wings": "sport", "out": "", "mass": "game", "shift": "0,2,4", "alt": "0", "ref_alt": "1000", "hold": "60", "after": "90"}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.contains("="):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1]
	var res := {"args": _a, "wings": {}}
	for w in String(_a.wings).split(","):
		res.wings[w] = _steady(w) if _a.mode == "steady" else (_launch(w) if _a.mode == "launch" else _xtest(w))
	var f := FileAccess.open(String(_a.out), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " ", false))
	f.close()
	get_tree().quit(0)


func _model(w: String, shift_cm := 0.0) -> PendulumModel:
	var wing: Dictionary = Config.get_config("wings/" + w).duplicate(true)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var mass := float(pilot.mass_kg)
	if _a.mass == "ref":
		mass = float(wing.pilot_mass_ref_kg)
	elif _a.mass != "game":
		mass = float(_a.mass)
	pilot.mass_kg = clampf(mass, float(wing.pilot_mass_min_kg), float(wing.pilot_mass_max_kg))
	var app := {}
	if shift_cm != 0.0:
		app["hang_shift_cm"] = shift_cm
	var m := PendulumModel.new()
	var fo := {} if _a.alt == "1" else {"air_density": {"altitude_dependent": false}}
	m.setup(wing, pilot, fo, app)
	if "release_event" in m.arms and _a.get("release_event", "") != "":
		m.arms.release_event = _a.release_event == "1"
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	return m


func _gamma(m: PendulumModel) -> float:
	var v := m._vel
	return atan2(-v.z, Vector2(v.x, v.y).length())


func _st(m: PendulumModel) -> Array:
	return [snappedf(m.time_s, 0.01), snappedf(m.telemetry.airspeed * 3.6, 0.01), snappedf(rad_to_deg(m.theta), 0.01),
		snappedf(rad_to_deg(_gamma(m)), 0.01), snappedf(rad_to_deg(m.alpha), 0.01), snappedf(rad_to_deg(m.bank), 0.01),
		snappedf(m.stall_amount(), 0.001), snappedf(m.pilot_shift.y, 0.001)]


func _run_const(m: PendulumModel, pitch: float, T: float, relaxed: bool, ser_dt: float) -> Dictionary:
	var inp := ControlInput.new()
	inp.pitch = pitch
	if "arms_relaxed" in m:
		m.arms_relaxed = relaxed
	var ser: Array = []
	var acc := [0.0, 0.0, 0.0, 0.0]
	var n := 0
	var vmin := INF
	var vmax := -INF
	var thmax := -INF
	var thmin := INF
	var stmax := 0.0
	var nan := false
	var every := maxi(1, int(ser_dt / DT))
	for i in int(T / DT):
		m.step(DT, inp, Callable(), Callable())
		var s := _st(m)
		if not is_finite(float(s[1])):
			nan = true
			break
		if m.time_s <= 20.0:
			vmin = minf(vmin, s[1]); vmax = maxf(vmax, s[1]); thmax = maxf(thmax, s[2]); thmin = minf(thmin, s[2]); stmax = maxf(stmax, s[6])
		if m.time_s > T - 20.0:
			acc[0] += s[1]; acc[1] += s[2]; acc[2] += s[3]; acc[3] += s[4]
			n += 1
		if i % every == 0 and m.time_s <= 30.0:
			ser.append(s)
	var r := {"nan": nan, "v20": [vmin, vmax], "th20": [thmin, thmax], "stall20": stmax, "series30": ser}
	if n > 0:
		r["V"] = acc[0] / n; r["theta"] = acc[1] / n; r["gamma"] = acc[2] / n; r["alpha"] = acc[3] / n
	return r


func _steady(w: String) -> Dictionary:
	var m0 := _model(w)
	var wing: Dictionary = Config.get_config("wings/" + w)
	var r := {"group": wing.get("group", ""), "trim_kmh": wing.trim_speed_kmh, "pend_ref_trim": wing.pendulum.ref.trim_kmh,
		"kmh_per_cm": wing.pendulum.ref.get("kmh_per_cm_hang", 0.0), "mass": m0.pilot_mass,
		"mass_ref": wing.pilot_mass_ref_kg, "solve_trim_kmh": float(m0.solve_trim().V) * 3.6,
		"solve_trim_theta": rad_to_deg(float(m0.solve_trim().theta))}
	r["neutral"] = _run_const(_model(w), 0.0, float(_a.hold), false, 0.25)
	r["relaxed"] = _run_const(_model(w), 0.0, float(_a.hold), true, 0.25)
	r["shift"] = {}
	for sh in String(_a.shift).split(","):
		if float(sh) != 0.0:
			var q := _run_const(_model(w, float(sh)), 0.0, 40.0, false, 100.0)
			r.shift[sh] = {"V": q.get("V"), "theta": q.get("theta")}
	return r


## X из установившегося режима: kind=pull/push/bank30; затем способ отдачи.
func _xtest(w: String) -> Dictionary:
	var out := {}
	for kind in String(_a.get("kinds", "pull,push,bank30")).split(","):
		for how in String(_a.get("hows", "X,instant,ramp1.5")).split(","):
			var m := _model(w)
			var inp := ControlInput.new()
			var p0: float = {"pull": -1.0, "push": 1.0, "bank30": 0.0}.get(kind, 0.0)
			if kind.begins_with("q"):
				p0 = float(kind.substr(1))
			var bank_t := deg_to_rad(30.0)
			var ik := 0.0
			var hold := float(_a.hold)
			var after := float(_a.after)
			var ser: Array = []
			var t_rel := -1.0
			for i in int((hold + after) / DT):
				var t: float = m.time_s
				var k := 1.0
				if t >= hold:
					if t_rel < 0.0:
						t_rel = t
					var dt_r := t - t_rel
					if how.begins_with("X"):
						k = exp(-dt_r / (float(how.substr(1)) if how.length() > 1 else 0.2))
					match how:
						"instant": k = 0.0
						"ramp1.5": k = clampf(1.0 - dt_r / 1.5, 0.0, 1.0)
				inp.pitch = p0 * k
				if kind == "bank30":
					var e := bank_t * k - m.bank
					ik = clampf(ik + 0.3 * e * DT, -1.0, 1.0)
					inp.roll = clampf(1.0 * e - 0.4 * m.roll_rate + ik, -1.0, 1.0)
				m.step(DT, inp, Callable(), Callable())
				if i % 12 == 0 and t >= hold - 1.0:
					ser.append(_st(m))
			out[kind + "_" + how] = {"t_release": hold, "series": ser}
	return out


## Разбег по склону и отрыв, затем 40 с при вводе pitch (0 — мышь в нейтрали). Серия с отрыва, шаг 0,25 с.
func _launch(w: String) -> Dictionary:
	var res := {}
	for slope in String(_a.get("slope", "12,17")).split(","):
		var k := tan(deg_to_rad(float(slope)))
		var gf := func(_x: float, z: float) -> float: return 1000.0 + k * z
		var af := func(_p: Vector3) -> Vector3: return Vector3.ZERO
		var m := _model(w)
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var inp := ControlInput.new()
		inp.run = true
		inp.pitch = float(_a.get("pitch", "0"))
		var t_lo := -1.0
		var ser: Array = []
		var vmin := INF
		var vmax := -INF
		var thmax := -INF
		var stmax := 0.0
		var n := 0
		while m.time_s < 80.0:
			m.step(DT, inp, af, gf)
			n += 1
			if t_lo < 0.0 and m.mode == FlightModel.Mode.AIR:
				t_lo = m.time_s
			if t_lo >= 0.0:
				var s := _st(m)
				if m.time_s - t_lo > 1.0 and m.time_s - t_lo <= 21.0:
					vmin = minf(vmin, s[1]); vmax = maxf(vmax, s[1]); thmax = maxf(thmax, s[2]); stmax = maxf(stmax, s[6])
				if n % 30 == 0 and m.time_s - t_lo <= 40.0:
					s[0] = snappedf(m.time_s - t_lo, 0.01)
					ser.append(s)
				if m.time_s - t_lo > 40.0:
					break
		res[slope] = {"t_liftoff": t_lo, "v_min_1_21": vmin, "v_max_1_21": vmax, "th_max_1_21": thmax, "stall_max": stmax,
			"series": ser, "phase": m.phase()}
	return res
