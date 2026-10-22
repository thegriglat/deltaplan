extends Node
## TP-19: временные ряды тангажа дельталёта на газу (PendulumModel trike_ixess15 + тележка configs/tow_tug.json).
## Запуск (из корня копии):
##   godot --headless --path . res://tools/research/trike-pilot/tp19_runner.tscn -- <spec.json> <out.jsonl>
## spec.json — массив прогонов {name, u, g, ...}; ключи (умолчания — как TP-17 speed_sweep.gd):
##   u — ход штанги «на себя» от нуля ввода, м; g — газ 0…1; t — длительность, с (90); force — предел рук, Н (5000);
##   thrust_at — "pilot" (как TowTug) | "hang" | "none"; thrust_const_n — постоянная тяга вместо таблицы (≤ 0 — таблица);
##   thrust_scale — множитель тяги; relaxed_x — руки вдоль киля отпущены (без ввода: «руки с штанги»);
##   ff_ext — прямая подача рук компенсирует тягу (true, как в игре) или нет;
##   dt_div — делитель шага модели (1 → 1/120 с), sub_mul — множитель подшагов цепи, aero_hz — частота полос;
##   kick_t, kick_dv — толчок скорости (м/с) вдоль полёта в момент kick_t для измерения затухания;
##   thrust_split — доля тяги на ЦМ тележки (остальное на подвеске: линия тяги на (1−a)·L выше ЦМ тележки);
##   cda — CdA тележки, м²; tau — постоянная рук, с; mass — масса тележки, кг; tilt_deg — наклон тяги к оси тележки.
## Выход: на прогон одна строка JSON {name, spec, series:{t,v,alpha,theta,vy,alt,fx_bar,phi,stall,thrust}} (20 Гц).
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")

var _tug: Dictionary
var _model: PendulumModel
var _spec: Dictionary
var _thrust := 0.0


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
	var g := float(_spec.get("g", 0.0))
	var t: float
	if float(_spec.get("thrust_const_n", 0.0)) > 0.0:
		t = float(_spec.thrust_const_n) * g
	else:
		var ti: float = _interp(th.v_ms, th.idle_n, v)
		t = ti + g * (_interp(th.v_ms, th.full_n, v) - ti)
	t *= float(_spec.get("thrust_scale", 1.0))
	_thrust = t
	var cb := _axes(s.pilot_pos, s.hang_pos, s.wing_basis)
	var tilt := deg_to_rad(float(_spec.get("tilt_deg", _tug.engine.thrust_tilt_deg)))
	var f: Vector3 = (-cb.z * cos(tilt) + cb.y * sin(tilt)) * t
	if _spec.has("thrust_split"):  # доля тяги на ЦМ тележки, остальное — на подвеске (линия тяги выше по стропе)
		var a := float(_spec.thrust_split)
		return {"pilot": f * a, "hang": f * (1.0 - a)}
	match String(_spec.get("thrust_at", "pilot")):
		"hang":
			return {"pilot": Vector3.ZERO, "hang": f}
		"none":
			return {"pilot": Vector3.ZERO, "hang": Vector3.ZERO}
	return {"pilot": f, "hang": Vector3.ZERO}


func _alpha(m: PendulumModel) -> float:
	var b := m.wing_basis()
	var va: Vector3 = m.telemetry.air_velocity
	return rad_to_deg(atan2(-va.dot(b.y), va.dot(-b.z)))


func _run(spec: Dictionary) -> Dictionary:
	_spec = spec
	_tug = Config.get_config("tow_tug")
	var cart: Dictionary = _tug.cart
	var app := {"hang_length_m": float(spec.get("hang", cart.cg_below_hang_m)), "pilot_cda_m2": float(spec.get("cda", cart.cda_m2)),
		"arms_force_max_n": float(spec.get("force", 5000.0))}
	var m := S.make("trike_ixess15", float(spec.get("mass", 272.25)), app)
	m.arms.shift_x_push = 1.0
	m.arms.shift_x_pull = 1.0
	m.arms.shift_x_pull_full = 1.0
	m.arms.pull_limit = 1.0
	if spec.has("tau"):
		m.arms.tau = float(spec.tau)
	m._sub_per_s *= float(spec.get("sub_mul", 1.0))
	if spec.has("aero_hz"):
		m.aero_hz = float(spec.aero_hz)
	_model = m
	S.reset(m)
	m.set_external_force(_ext)
	var inp := S.input(-float(spec.get("u", 0.0)))
	var dt: float = S.DT / float(spec.get("dt_div", 1.0))
	var n := int(round(float(spec.get("t", 90.0)) / dt))
	var every := maxi(1, int(round(0.05 / dt)))
	var relaxed_x := bool(spec.get("relaxed_x", false))
	var kick_t := float(spec.get("kick_t", -1.0))
	var kicked := false
	var ser := {"t": [], "v": [], "alpha": [], "theta": [], "vy": [], "alt": [], "fx_bar": [], "phi": [], "stall": [],
		"thrust": [], "strap_deg": []}
	for i in n:
		if relaxed_x:
			m.arms.release_event = true
			m.arms._rel_on = true  # руки вдоль киля отпущены (f.x = 0), поперёк держат
			m.arms.release_settle_m = 0.0
		if kick_t > 0.0 and not kicked and m.time_s >= kick_t:
			kicked = true
			var dv: Vector3 = m.velocity.normalized() * float(spec.get("kick_dv", 2.0))
			m._vel += PendulumModel.ned(dv)
			for j in m.chain.links:
				m.chain.v[j] += PendulumModel.ned(dv)
		m.step(dt, inp, Callable(), Callable())
		if i % every == 0:
			ser.t.append(snappedf(m.time_s, 0.001))
			ser.v.append(snappedf(S.airspeed(m) * 3.6, 0.01))
			ser.alpha.append(snappedf(_alpha(m), 0.01))
			ser.theta.append(snappedf(rad_to_deg(asin(clampf((-m.wing_basis().z).normalized().y, -1.0, 1.0))), 0.01))
			ser.vy.append(snappedf(m.velocity.y, 0.01))
			ser.alt.append(snappedf(m.position.y, 0.01))
			ser.fx_bar.append(snappedf(m.arms.force_b.x, 0.1))
			ser.phi.append(snappedf(rad_to_deg(m.arms.phi), 0.01))
			ser.stall.append(snappedf(m.stall_amount(), 0.001))
			ser.thrust.append(snappedf(_thrust, 0.1))
			var st: Vector3 = m.hang_position - m.pilot_position
			ser.strap_deg.append(snappedf(rad_to_deg(atan2(st.dot(-m.wing_basis().z), st.dot(m.wing_basis().y))), 0.01))
		if not S.finite(m):
			break
	return {"name": spec.get("name", ""), "spec": spec, "finite": S.finite(m), "series": ser}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var specs: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	for sp: Dictionary in specs:
		var r := _run(sp)
		f.store_line(JSON.stringify(r))
		f.flush()
		print("TP19 done ", sp.get("name", ""))
	f.close()
	get_tree().quit()
