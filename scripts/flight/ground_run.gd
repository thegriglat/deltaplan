class_name GroundRun
extends RefCounted
## Пилот на земле (FR-9): стоит, ходит с крылом на плечах или разбегается со склона.
##
## Шагает состояние FlightModel, пока тот в режиме GROUND. Трапеция задаёт угол носа
## относительно набегающего потока, подъёмная сила разгружает ноги; отрыв — когда
## вертикальная составляющая подъёмной силы ≥ веса. Ошибки разбега срывают взлёт.

enum Result { NONE, TOOK_OFF, FAILED }

const UP := Vector3.UP

## "standing", "walking", "running".
var phase: String = "standing"
## Причина срыва: "nose_high", "nose_low", "tailwind", "crosswind", "weak_run" или "".
var failure: String = ""

var _speed: float = 0.0  ## скорость вдоль склона по курсу, м/с
var _run_time: float = 0.0
var _ever_ran: bool = false
var _fail_timers: Dictionary = {}


## Текст причины срыва взлёта для интерфейса.
static func failure_text(reason: String) -> String:
	match reason:
		"nose_high":
			return TranslationServer.translate("Нос слишком высоко — крыло сорвало поток")
		"nose_low":
			return TranslationServer.translate("Нос слишком низко — крыло зарылось")
		"tailwind":
			return TranslationServer.translate("Попутный ветер — не набрать воздушную скорость")
		"crosswind":
			return TranslationServer.translate("Боковой ветер завалил крыло")
		"weak_run":
			return TranslationServer.translate("Слабый разбег — крыло не набрало скорость")
	return reason


func reset() -> void:
	phase = "standing"
	failure = ""
	_speed = 0.0
	_run_time = 0.0
	_ever_ran = false
	_fail_timers.clear()


## Один шаг на земле; меняет положение, курс, крен и тангаж модели m.
func step(
	m: FlightModel, dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable
) -> Result:
	var to: Dictionary = m.flight.takeoff
	var gh := FlightModel.ground_height(ground_fn, m.position.x, m.position.z)
	if gh > -INF:
		m.position.y = gh
	m.rho = m.air_density(m.position.y)
	var running := input.run
	var walk := 0.0 if running else clampf(input.walk, -1.0, 1.0)
	phase = "running" if running else ("walking" if absf(walk) > 0.01 else "standing")

	_turn(m, dt, input, running)
	var fwd := m.heading_dir()
	var d := float(to.slope_sample_m)
	var slope_tan := 0.0
	if gh > -INF:
		var ahead := m.position + fwd * d
		slope_tan = (FlightModel.ground_height(ground_fn, ahead.x, ahead.z) - gh) / d
	var dir3 := (fwd + UP * slope_tan).normalized()
	var wind := FlightModel.sample_air(air_fn, m.position + UP * float(to.wing_height_m))

	var v_air := dir3 * _speed - wind
	var aero := _aero_force(m, dt, input, v_air)
	var weight := m.mass * Units.G
	_ground_bank(m, dt, input, wind)
	_move(m, dt, running, walk, slope_tan, dir3, aero)
	if gh > -INF:
		m.position.y = FlightModel.ground_height(ground_fn, m.position.x, m.position.z)

	if aero.y >= weight * float(to.liftoff_lift_fraction) and not m.stalled:
		return Result.TOOK_OFF
	if _ever_ran and _check_failures(m, dt, running, v_air.length(), wind):
		return Result.FAILED
	return Result.NONE


## Поворот: на месте при ходьбе или подруливание на разбеге.
func _turn(m: FlightModel, dt: float, input: ControlInput, running: bool) -> void:
	var run_cfg: Dictionary = m.pilot.run
	var walk_cfg: Dictionary = m.pilot.walk
	var dps := float(run_cfg.ground_turn_rate_dps) if running else float(walk_cfg.turn_rate_dps)
	m.heading += clampf(input.roll, -1.0, 1.0) * Units.deg(dps) * dt


## Аэродинамическая сила на крыло в руках пилота.
func _aero_force(m: FlightModel, dt: float, input: ControlInput, v_air: Vector3) -> Vector3:
	var v := v_air.length()
	var min_v := float(m.flight.min_airspeed_ms)
	var u := v_air / v if v > min_v else m.heading_dir()
	var side := u.cross(UP)
	side = side.normalized() if side.length() > 1.0e-3 else m.right_dir()
	var up0 := side.cross(u)
	var gamma := asin(clampf(u.y, -1.0, 1.0))
	var la: Dictionary = m.wing.launch
	var nose := (
		float(la.alpha_neutral_deg) + clampf(input.pitch, -1.0, 1.0) * float(la.alpha_range_deg)
	)
	m.theta += (gamma + Units.deg(nose) - m.theta) * (1.0 - exp(-dt / m.tau_pitch))
	m.alpha = m.theta - gamma
	m.stalled = m.alpha > m.alpha_stall
	var c := m.aero_coefs(dt)
	var q := 0.5 * m.rho * v * v * m.area if v > min_v else 0.0
	return up0 * (q * c.x) - u * (q * c.y)


## Крен крыла в руках: боковой ветер поднимает наветренную консоль, пилот выравнивает.
func _ground_bank(m: FlightModel, dt: float, input: ControlInput, wind: Vector3) -> void:
	var gb: Dictionary = m.flight.ground_bank
	var crosswind := wind.dot(m.right_dir())  # + воздух движется вправо (ветер слева)
	var rate := Units.deg(float(gb.crosswind_roll_dps_per_ms)) * crosswind
	rate += clampf(input.roll, -1.0, 1.0) * Units.deg(float(gb.pilot_roll_rate_dps))
	rate -= m.bank / float(gb.level_time_s)
	m.bank += rate * dt


## Движение вдоль склона: разбег (сила ног + склон + аэродинамика) или ходьба.
func _move(
	m: FlightModel,
	dt: float,
	running: bool,
	walk: float,
	slope_tan: float,
	dir3: Vector3,
	aero: Vector3
) -> void:
	var run_cfg: Dictionary = m.pilot.run
	var walk_cfg: Dictionary = m.pilot.walk
	var weight := m.mass * Units.G
	if running:
		_ever_ran = true
		_run_time += dt
		var unload := clampf(aero.y / weight, 0.0, 1.0)
		var bonus := float(run_cfg.unload_speed_bonus) * unload
		var v_cap := float(run_cfg.speed_max_ms) * (1.0 + bonus)
		var f_run := float(run_cfg.force_n) * (1.0 - _speed / v_cap)
		var f_along := aero.dot(dir3) - weight * dir3.y
		_speed = clampf(_speed + (f_run + f_along) / m.mass * dt, 0.0, v_cap)
	else:
		var slope_factor := clampf(
			1.0 - absf(slope_tan) / float(walk_cfg.max_slope_tan),
			float(walk_cfg.min_slope_factor),
			1.0
		)
		var step_speed := float(walk_cfg.speed_ms) if walk >= 0.0 else float(walk_cfg.back_speed_ms)
		var target := walk * slope_factor * step_speed
		_speed = move_toward(_speed, target, float(run_cfg.stop_decel_ms2) * dt)
	m.velocity = dir3 * _speed
	m.position += m.velocity * dt


## Ошибки разбега; true — взлёт сорван (failure заполнен).
func _check_failures(
	m: FlightModel, dt: float, running: bool, airspeed: float, wind: Vector3
) -> bool:
	var to: Dictionary = m.flight.takeoff
	var gb: Dictionary = m.flight.ground_bank
	var tailwind := wind.dot(m.heading_dir())
	var check_alpha := running and airspeed > float(to.check_min_airspeed_ms)
	var high := m.alpha > m.alpha_stall + Units.deg(float(to.nose_high_margin_deg))
	var low := m.alpha < Units.deg(float(to.nose_low_alpha_deg))
	var fail_time := float(to.fail_time_s)
	if _timer("nose_high", check_alpha and high, dt) > fail_time:
		failure = "nose_high"
	elif _timer("nose_low", check_alpha and low, dt) > fail_time:
		failure = "nose_low"
	elif _timer("tailwind", running and tailwind > float(to.tailwind_max_ms), dt) > fail_time:
		failure = "tailwind"
	elif _timer("crosswind", absf(m.bank) > Units.deg(float(gb.fail_bank_deg)), dt) > fail_time:
		failure = "crosswind"
	elif not running and _run_time > float(to.weak_run_min_time_s):
		failure = "weak_run"
	elif _run_time > float(to.max_run_time_s):
		failure = "weak_run"
	if failure != "":
		_speed = 0.0
		return true
	return false


func _timer(reason: String, cond: bool, dt: float) -> float:
	var t: float = (_fail_timers.get(reason, 0.0) + dt) if cond else 0.0
	_fail_timers[reason] = t
	return t
