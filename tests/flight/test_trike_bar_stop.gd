extends TestCase
## Контракт TKF-К4 v2 (docs/contracts/trike-fix.md): упор переднего подкоса в физике дельталёта (ключ cart.strut_stop,
## PendulumModel) и ход штанги «на себя» игрока (configs/trike_pilot.json → arms). bar_deg_phys считается как в
## tools/research/trike-fix/coupling_run.gd (TKF-К1): середина базовой штанги в осях C_phys от bar.trim, «+» к подкосу.
## Шаг 1/120 с, тяга по таблице tow_tug.json (T = idle + g (full - idle)), воздух неподвижный, земля y = 0.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const BAR_WING := Vector3(0.0, 0.6793, -1.5287)
const BAR_TRIM := Vector2(0.72, 1.51)
const PULL_BODY_DEG := -10.29  ## bar_deg касания тела на полном «на себя» при 0,178 м (strut.md, TKF-9); ниже - сквозь тело
const PULL_TOL_DEG := 0.4

var _cfg: Dictionary
var _g: Glider


static func flat(_x: float, _z: float) -> float:
	return 0.0


func _limits() -> Dictionary:
	var tp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
	return {"push": float(tp.bar.push_deg), "pull": float(tp.bar.pull_deg)}


func _interp(xs: Array, ys: Array, x: float) -> float:
	if x <= xs[0]:
		return ys[0]
	for i in range(1, xs.size()):
		if x <= xs[i]:
			var f: float = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
			return ys[i - 1] + f * (ys[i] - ys[i - 1])
	return ys[xs.size() - 1]


func _thrust(v: float, gk: float) -> float:
	var th: Dictionary = _cfg.thrust
	var ti := _interp(th.v_ms, th.idle_n, v)
	return ti + gk * (_interp(th.v_ms, th.full_n, v) - ti)


static func bar_deg(rig: TrikeRig, vis: bool = false) -> float:
	var c := rig.cart_basis if vis else rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, false)
	var bw: Vector3 = c.transposed() * (rig.wing_basis * BAR_WING)
	return rad_to_deg(atan2(bw.y, -bw.z) - atan2(BAR_TRIM.x, BAR_TRIM.y))


func _theta_deg() -> float:
	return rad_to_deg(asin(clampf((-_g.model.wing_basis().z).normalized().y, -1.0, 1.0)))


## Сценарий: input_fn(t) -> [pitch, газ]. -> {bar_min, bar_max (с 1 с), jump_on_stop (наибольшее изменение скорости
## тангажа крыла за шаг, °/с, у упора: bar_deg > push - 0,05 на этом или прошлом шаге), rate_peak (°/с, окно 0,1 с,
## за 2 с после t_in), finite}
func _run(input_fn: Callable, dur: float, t_in: float = 0.0) -> Dictionary:
	if _g != null:
		_g.free()
	_g = Glider.new()
	_g.set_ground_fn(flat)
	_g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	_g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
	var rig := _g.trike
	rig.refresh(0.0)
	var ctl := ControlInput.new()
	var push := float(_limits().push)
	var bmin := INF
	var bmax := -INF
	var vis_max := -INF
	var vis_min := INF
	var v_late := 0.0
	var th: Array = []
	var jump := 0.0
	var on_prev := false
	var ok := true
	for i in int(round(dur / DT)):
		var t := i * DT
		var u: Array = input_fn.call(t)
		ctl.pitch = u[0]
		rig.thrust_n = _thrust(_g.model.telemetry.airspeed, u[1])
		_g.model.step(DT, ctl, Callable(), Callable(flat))
		rig.refresh(DT)
		var b := bar_deg(rig)
		ok = ok and is_finite(b) and S.finite(_g.model)
		if t >= 1.0:
			bmin = minf(bmin, b)
			bmax = maxf(bmax, b)
			var bv := bar_deg(rig, true)
			vis_max = maxf(vis_max, bv)
			vis_min = minf(vis_min, bv)
		if t >= dur - 20.0:
			v_late = maxf(v_late, _g.model.telemetry.airspeed * 3.6)
		th.append(_theta_deg())
		var on := b > push - 0.05
		if i > 1 and t > 1.0 and (on or on_prev):
			var w: float = (th[i] - th[i - 1]) / DT
			var w0: float = (th[i - 1] - th[i - 2]) / DT
			jump = maxf(jump, absf(w - w0))
		on_prev = on
	var peak := 0.0
	var h := 12
	var a := int(round(t_in / DT))
	for i in range(a + h, mini(th.size(), a + int(2.0 / DT) + 1)):
		peak = maxf(peak, absf(th[i] - th[i - h]) / (h * DT))
	return {"bar_min": bmin, "bar_max": bmax, "vis_min": vis_min, "vis_max": vis_max, "v_late_kmh": v_late, "jump_on_stop": jump, "rate_peak": peak, "finite": ok}


func _load_cfg() -> void:
	_cfg = Config.get_config("tow_tug").duplicate(true)


func test_contract_version() -> void:
	var txt := FileAccess.get_file_as_string("res://docs/contracts/trike-fix.md")
	var re := RegEx.create_from_string("(?m)^## TKF-К4 v(\\d+)\\.")
	var m := re.search(txt)
	check(m != null and m.get_string(1) == "2", "версия раздела TKF-К4 - v2")


## (1) Без ключа - модель прежняя бит в бит: ключ с недостижимым углом ничего не меняет (дельтаплан и тележка).
func test_without_key_unchanged() -> void:
	for kind in ["wing", "trike"]:
		var traj: Array = []
		for variant in ["none", "far"]:
			var m: PendulumModel
			var rig: TrikeRig = null
			if kind == "wing":
				m = S.make("sport", 0.0, {"strut_stop": {"angle_deg": -90.0, "stiffness_nm_rad": 2.0e5, "damping_nms_rad": 5000.0}} if variant == "far" else {})
				S.reset(m)
			else:
				var cfg := Config.get_config("tow_tug").duplicate(true)
				if variant == "far":
					cfg.cart.strut_stop.angle_deg = -90.0
				else:
					cfg.cart.erase("strut_stop")
				var g := Glider.new()
				g.set_ground_fn(flat)
				g.setup_trike(cfg, 0.0, Config.get_config("trike_pilot"))
				g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
				m = g.model
				rig = g.trike
				rig.thrust_n = 600.0
			for i in 1200:  # 10 с, качание штанги +-1
				var inp := S.input(1.0 if fmod(i * DT, 2.6) < 1.3 else -1.0, 0.0)
				m.step(DT, inp, Callable(), Callable(flat))
			traj.append([m.position, m.velocity, m.theta, m.pilot_position])
		check(traj[0] == traj[1], "%s: траектория с недостижимым упором равна траектории без ключа" % kind)
	# упор, который достижим, заметно меняет тележку (проверка, что ключ вообще действует)
	var cfg2 := Config.get_config("tow_tug").duplicate(true)
	check(cfg2.cart.has("strut_stop"), "configs/tow_tug.json: cart.strut_stop есть")
	check(absf(float(cfg2.cart.strut_stop.angle_deg) + 10.87) < 1e-9, "угол упора -10,87 (bar_deg = push_deg в осях с ЦМ за подвеской)")


## (2) Дельталёт игрока: bar_deg_phys не выше push_deg + 0,5 на push_full, pitch_pump, trim_full, throttle_step.
## (4) Упор без скачков: изменение скорости тангажа крыла за шаг у упора не больше 10 °/с.
func test_bar_not_beyond_strut() -> void:
	_load_cfg()
	var lim := _limits()
	var scen := {
		"push_full": [func(t: float) -> Array: return [1.0 if t < 10.0 else 0.0, 1.0], 20.0],
		"pitch_pump": [func(t: float) -> Array: return [1.0 if fmod(t, 2.6) < 1.3 else -1.0, 1.0], 20.0],
		"pitch_pump_idle": [func(t: float) -> Array: return [1.0 if fmod(t, 2.6) < 1.3 else -1.0, 0.0], 20.0],
		"trim_full": [func(_t: float) -> Array: return [0.0, 1.0], 15.0],
		"throttle_step": [func(t: float) -> Array: return [0.0, 1.0 if (t >= 5.0 and t < 10.0) else 0.0], 20.0],
	}
	for name: String in scen:
		var r := _run(scen[name][0], scen[name][1])
		print("TKF-5 ", name, " bar_phys [", snappedf(r.bar_min, 0.01), "; ", snappedf(r.bar_max, 0.01), "] jump_on_stop ", snappedf(r.jump_on_stop, 0.01))
		check(r.finite, "%s: конечные числа" % name)
		check(r.bar_max <= lim.push + 0.5, "%s: bar_deg_phys max %.2f <= push_deg %.2f + 0,5" % [name, r.bar_max, lim.push])
		check(r.vis_max <= lim.push + 0.5, "%s: bar_deg_vis max %.2f <= push_deg %.2f + 0,5" % [name, r.vis_max, lim.push])
		check(r.jump_on_stop <= 10.0, "%s: скачок скорости тангажа у упора %.2f °/с <= 10" % [name, r.jump_on_stop])
	var rp := _run(scen.push_full[0], 20.0)
	check(rp.bar_max > lim.push - 0.5, "push_full доходит до упора: bar_deg_phys max %.2f" % rp.bar_max)


## (3'') Полный «на себя» (10 с трима, потом pitch -1) на газу 0 / 0,5 / 1: штанга доходит до груди, не глубже (Q4 б: bar_deg_vis >= -10,29 - допуск).
func test_pull_full() -> void:
	_load_cfg()
	for gas in [0.0, 0.5, 1.0]:
		var r := _run(func(t: float) -> Array: return [-1.0 if t >= 10.0 else 0.0, gas], 18.0, 10.0)
		print("TKF-5 pull gas ", gas, " bar_min phys ", snappedf(r.bar_min, 0.01), " vis ", snappedf(r.vis_min, 0.01), " rate ", snappedf(r.rate_peak, 0.1))
		check(r.finite, "pull газ %.1f: конечные числа" % gas)
		check(r.vis_min >= PULL_BODY_DEG - PULL_TOL_DEG, "газ %.1f: bar_deg_vis min %.2f не глубже касания тела %.2f" % [gas, r.vis_min, PULL_BODY_DEG])
		check(r.bar_min >= PULL_BODY_DEG - PULL_TOL_DEG, "газ %.1f: bar_deg_phys min %.2f не глубже касания тела %.2f" % [gas, r.bar_min, PULL_BODY_DEG])


## (3') Полный «от себя» на газу 0 (60 с): установившаяся скорость (последние 20 с, наибольшая) не выше 58 км/ч - упор не отнимает ход.
func test_push_full_speed() -> void:
	_load_cfg()
	var r := _run(func(_t: float) -> Array: return [1.0, 0.0], 60.0)
	print("TKF-5 push gas0 v_late_max ", snappedf(r.v_late_kmh, 0.1))
	check(r.finite, "push: конечные числа")
	check(r.v_late_kmh <= 58.0, "полный от себя, газ 0: %.1f км/ч <= 58" % r.v_late_kmh)


## TowTug получает упор через TrikeRig.model_params.
func test_tow_tug_has_stop() -> void:
	var cfg := Config.get_config("tow_tug")
	var mp := TrikeRig.model_params(cfg, 300.0)
	check(mp.apparatus.has("strut_stop"), "model_params передаёт strut_stop")


func test_pull_travel_config() -> void:
	var arms: Dictionary = Config.get_config("trike_pilot").arms
	var pull := float(arms.shift_pull_m)
	check(absf(pull - 0.178) < 1e-9, "ход на себя игрока %.3f (v2, Q4 б: 0,178)" % pull)
	var cfg := Config.get_config("tow_tug")
	check(absf(float(cfg.cart.arms_shift_pull_m) - 0.1107) < 1e-9, "cart.arms_shift_pull_m не тронут")
	var g := Glider.new()
	g.setup_trike(cfg, 0.0, Config.get_config("trike_pilot"))
	check(absf(g.model.arms.shift_x_pull - pull) < 1e-9 and absf(g.model.arms.shift_x_pull_full - pull) < 1e-9, "Glider: ход применён")
	g.free()
