extends Node
## Исследование тангажа «Маятника» на разгоне (research/pendulum-pitch): установившиеся режимы по ходу
## трапеции и переходы трим → «на себя» (ступенька, рампа клавиатуры, плавная рампа). Без окна.
##
## XDG_DATA_HOME=~/.cache/dp-xdg/deltaplan-pendulum-pitch godot --headless --path . \
##     res://tools/flight/pendulum_pitch.tscn -- --out=tools/research/pendulum_pitch/out/game.json \
##     [--wings=training,laminar,sport] [--hang_shift_cm=0] [--iyy_scale=1] [--cmq_add=0]
##
## Каждое крыло: эталонная масса пилота, плотность 1,225, штиль. Углы: θ — тангаж киля над горизонтом,
## γ — угол траектории ЦМ крыла (+ вверх), α — угол атаки киля (θ ≈ γ + α при нулевом крене),
## q — угловая скорость тангажа (+ нос вверх). Знак ввода: pitch −1 — «на себя» (пилот вперёд).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const G := 9.81
const SWEEP := [0.5, 0.25, 0.0, -0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8, -0.9, -1.0]
## (имя, время выхода на полный ход, с, итоговый ход): ступенька — мышь, 0,67 с — клавиатура
## (controls.json keyboard.pitch_rate_per_s 1,5), 3 и 6 с — плавно.
const RAMPS := [["step", 0.0, -1.0], ["kbd", 0.667, -1.0], ["ramp3", 3.0, -1.0], ["ramp6", 6.0, -1.0]]

var _args := {"out": "tools/research/pendulum_pitch/out/game.json", "wings": "training,laminar,sport",
	"hang_shift_cm": "", "iyy_scale": "1", "cmq_add": "0", "series": "1",
	"long": "", "arms_tau": "", "arms_fmax": "", "long_s": "300", "long_ramp": "6"}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	var res := {"args": _args, "wings": {}}
	if String(_args.long) != "":
		# --long=-1,-0.5: рампа 6 с к ходу, затем long_s с; γ, θ, α, V, сила рук, n каждые 0,1 с
		for w in String(_args.wings).split(","):
			res.wings[w] = {}
			for ps in String(_args.long).split(","):
				res.wings[w][ps] = _long(w, float(ps), float(_args.long_s))
		var fl := FileAccess.open(String(_args.out), FileAccess.WRITE)
		fl.store_string(JSON.stringify(res, " ", false))
		fl.close()
		get_tree().quit(0)
		return
	for w in String(_args.wings).split(","):
		var r := {}
		var m0 := _model(w)
		r["trim"] = _state(m0)
		r["trim"]["trim_pitch_deg"] = rad_to_deg(m0.trim_pitch())
		r["polar"] = Config.get_config("wings/" + w).polar.points_kmh_ms
		r["iyy"] = m0._I_b.y.y
		r["sweep"] = []
		for p: float in SWEEP:
			r.sweep.append(_steady(w, p))
		r["transients"] = {}
		for rp: Array in RAMPS:
			r.transients[rp[0]] = _transient(w, float(rp[1]), float(rp[2]))
		# ступенька на ход, дающий 1,6·V_трим в установившемся режиме (если есть)
		var p16 := _pitch_for_ratio(r.sweep, float(r.trim.V_kmh) * 1.6)
		if not is_nan(p16):
			r.transients["step_to_1.6"] = _transient(w, 0.0, p16)
			r.transients["ramp3_to_1.6"] = _transient(w, 3.0, p16)
		r["pitch_impulse"] = _impulse(w)
		res.wings[w] = r
		print("%s: trim V %.1f θ %.1f; full pull steady V %.1f θ %.1f γ %.1f α %.1f; step θmin %.1f" % [
			w, r.trim.V_kmh, r.trim.theta_deg, r.sweep[-1].V_kmh, r.sweep[-1].theta_deg,
			r.sweep[-1].gamma_deg, r.sweep[-1].alpha_deg, r.transients.step.theta_min_deg])
	var f := FileAccess.open(String(_args.out), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " ", false))
	f.close()
	get_tree().quit(0)


func _model(w: String) -> PendulumModel:
	var app := {}
	if String(_args.hang_shift_cm) != "":
		app["hang_shift_cm"] = float(_args.hang_shift_cm)
	var m := S.make(w, 0.0, app)
	var k := float(_args.iyy_scale)
	if k != 1.0:
		m._I_b.y.y *= k
		m._I_inv = m._I_b.inverse()
	if String(_args.arms_tau) != "":
		m.arms.tau = float(_args.arms_tau)
	if String(_args.arms_fmax) != "":
		m.arms.force_max = float(_args.arms_fmax)
	S.reset(m)
	return m


func _long(w: String, p: float, T: float) -> Dictionary:
	var m := _model(w)
	var inp := S.input(0.0)
	var ser: Array = []
	for i in int((T + 6.0) / DT):
		inp.pitch = p * clampf(m.time_s / maxf(float(_args.long_ramp), 1.0e-3), 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if i % 12 == 0:
			var s := _state(m)
			ser.append([snappedf(m.time_s, 0.01), snappedf(s.theta_deg, 0.01), snappedf(s.gamma_deg, 0.01),
				snappedf(s.alpha_deg, 0.01), snappedf(s.V_kmh, 0.01), snappedf(s.bar_n, 0.1), snappedf(s.n, 0.001),
				snappedf(s.shift, 0.001)])
	return {"cols": ["t", "theta", "gamma", "alpha", "V_kmh", "bar_n", "n", "shift"], "series": ser,
		"finite": S.finite(m)}


func _gamma(m: PendulumModel) -> float:
	var v := m._vel
	return atan2(-v.z, Vector2(v.x, v.y).length())


func _q(m: PendulumModel) -> float:
	return (m._R.transposed() * m._w).y


func _state(m: PendulumModel) -> Dictionary:
	var V := S.airspeed(m)
	return {"V_kmh": V * 3.6, "theta_deg": rad_to_deg(m.theta), "gamma_deg": rad_to_deg(_gamma(m)),
		"alpha_deg": rad_to_deg(m.alpha), "sink_ms": m._vel.z, "q_dps": rad_to_deg(_q(m)),
		"shift": m.pilot_shift.y, "bar_n": m.bar_force_wing.y, "n": m.strap_tension / (m.pilot_mass * G)}


## Ход pitch держится 90 с; средние за последние 30 с и размах θ (колебания).
func _steady(w: String, p: float) -> Dictionary:
	var m := _model(w)
	var inp := S.input(p)
	var acc := {}
	var k := 0
	var th_lo := INF
	var th_hi := -INF
	for i in int(90.0 / DT):
		m.step(DT, inp, Callable(), Callable())
		if m.time_s > 60.0:
			var s := _state(m)
			for key: String in s:
				acc[key] = float(acc.get(key, 0.0)) + float(s[key])
			k += 1
			th_lo = minf(th_lo, s.theta_deg)
			th_hi = maxf(th_hi, s.theta_deg)
	var r := {"pitch": p, "theta_p2p_deg": th_hi - th_lo, "stall": m.stall_amount(), "finite": S.finite(m)}
	for key: String in acc:
		r[key] = float(acc[key]) / k
	return r


func _pitch_for_ratio(sweep: Array, v_target: float) -> float:
	for i in range(1, sweep.size()):
		var a: Dictionary = sweep[i - 1]
		var b: Dictionary = sweep[i]
		if float(b.pitch) < 0.0 and float(a.V_kmh) <= v_target and float(b.V_kmh) >= v_target:
			var t := (v_target - float(a.V_kmh)) / maxf(float(b.V_kmh) - float(a.V_kmh), 1.0e-6)
			return lerpf(float(a.pitch), float(b.pitch), t)
	return NAN


## Трим 0 → ход p_end за t_ramp с (0 — ступенька), держится 60 с.
func _transient(w: String, t_ramp: float, p_end: float) -> Dictionary:
	var m := _model(w)
	var s0 := _state(m)
	var v16 := float(s0.V_kmh) * 1.6
	var inp := S.input(0.0)
	var ser: Array = []
	var mn := {"theta_deg": INF}
	var at16 := {}
	var q_min := INF
	var a_min := INF
	var g_min := INF
	var n_min := INF
	var n_max := -INF
	var v_max := 0.0
	for i in int(60.0 / DT):
		var t := m.time_s
		inp.pitch = p_end if t_ramp <= 0.0 else p_end * clampf(t / t_ramp, 0.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		var s := _state(m)
		s["t"] = m.time_s
		if s.theta_deg < float(mn.theta_deg):
			mn = s
		q_min = minf(q_min, s.q_dps)
		a_min = minf(a_min, s.alpha_deg)
		g_min = minf(g_min, s.gamma_deg)
		n_min = minf(n_min, s.n)
		n_max = maxf(n_max, s.n)
		v_max = maxf(v_max, s.V_kmh)
		if at16.is_empty() and s.V_kmh >= v16:
			at16 = s
		if String(_args.series) == "1" and i % 6 == 0 and m.time_s <= 30.0:
			ser.append([snappedf(m.time_s, 0.01), snappedf(s.theta_deg, 0.01), snappedf(s.gamma_deg, 0.01),
				snappedf(s.alpha_deg, 0.01), snappedf(s.V_kmh, 0.01), snappedf(s.q_dps, 0.1),
				snappedf(s.shift, 0.001), snappedf(s.bar_n, 0.1), snappedf(s.n, 0.001)])
	return {"t_ramp_s": t_ramp, "pitch_end": p_end, "trim": s0, "at_theta_min": mn, "at_1.6Vtrim": at16,
		"theta_min_deg": mn.theta_deg, "q_min_dps": q_min, "alpha_min_deg": a_min, "gamma_min_deg": g_min,
		"n_min": n_min, "n_max": n_max, "V_max_kmh": v_max, "end": _state(m), "finite": S.finite(m),
		"stall_end": m.stall_amount(),
		"series_cols": ["t", "theta", "gamma", "alpha", "V_kmh", "q_dps", "shift", "bar_n", "n"],
		"series": ser}


## Короткопериодическое движение: руки держат нейтраль, толчок по тангажу q = −20 °/с от трима;
## α(t) в первые 3 с — частота и затухание.
func _impulse(w: String) -> Dictionary:
	var m := _model(w)
	var R := m._R
	m._w += R * Vector3(0.0, deg_to_rad(-20.0), 0.0)
	var inp := S.input(0.0)
	var a0 := m.alpha
	var ser: Array = []
	for i in int(4.0 / DT):
		m.step(DT, inp, Callable(), Callable())
		ser.append(rad_to_deg(m.alpha - a0))
	# экстремумы
	var ext: Array = []
	for i in range(1, ser.size() - 1):
		if (ser[i] - ser[i - 1]) * (ser[i + 1] - ser[i]) < 0.0 and absf(ser[i]) > 0.05:
			ext.append([snappedf((i + 1) * DT, 0.001), snappedf(ser[i], 0.001)])
	var thin: Array = []
	for i in range(0, ser.size(), 3):
		thin.append(snappedf(ser[i], 0.001))
	return {"extrema": ext, "dalpha_deg_every_25ms": thin}
