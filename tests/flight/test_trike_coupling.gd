extends TestCase
## TKF-4 (TKF-К1 v2, docs/contracts/trike-fix.md): вид тележки дельталёта игрока без отставания от физики «Маятника».
## Сценарии, ввод, регулятор крена и формулы величин - из tools/research/trike-fix/coupling_run.gd (TKF-1): штиль,
## старт в воздухе 300 м, 80 км/ч, шаг 1/120 с, тяга по таблице configs/tow_tug.json напрямую (газ g).
## Инварианты: (1) yaw_rel_deg_vis <= 1 град; (2) vis_lag_deg_max <= 1 (виражи, перекладка) / 3 (push_full, pitch_pump,
## roll_pump); (3) mast_normal_deg_max_vis <= 20; (4) bar_deg_vis в [-10,7; push + 0,5] (TKF-К4 v2, во всех сценариях);
## (5) |roll_rel_deg_vis| <= 15; (6) колёса -> воздух: cart_basis непрерывен и через <= 0,6 с совпадает с C_phys (<= 0,5 град).
## Первая секунда после старта и 0,5 с после отрыва в (1)-(5) не учитываются. Длительности сокращены против инструмента.

const DT := 1.0 / 120.0
const BAR_WING := Vector3(0.0, 0.6793, -1.5287)  ## штанга trim в осях крыла от HangPoint (trapeze.json wing_frame_bar)
const BAR_TRIM := Vector2(0.72, 1.51)  ## (y, -z) в осях тележки: trike_params.json bar.trim
const SKIP_S := 1.0
const TAKEOFF_SKIP_S := 0.5

## Сценарий -> длительность, с
const DURATIONS := {
	"trim_full": 12.0, "push_full": 16.0, "pull_full": 16.0, "throttle_step": 20.0,
	"turn30_half": 16.0, "turn30_idle": 16.0, "turn45_half": 16.0, "turn45_idle": 16.0,
	"reversal45": 32.0, "roll_pump": 12.0, "pitch_pump": 14.0,
}

var _bank_i := 0.0
var _cfg: Dictionary


static func flat(_x: float, _z: float) -> float:
	return 0.0


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


## Регулятор крена: цель target_deg (+ вправо), ПИД (6; 2,5; 1).
func _bank_roll(m: PendulumModel, target_deg: float) -> float:
	var e := deg_to_rad(target_deg) - m.bank
	_bank_i = clampf(_bank_i + 1.0 * e * DT, -1.0, 1.0)
	return clampf(6.0 * e - 2.5 * m.roll_rate + _bank_i, -1.0, 1.0)


## [pitch, roll, газ 0..1]
func _inputs(name: String, t: float, m: PendulumModel) -> Array:
	match name:
		"trim_full":
			return [0.0, 0.0, 1.0]
		"push_full":
			return [1.0 if t < 10.0 else 0.0, 0.0, 1.0]
		"pull_full":
			return [-1.0 if t < 10.0 else 0.0, 0.0, 1.0]
		"throttle_step":
			return [0.0, 0.0, 1.0 if (t >= 5.0 and t < 10.0) else 0.0]
		"turn30_half", "turn30_idle", "turn45_half", "turn45_idle":
			var tgt := 30.0 if name.begins_with("turn30") else 45.0
			var gk := 0.5 if name.ends_with("half") else 0.0
			return [0.0, _bank_roll(m, tgt * clampf((t - 2.0) / 3.0, 0.0, 1.0)), gk]
		"reversal45":
			var tg := 0.0
			if t >= 2.0 and t < 12.0:
				tg = 45.0
			elif t >= 12.0 and t < 22.0:
				tg = -45.0
			elif t >= 22.0:
				tg = 45.0
			return [0.0, _bank_roll(m, tg), 0.5]
		"roll_pump":
			return [0.0, 1.0 if int(floor(t / 2.0)) % 2 == 0 else -1.0, 1.0]
		"pitch_pump":
			var per := 2.6
			return [1.0 if fmod(t, per) < per * 0.5 else -1.0, 0.0, 1.0]
	return [0.0, 0.0, 0.0]


## Величины вида (vis) и физики (phys) в один момент.
func _vals(rig: TrikeRig, c: Basis, w: Basis, ang_trim: float) -> Dictionary:
	var bw: Vector3 = c.transposed() * (w * BAR_WING)
	var yw: Vector3 = c.transposed() * w.y
	var mast: Vector3 = (-(c * TrikeRig.CART_CM_MODEL)).normalized()
	var kf: Vector3 = -w.z
	var pr := (kf - mast * kf.dot(mast)).normalized()
	return {
		"bar": rad_to_deg(atan2(bw.y, -bw.z) - ang_trim),
		"roll_rel": -rad_to_deg(atan2(yw.x, yw.y)),
		"yaw_rel": rad_to_deg(atan2(pr.dot(c.x), pr.dot(-c.z))),
		"mast_normal": rad_to_deg(mast.angle_to(w.y)),
	}


## -> {yaw_abs, roll_abs, mast_max, bar_min, bar_max, vis_lag_max}, градусы, после SKIP_S.
func _run(name: String) -> Dictionary:
	_cfg = Config.get_config("tow_tug")
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	g.reset_in_air(Vector3(0.0, 300.0, 0.0), 0.0, 80.0 / 3.6)
	var rig := g.trike
	rig.refresh(0.0)
	_bank_i = 0.0
	var ctl := ControlInput.new()
	var ang_trim := atan2(BAR_TRIM.x, BAR_TRIM.y)
	var r := {"yaw_abs": 0.0, "roll_abs": 0.0, "mast_max": 0.0, "bar_min": INF, "bar_max": -INF, "vis_lag_max": 0.0, "finite": true}
	for i in int(round(float(DURATIONS[name]) / DT)):
		var t := i * DT
		var u := _inputs(name, t, g.model)
		ctl.pitch = u[0]
		ctl.roll = u[1]
		rig.thrust_n = _thrust(g.model.telemetry.airspeed, u[2])
		g.model.step(DT, ctl, Callable(), Callable(flat))
		rig.refresh(DT)
		if t < SKIP_S:
			continue
		var w := rig.wing_basis
		var cp := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, w, false)
		var v := _vals(rig, rig.cart_basis, w, ang_trim)
		r.yaw_abs = maxf(r.yaw_abs, absf(v.yaw_rel))
		r.roll_abs = maxf(r.roll_abs, absf(v.roll_rel))
		r.mast_max = maxf(r.mast_max, v.mast_normal)
		r.bar_min = minf(r.bar_min, v.bar)
		r.bar_max = maxf(r.bar_max, v.bar)
		var lag := rad_to_deg(rig.cart_basis.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion()))
		r.vis_lag_max = maxf(r.vis_lag_max, lag)
		if not (is_finite(v.yaw_rel) and is_finite(v.bar) and is_finite(lag)):
			r.finite = false
	g.free()
	return r


func _limits() -> Dictionary:
	var tp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
	# «на себя» - ответ Q4 (б), TKF-К4 v2: ход 0,178 м доходит до груди (bar_deg -10,29, strut.md) вместо предела TT-К6 -8,39
	return {"push": float(tp.bar.push_deg), "pull": 10.29 + 0.4}


func _check_scenarios(names: Array, lag_max: float, bar_checked := true) -> void:
	var lim := _limits()
	for n: String in names:
		var r := _run(n)
		check(r.finite, "%s: не конечны величины" % n)
		check(r.yaw_abs <= 1.0, "%s: yaw_rel_deg_vis %.2f > 1" % [n, r.yaw_abs])
		check(r.vis_lag_max <= lag_max, "%s: vis_lag_deg_max %.2f > %.1f" % [n, r.vis_lag_max, lag_max])
		check(r.mast_max <= 20.0, "%s: mast_normal_deg_max_vis %.2f > 20" % [n, r.mast_max])
		check(r.roll_abs <= 15.0, "%s: |roll_rel_deg_vis| %.2f > 15" % [n, r.roll_abs])
		if bar_checked:
			check(r.bar_min >= -float(lim.pull) and r.bar_max <= float(lim.push) + 0.5,
				"%s: bar_deg_vis [%.2f; %.2f] вне [-%.2f; %.2f]" % [n, r.bar_min, r.bar_max, lim.pull, float(lim.push) + 0.5])


func test_turns_follow_physics() -> void:
	_check_scenarios(["turn30_half", "turn30_idle", "turn45_half", "turn45_idle", "reversal45"], 1.0)


func test_straight_and_throttle() -> void:
	_check_scenarios(["trim_full", "throttle_step"], 3.0)
	_check_scenarios(["pull_full"], 3.0)


func test_pumps() -> void:
	_check_scenarios(["roll_pump"], 3.0)
	# TKF-К1 v2 (7): упор подкоса в физике (TKF-К4) - штанга не выходит за упор и в push_full, pitch_pump
	_check_scenarios(["push_full", "pitch_pump"], 3.0)


## (6) Разбег, отрыв: cart_basis непрерывен, после отрыва за <= 0,6 с совпадает с C_phys.
func test_takeoff_continuity() -> void:
	_cfg = Config.get_config("tow_tug")
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(_cfg, 0.0, Config.get_config("trike_pilot"))
	g.reset_on_wheels(Vector3.ZERO, 0.0)
	var rig := g.trike
	var model: PendulumModel = g.model
	var t := 0.0
	var t_air := -1.0  ## начало текущего полёта без касаний колёс
	var max_over := 0.0
	var jump := 0.0
	var settled := false
	var prev := rig.cart_basis
	var prev_cp := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, model.on_wheels)
	for k in int(120.0 / DT):
		var c := ControlInput.new()
		if t < 0.2:
			c.engine_toggle = true
		if t > 2.0:
			c.throttle_axis = 1.0
		var v := g.get_telemetry().airspeed
		if g.phase() == "wheels" and v > 14.0:
			c.pitch = 0.3  # штанга от себя - тележка на колёсах до отрыва
		g.control = c
		g.step(DT)
		t += DT
		var cp := rig._cart_model_basis(rig.pilot_pos, rig.hang_pos, rig.wing_basis, model.on_wheels)
		var step := rad_to_deg(prev.get_rotation_quaternion().angle_to(rig.cart_basis.get_rotation_quaternion()))
		var cp_step := rad_to_deg(prev_cp.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion()))
		prev = rig.cart_basis
		prev_cp = cp
		# за шаг: не больше предела гашения скачка плюс собственный поворот цели (физика) за этот шаг
		max_over = maxf(max_over, step - cp_step)
		if model.on_wheels:
			t_air = -1.0  # подскок на колёсах: отсчёт сначала
			continue
		if t_air < 0.0:
			t_air = t
			jump = maxf(jump, rad_to_deg(rig.cart_basis.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion())))
		if t - t_air >= 0.6:
			var lag := rad_to_deg(rig.cart_basis.get_rotation_quaternion().angle_to(cp.get_rotation_quaternion()))
			check(lag <= 0.5, "через 0,6 с непрерывного полёта вид отстаёт от физики на %.2f град" % lag)
			settled = true
			break
	check(t_air > 0.0, "отрыв не случился за 120 с")
	check(settled, "не дошли до 0,6 с после отрыва")
	var limit := TrikeRig.CART_TURN_DEG_S * DT + 0.05  # + второй порядок: смещение в осях цели при её повороте
	check(max_over <= limit, "cart_basis за шаг повернулся сверх цели на %.3f град (> %.3f)" % [max_over, limit])
	check(jump <= 20.0, "скачок на отрыве %.2f град (ожидается ~16,3 после исправления знака z ЦМ тележки: было ~8,5; непрерывно)" % jump)
	g.free()
