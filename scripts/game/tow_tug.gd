class_name TowTug
extends RefCounted
## Буксировщик аэробуксировки - дельталёт (TT-К4 v1, docs/contracts/tow-trike.md; заменяет TW-К9 v3).
##
## Модель полёта, не кинематика: внутри PendulumModel с крылом trike_ixess15 (TT-К2) и тележкой (TT-К1: масса,
## cg_below_hang_m, cda_m2, arms_force_max_n), старт на колёсах (TT-К3). Тяга винта T(V, газ) и сила троса идут через
## set_external_force (TW-К4): тяга - на тележку вдоль её продольной оси с наклоном engine.thrust_tilt_deg, трос - в точку
## tow_hook (на тележке или на подвеске, cart.tow_hook_on). Автопилот по фазам: ПИ по скорости -> штанга, ПД по крену -> roll,
## газ по фазам. Набор - результат физики (тяга, сопротивление, натяжение), не задаётся.
##
## ГРАНИЦЫ МОДЕЛИ: тележка - точечная масса, момента от троса вокруг ЦМ тележки нет (трос тянет ЦМ, точка tow_hook нужна
## для позиции конца троса); винт не обдувает крыло и пилота, реактивного момента и гироскопики нет; тяга - таблица по V и
## газу (расчётная, не измеренная); на холостых (idle) тележка на тормозе (холостая тяга её не катит); посадки на колёса
## нет - после отцепа буксировщик уходит и его убирают через away.away_s; руки пилота (предел arms_force_max_n) держат
## штангу; воздух - только air_fn (ветер), плотность и порывы - как у PendulumModel.
##
## Мир игры: X восток, Y вверх, -Z север; курс - от севера по часовой, вперёд = (sin h, 0, -cos h).
## API: setup(runway_start, heading_deg, rope_length_m, terrain_height: Callable(x, z) -> float, cfg := {}),
##   set_air(fn), start() (по W), set_rope_force(f: Vector3) (Н, мир; каждый шаг), release(), step(dt, glider_height_agl_m).
## Чтение: pos (точка tow_hook), vel, hang_pos, wing_basis, cart_basis, basis (= cart_basis), phase: idle / slack / roll /
## climb / circuit / away; agl_m (низ колёс над землёй), gone, throttle, prop_rpm, airspeed_ms, model.

const WING_DEFAULT := "trike_ixess15"

var pos := Vector3.ZERO  ## точка tow_hook в мире - конец троса
var vel := Vector3.ZERO  ## её скорость
var hang_pos := Vector3.ZERO  ## точка подвески (начало trike.glb)
var wing_basis := Basis.IDENTITY
var cart_basis := Basis.IDENTITY  ## +Y - от ЦМ тележки к подвеске, -Z - продольная ось вперёд
var basis := Basis.IDENTITY
var phase := "idle"
var agl_m := 0.0
var gone := false
var throttle := 0.0
var prop_rpm := 0.0
var airspeed_ms := 0.0
var model: PendulumModel

var _cfg: Dictionary = {}
var _terrain: Callable
var _air_fn: Callable
var _hook := Vector3.ZERO
var _rope_force := Vector3.ZERO
var _thrust_n := 0.0
var _thr_cmd := 0.0
var _heading_ref := 0.0  ## курс полосы, рад
var _hdg_tgt := 0.0
var _bar_i := 0.0  ## интеграл ПИ по скорости (штанга)
var _thr_i := 0.0  ## интеграл газа (выбор слабины / ограничение набора)
var _vz_f := 0.0  ## сглаженная вертикальная скорость
var _vdot_f := 0.0  ## сглаженное ускорение воздушной скорости
var _away_t := 0.0
var _rotating := false
var _prev_pos := Vector3.ZERO


func setup(
	runway_start: Vector3, heading_deg: float, rope_length_m: float, terrain_height: Callable, cfg: Dictionary = {}
) -> void:
	_cfg = cfg if not cfg.is_empty() else Config.get_config("tow_tug")
	_terrain = terrain_height if terrain_height.is_valid() else func(_x: float, _z: float) -> float: return 0.0
	var cart: Dictionary = _cfg.cart
	var wing: Dictionary = Config.get_config("wings/" + String(_cfg.get("wing", WING_DEFAULT))).duplicate(true)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(cart.mass_kg)
	var app := {
		"hang_length_m": float(cart.cg_below_hang_m),
		"pilot_cda_m2": float(cart.cda_m2),
		"arms_force_max_n": float(cart.arms_force_max_n),
	}
	model = PendulumModel.new()
	model.setup(wing, pilot, {}, app)
	# ход штанги в треугольнике тележки (TT-8, trapeze.json): штатные 0,3 / 0,45 м не помещаются
	model.arms.shift_x_push = float(cart.arms_shift_push_m)
	model.arms.shift_x_pull = float(cart.arms_shift_pull_m)
	model.arms.shift_x_pull_full = float(cart.arms_shift_pull_m)
	var h := deg_to_rad(heading_deg)
	_heading_ref = h
	_hdg_tgt = h
	var hk: Array = cart.tow_hook
	_hook = Vector3(float(hk[0]), float(hk[1]), float(hk[2]))
	var target := runway_start + _fwd(h) * rope_length_m
	# тележка на оси полосы так, чтобы tow_hook стоял на длину троса впереди начала: два прохода по поправке
	var p := target
	for _i in 2:
		model.reset_on_wheels(Vector3(p.x, _ground(p.x, p.z), p.z), heading_deg, _cfg.ground)
		model.set_external_force(_ext_force)
		_refresh(0.0)
		p += Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	vel = Vector3.ZERO
	_prev_pos = pos
	phase = "idle"
	gone = false
	throttle = 0.0
	_thr_cmd = 0.0
	prop_rpm = float(_cfg.engine.prop_rpm_idle)
	airspeed_ms = 0.0
	_rope_force = Vector3.ZERO
	_thrust_n = 0.0
	_bar_i = float(_ap("bar_i_init_m"))
	_thr_i = 0.0
	_vz_f = 0.0
	_away_t = 0.0
	_rotating = false


func set_air(fn: Callable) -> void:
	_air_fn = fn


func start() -> void:
	if phase == "idle":
		phase = "slack"


## Сила троса на буксировщик (Н, мир игры): tension_n * (точка крепления на дельтаплане - pos).normalized().
func set_rope_force(f: Vector3) -> void:
	_rope_force = f if (is_finite(f.x) and is_finite(f.y) and is_finite(f.z)) else Vector3.ZERO


func release() -> void:
	if phase != "away":
		phase = "away"
		_away_t = 0.0
		_hdg_tgt = model.heading
		_rope_force = Vector3.ZERO


func step(dt: float, glider_height_agl_m: float) -> void:
	if dt <= 0.0 or phase == "idle" or gone:
		return
	var tow: Dictionary = _cfg.tow
	var v_tow := float(tow.tow_speed_kmh) / 3.6
	var in_air := not model.on_wheels
	var v_new := (model.pilot_velocity - _wind(model.pilot_position)).length()
	_vdot_f += ((v_new - airspeed_ms) / dt - _vdot_f) * minf(dt / maxf(float(_ap("vdot_filter_s")), dt), 1.0)
	airspeed_ms = v_new
	var ctl := ControlInput.new()
	var hz := Vector3(model.pilot_velocity.x, 0.0, model.pilot_velocity.z)
	_vz_f += (model.pilot_velocity.y - _vz_f) * minf(dt / maxf(float(_ap("vz_filter_s")), dt), 1.0)
	match phase:
		"slack":
			_thr_cmd = _speed_throttle(float(tow.slack_speed_ms), hz.length(), dt)
			if _rope_force.length() > 0.0:
				phase = "roll"
		"roll":
			# пока дельтаплан не поднялся - скорость ниже скорости отрыва тележки (штангой на колёсах прижать нельзя),
			# дельтаплан поднялся - полный газ, и на скорости отрыва штанга отдаётся
			var lifted := glider_height_agl_m >= float(tow.glider_hold_agl_m)
			if lifted:
				_thr_cmd = 1.0
			else:
				_thr_cmd = _speed_throttle(float(tow.rotate_speed_kmh) / 3.6 * float(_ap("roll_hold_frac")), airspeed_ms + float(_ap("roll_hold_lead_s")) * _vdot_f, dt, "roll_hold")
			if lifted and airspeed_ms >= float(tow.rotate_speed_kmh) / 3.6:
				_rotating = true
			ctl.pitch = float(_ap("rotate_bar")) if _rotating else 0.0
			if in_air:
				phase = "climb"
				_hdg_tgt = _heading_ref
				_bar_i = float(_ap("bar_i_init_m"))
		"climb", "circuit":
			if phase == "climb" and agl_m >= float(tow.circuit_start_agl_m):
				phase = "circuit"
			ctl.pitch = _bar(v_tow, dt)
			_thr_cmd = _climb_throttle(dt)
		"away":
			_away_t += dt
			var aw: Dictionary = _cfg.away
			_thr_cmd = float(aw.throttle)
			if in_air:
				ctl.pitch = _bar(v_tow, dt)
			var turn := deg_to_rad(float(aw.turn_deg))
			if turn != 0.0 and _away_t < float(aw.turn_s):
				_hdg_tgt -= turn / float(aw.turn_s) * dt
			if _away_t >= float(aw.away_s):
				gone = true
	# газ - с ограничением скорости изменения
	var rate := (float(_ap("throttle_rate_per_s")) if in_air else float(_ap("throttle_rate_ground_per_s"))) * dt
	throttle = clampf(clampf(_thr_cmd, throttle - rate, throttle + rate), 0.0, 1.0)
	if in_air:
		ctl.roll = _roll_cmd(phase)
	_update_thrust()
	model.step(dt, ctl, _air_fn, _terrain)
	_refresh(dt)


## ПИД по воздушной скорости -> ход штанги u (м от нуля ввода, + от себя), далее в pitch ControlInput: ход вперёд и
## назад в треугольнике тележки разный (arms_shift_push_m / arms_shift_pull_m), поэтому pitch = u / соответствующий ход.
## Скорость ниже цели -> штанга на себя (u < 0). D-составляющая по ускорению скорости демпфирует фугоиду (без неё обмен
## скорости на высоту не затухает).
func _bar(v_tow: float, dt: float) -> float:
	var e := airspeed_ms - v_tow
	var u_min := float(_ap("bar_min_m"))
	var u_max := float(_ap("bar_max_m"))
	_bar_i = clampf(_bar_i + float(_ap("bar_ki")) * e * dt, u_min, u_max)
	var u := clampf(_bar_i + float(_ap("bar_kp")) * e + float(_ap("bar_kd")) * _vdot_f, u_min, u_max)
	var cart: Dictionary = _cfg.cart
	return clampf(u / float(cart.arms_shift_push_m) if u >= 0.0 else u / float(cart.arms_shift_pull_m), -1.0, 1.0)


## Газ в наборе: до power_reduce_agl_m полный, выше - ПИ так, чтобы вертикальная скорость не превышала climb_limit_ms.
func _climb_throttle(dt: float) -> float:
	var tow: Dictionary = _cfg.tow
	if agl_m < float(tow.power_reduce_agl_m):
		_thr_i = 1.0
		return 1.0
	var e := float(tow.climb_limit_ms) - _vz_f
	var lo := float(_ap("throttle_min_climb"))
	_thr_i = clampf(_thr_i + float(_ap("climb_throttle_ki")) * e * dt, lo, 1.0)
	return clampf(_thr_i + float(_ap("climb_throttle_kp")) * minf(e, 0.0), lo, 1.0)


## Газ для скорости по земле (выбор слабины): ПИ.
func _speed_throttle(v_goal: float, v: float, dt: float, gains := "slack") -> float:
	var e := v_goal - v
	_thr_i = clampf(_thr_i + float(_ap(gains + "_ki")) * e * dt, 0.0, 1.0)
	return clampf(_thr_i + float(_ap(gains + "_kp")) * e, 0.0, 1.0)


## ПД по крену: цель - от ошибки курса (climb, away), в circuit - circuit_bank_deg влево.
func _roll_cmd(ph: String) -> float:
	var tgt := 0.0
	if ph == "circuit":
		tgt = -deg_to_rad(float(_cfg.tow.circuit_bank_deg))
	else:
		var he := wrapf(_hdg_tgt - model.heading, -PI, PI)
		var lim := deg_to_rad(float(_ap("heading_bank_max_deg")))
		tgt = clampf(float(_ap("heading_kp")) * he, -lim, lim)
	var u := float(_ap("roll_kp")) * (tgt - model.bank) - float(_ap("roll_kd")) * model.roll_rate
	return clampf(u, -1.0, 1.0)


func _ap(key: String) -> Variant:
	return _cfg.autopilot[key]


func _wind(p: Vector3) -> Vector3:
	return _air_fn.call(p) as Vector3 if _air_fn.is_valid() else Vector3.ZERO


func _ground(x: float, z: float) -> float:
	return float(_terrain.call(x, z))


static func _fwd(h: float) -> Vector3:
	return Vector3(sin(h), 0.0, -cos(h))


## Линейная интерполяция по таблице thrust (вне таблицы - крайние значения).
func _table(key: String, v: float) -> float:
	var th: Dictionary = _cfg.thrust
	var vs: Array = th.v_ms
	var ys: Array = th[key]
	if v <= float(vs[0]):
		return float(ys[0])
	for i in range(1, vs.size()):
		if v <= float(vs[i]):
			var k := (v - float(vs[i - 1])) / (float(vs[i]) - float(vs[i - 1]))
			return lerpf(float(ys[i - 1]), float(ys[i]), k)
	return float(ys[ys.size() - 1])


func _update_thrust() -> void:
	var idle_rpm := float(_cfg.engine.prop_rpm_idle)
	if phase == "idle":
		_thrust_n = 0.0
		prop_rpm = idle_rpm
		return
	var idle_n := _table("idle_n", airspeed_ms)
	_thrust_n = idle_n + throttle * (_table("full_n", airspeed_ms) - idle_n)
	prop_rpm = idle_rpm + throttle * (_table("rpm_full", airspeed_ms) - idle_rpm)


## Внешняя сила модели (подшаг 480 Гц): тяга на тележку вдоль продольной оси, трос - на тележку или подвеску.
func _ext_force(s: Dictionary) -> Dictionary:
	var cb := _cart_axes(s.pilot_pos, s.hang_pos, s.wing_basis)
	var tilt := deg_to_rad(float(_cfg.engine.thrust_tilt_deg))
	var dir := -cb.z * cos(tilt) + cb.y * sin(tilt)
	var out := {}
	var f_p: Vector3 = dir * _thrust_n
	if String(_cfg.cart.tow_hook_on) == "hang":
		out["hang"] = _rope_force
	else:
		f_p += _rope_force
	out["pilot"] = f_p
	return out


## Оси тележки: +Y от ЦМ тележки к подвеске, -Z - курс крыла, ортогонализованный к мачте.
static func _cart_axes(pilot_p: Vector3, hang_p: Vector3, wb: Basis) -> Basis:
	var y := (hang_p - pilot_p).normalized()
	var f: Vector3 = -wb.z
	f = (f - y * f.dot(y)).normalized()
	var z := -f
	return Basis(y.cross(z), y, z)


func _refresh(dt: float) -> void:
	hang_pos = model.hang_position
	wing_basis = model.wing_basis()
	cart_basis = _cart_axes(model.pilot_position, hang_pos, wing_basis)
	basis = cart_basis
	var np := hang_pos + cart_basis * _hook
	if dt > 0.0:
		vel = (np - _prev_pos) / dt
	pos = np
	_prev_pos = np
	var pp := model.pilot_position
	agl_m = maxf(pp.y - float(_cfg.ground.wheel_base_agl_m) - _ground(pp.x, pp.z), 0.0)
