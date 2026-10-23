extends TestCase
## TP-17: установившаяся скорость дельталёта (PendulumModel trike_ixess15 + тележка configs/tow_tug.json cart)
## от хода штанги u (м от нуля ввода, + «на себя» = быстрее) и газа g. Тяга — таблица TT-К1 вдоль оси тележки
## (как TrikeRig.ext_force). Ход рук растянут до 1,0 м, ввод pitch = -u (pitch -1 = «на себя»; ход измеряется в метрах).
## Запуск (из корня копии): tools/research/trike-pilot/run_sweep.sh
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")

var _tug: Dictionary
var _thr := 0.0
var _model: PendulumModel
var _mass_cfg := 272.25


func _interp(xs: Array, ys: Array, x: float) -> float:
	if x <= xs[0]:
		return ys[0]
	for i in range(1, xs.size()):
		if x <= xs[i]:
			var f: float = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
			return ys[i - 1] + f * (ys[i] - ys[i - 1])
	return ys[xs.size() - 1]


func _axes(pp: Vector3, hp: Vector3, wb: Basis) -> Basis:
	var y := (hp - pp).normalized()
	var f: Vector3 = -wb.z
	f = (f - y * f.dot(y)).normalized()
	var z := -f
	return Basis(y.cross(z), y, z)


func _ext(s: Dictionary) -> Dictionary:
	var th: Dictionary = _tug.thrust
	var v: float = S.airspeed(_model)
	var ti: float = _interp(th.v_ms, th.idle_n, v)
	var t: float = ti + _thr * (_interp(th.v_ms, th.full_n, v) - ti)
	var cb := _axes(s.pilot_pos, s.hang_pos, s.wing_basis)
	var tilt := deg_to_rad(float(_tug.engine.thrust_tilt_deg))
	return {"pilot": (-cb.z * cos(tilt) + cb.y * sin(tilt)) * t, "hang": Vector3.ZERO}


func _run(u: float, g: float, opts: Dictionary) -> Dictionary:
	_tug = Config.get_config("tow_tug")
	var cart: Dictionary = _tug.cart
	var app := {"hang_length_m": float(opts.get("hang", cart.cg_below_hang_m)), "pilot_cda_m2": float(cart.cda_m2),
		"arms_force_max_n": float(opts.get("force", 5000.0))}
	var m := S.make("trike_ixess15", float(opts.get("mass", _mass_cfg)), app)
	m.arms.shift_x_push = 1.0
	m.arms.shift_x_pull = 1.0
	m.arms.shift_x_pull_full = 1.0
	if opts.has("sigma"):
		m.strips.nl_soft *= (1.0 - float(opts.sigma)) / 0.5
	_model = m
	_thr = g
	S.reset(m)
	m.set_external_force(_ext)
	var inp := S.input(-u)
	var n := int(round(float(opts.get("t", 75.0)) / S.DT))
	var t0 := float(opts.get("t0", 45.0))
	var th := 0.0
	var v := 0.0
	var vy := 0.0
	var vmin := 1e9
	var vmax := -1e9
	var k := 0
	var th_s := 0.0
	var ramp := float(opts.get("ramp", 0.0))
	for i in n:
		if ramp > 0.0:
			inp.pitch = -u * minf(1.0, m.time_s / ramp)
		m.step(S.DT, inp, Callable(), Callable())
		if m.time_s > t0:
			var vv: float = S.airspeed(m)
			v += vv
			vmin = minf(vmin, vv)
			vmax = maxf(vmax, vv)
			vy += m.velocity.y
			th += asin(clampf((-m.wing_basis().z).normalized().y, -1.0, 1.0))
			k += 1
	return {"pull_m": u, "g": g, "v_ms": v / k, "v_kmh": v / k * 3.6, "vy": vy / k, "theta_deg": rad_to_deg(th / k),
		"vmin_kmh": vmin * 3.6, "vmax_kmh": vmax * 3.6, "alt_end": m.position.y, "phi_deg": rad_to_deg(m.arms.phi),
		"finite": S.finite(m)}


func test_sweep() -> void:
	var us := [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
	for sg: float in [0.5, 0.25, 0.0]:
		for hang: float in [1.71]:
			for u: float in us:
				var r := _run(u, 0.5, {"ramp": 20.0, "sigma": sg, "hang": hang})
				r["sigma"] = sg
				r["hang"] = hang
				print("TP17 ", JSON.stringify(r))
	check(true)
