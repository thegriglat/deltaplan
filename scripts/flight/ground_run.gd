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
## Доля веса (пилот + крыло) на ногах N/W = clamp(1 − L_верт/W, 0, 1): 1 — стоит, крыло
## ничего не несёт; 0 — крыло несёт всё (отрыв). Предел «руки пилота» ∝ этой доле.
var feet_load: float = 1.0
## Кренящий момент ветра на крыло в руках (скольжение + несимметрия по размаху), Н·м, + вправо.
var wind_moment_nm: float = 0.0
## Предел удерживающего момента пилота сейчас: ground_bank.pilot_moment_max_nm · feet_load, Н·м.
var hold_limit_nm: float = 0.0

var _speed: float = 0.0  ## скорость вдоль склона по курсу, м/с
var _run_time: float = 0.0
var _ever_ran: bool = false
var _fail_timers: Dictionary = {}
var _yaw_rate: float = 0.0  ## рад/с, + вправо (по часовой)
var _bank_cmd: float = 0.0  ## заданный крен руки пилота на этом шаге, рад (из input.roll в _turn)
var _fresh: bool = true  ## первый шаг после reset: тангаж сразу установившийся (склон известен)


## Текст причины срыва взлёта для интерфейса.
static func failure_text(reason: String) -> String:
	match reason:
		"nose_high":
			return TranslationServer.translate("launch_fail_nose_high")
		"nose_low":
			return TranslationServer.translate("launch_fail_nose_low")
		"tailwind":
			return TranslationServer.translate("launch_fail_tailwind")
		"crosswind":
			return TranslationServer.translate("launch_fail_crosswind")
		"weak_run":
			return TranslationServer.translate("launch_fail_weak_run")
	return reason


func reset() -> void:
	phase = "standing"
	failure = ""
	_speed = 0.0
	_run_time = 0.0
	_ever_ran = false
	_fail_timers.clear()
	_yaw_rate = 0.0
	_fresh = true
	feet_load = 1.0
	wind_moment_nm = 0.0
	hold_limit_nm = 0.0


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
	var aero := _aero_force(m, dt, input, v_air, dir3)
	var weight := m.mass * Units.G
	feet_load = clampf(1.0 - aero.y / weight, 0.0, 1.0)
	_ground_bank(m, dt, v_air, air_fn)
	_move(m, dt, running, walk, slope_tan, dir3, aero)
	if gh > -INF:
		m.position.y = FlightModel.ground_height(ground_fn, m.position.x, m.position.z)

	if aero.y >= weight * float(to.liftoff_lift_fraction) and not m.stalled:
		return Result.TOOK_OFF
	if _check_failures(m, dt, running, v_air.length(), wind):
		return Result.FAILED
	return Result.NONE


## Поворот курса (К3 v3). Стоя и шагом — на месте от input.turn с pilot.walk.turn_rate_dps
## (крыло не кренит). На бегу — дугой от крена крыла. Пилот бежит по дуге заданного рукой крена
## φ_зад: a_зад = g·tgφ_зад (наклон в поворот вместе с крылом). Боковая сила крыла при крене φ
## тянет вбок: a_кр = (1 − N/W)·g·sinφ (L ≈ L_верт = (1 − N/W)·W); остальное дают ноги трением,
## но не больше, чем позволяет равновесие наклонённого бегуна с весом N на ногах: N/W·a_max
## (a_max = pilot.run.turn_accel_max_ms2 — предельный наклон тела). a = a_кр + clamp(a_зад − a_кр,
## ±N/W·a_max), |a| ≤ a_max, ω = a/v. Пока ноги нагружены, курс — от φ_зад, крен от ветра ноги
## перебарывают; к отрыву (N → 0) — от крена крыла, g·sinφ/v, как вираж в воздухе. На малой
## скорости угловая скорость не больше, чем при повороте на месте. input.turn на бегу не нужен.
func _turn(m: FlightModel, dt: float, input: ControlInput, running: bool) -> void:
	_bank_cmd = bank_command(m, input)  # для _ground_bank этого же шага
	var w_walk := Units.deg(float(m.pilot.walk.turn_rate_dps))
	if not running:
		_yaw_rate = clampf(input.turn, -1.0, 1.0) * w_walk
	else:
		var f := clampf(feet_load, 0.0, 1.0)
		var a_max := float(m.pilot.run.turn_accel_max_ms2)
		var a_cmd := clampf(Units.G * tan(_bank_cmd), -a_max, a_max)
		var a_wing := (1.0 - f) * Units.G * sin(m.bank)
		var legs := f * a_max
		var a := clampf(a_wing + clampf(a_cmd - a_wing, -legs, legs), -a_max, a_max)
		var v := absf(_speed)
		_yaw_rate = clampf(a / v, -w_walk, w_walk) if v > 1.0e-3 else 0.0
	m.heading += _yaw_rate * dt


## Аэродинамическая сила на крыло в руках пилота. dir3 — направление бега вдоль склона по курсу.
## Трапеция задаёт угол атаки — угол киля к набегающему потоку; пока потока нет (штиль, стоит),
## опорное направление — вдоль склона по курсу (поток, который встретит крыло на разбеге), а не
## горизонт: иначе стоя на склоне 20° нос задран на 20° выше, чем на первом шаге, и задние концы
## консолей уходят в склон (docs/flight.md → «Поза крыла на земле»).
func _aero_force(
	m: FlightModel, dt: float, input: ControlInput, v_air: Vector3, dir3: Vector3
) -> Vector3:
	var v := v_air.length()
	var min_v := float(m.flight.min_airspeed_ms)
	# ниже min_v поток плавно подменяется направлением бега (без скачка тангажа на min_v)
	var u := v_air + dir3 * maxf(min_v - v, 0.0)
	u = u.normalized() if u.length() > 1.0e-3 else dir3
	var side := u.cross(UP)
	side = side.normalized() if side.length() > 1.0e-3 else m.right_dir()
	var up0 := side.cross(u)
	var gamma := asin(clampf(u.y, -1.0, 1.0))
	var la: Dictionary = m.wing.launch
	var nose := (
		float(la.alpha_neutral_deg) + clampf(input.pitch, -1.0, 1.0) * float(la.alpha_range_deg)
	)
	var theta_target := gamma + Units.deg(nose)
	if _fresh:
		# FlightModel.reset_on_ground не знает склона — на первом шаге сразу поза стоя,
		# без переходного наклона от горизонта
		m.theta = theta_target
		_fresh = false
	m.theta += (theta_target - m.theta) * (1.0 - exp(-dt / m.tau_pitch))
	m.alpha = m.theta - gamma
	m.stalled = m.alpha > m.alpha_stall
	var c := m.aero_coefs(dt)
	var q := 0.5 * m.rho * v * v * m.area if v > min_v else 0.0
	return up0 * (q * c.x) - u * (q * c.y)


## Момент инерции крыла по крену относительно оси киля, кг·м²: конструкция — доля
## ground_bank.span_mass_fraction массы крыла, распределённая по размаху как стержень
## (m·b²/12; остальное — киль, мачта, трапеция у оси), плюс присоединённая масса воздуха
## пластины (π/4·ρ·c² на метр размаха, c = S/b): π/48·ρ·c²·b³.
static func roll_inertia(m: FlightModel) -> float:
	var gb: Dictionary = m.flight.ground_bank
	var b := m.span
	var c := m.area / b
	var i_struct := float(gb.span_mass_fraction) * float(m.wing.wing_mass_kg) * b * b / 12.0
	return i_struct + PI / 48.0 * m.rho * c * c * b * b * b


## Момент «руки пилота», Н·м: регулятор «пропорционально крену + демпфирование» к заданному
## крену (жёсткость I/τ², демпфирование 2I/τ — критическое, τ = ground_bank.pilot_response_s),
## ограниченный pilot_moment_max_nm · доля веса на ногах. bank — отклонение крена от заданного
## φ − φ_зад (К3 v3: φ_зад = input.roll · ground_bank.command_max_deg; без ввода — горизонт).
static func pilot_moment(
	m: FlightModel, bank: float, rate: float, load_frac: float, inertia: float
) -> float:
	var gb: Dictionary = m.flight.ground_bank
	var tau := float(gb.pilot_response_s)
	var want := -inertia / (tau * tau) * bank - 2.0 * inertia / tau * rate
	var lim := float(gb.pilot_moment_max_nm) * clampf(load_frac, 0.0, 1.0)
	return clampf(want, -lim, lim)


## Заданный крен руки пилота, рад: input.roll · ground_bank.command_max_deg.
static func bank_command(m: FlightModel, input: ControlInput) -> float:
	var gb: Dictionary = m.flight.ground_bank
	return clampf(input.roll, -1.0, 1.0) * Units.deg(float(gb.command_max_deg))


## Крен крыла на плечах: I·φ̈ = M_скольж + M_несимм + M_веса + M_инерц + M_пилота − D·φ̇.
## Крен — относительно горизонта (склон не влияет); рука пилота ведёт его к заданному
## bank_command (input.roll). Подробно — docs/flight.md.
func _ground_bank(m: FlightModel, dt: float, v_air: Vector3, air_fn: Callable) -> void:
	var gb: Dictionary = m.flight.ground_bank
	var inertia := roll_inertia(m)
	var fwd := m.heading_dir()
	var right := m.right_dir()
	var v := v_air.length()
	# скольжение: Cl = Clβ·½·sin2β (теория скольжения стреловидного крыла) ⇒ M = K·u·s,
	# u — встречная, s — боковая (воздух движется вправо, +) составляющие потока на крыло
	var u := v_air.dot(fwd)
	var s := -v_air.dot(right)
	var cl := clampf(
		float(m.wing.lift_slope_per_rad) * (m.alpha - Units.deg(float(m.wing.zero_lift_alpha_deg))),
		0.0,
		m.polar.cl_max
	)
	cl *= 1.0 - m.stall_amount()
	var clb := float(gb.slip_roll_per_cl) * cl
	var m_slip := 0.5 * m.rho * m.area * m.span * clb * u * s
	# аэродемпфирование по крену: C_lp = −CLα/8 (эллиптическая нагрузка);
	# D = ¼·ρ·V·S·b²·|C_lp|. Несимметрия вертикального ветра по размаху: M = D·Δw/b
	# (в воздухе то же даёт установившуюся угловую скорость Δw/b — FlightModel._update_roll)
	var damp := 0.25 * m.rho * v * m.area * m.span * m.span * float(m.wing.lift_slope_per_rad) / 8.0
	var m_asym := 0.0
	if air_fn.is_valid():
		var hub := m.position + UP * float(m.flight.takeoff.wing_height_m)
		var half := 0.5 * m.span * float(m.flight.air_sampling.tip_fraction)
		var w_l := FlightModel.sample_air(air_fn, hub - right * half).y
		var w_r := FlightModel.sample_air(air_fn, hub + right * half).y
		m_asym = damp * float(m.wing.air_roll_gain) * (w_l - w_r) / m.span
	wind_moment_nm = m_slip + m_asym
	# вес крыла: ЦТ выше оси вращения — опрокидывающий; центробежная сила на ЦТ крыла на дуге
	var h := float(gb.wing_cg_above_axis_m)
	var m_w := float(m.wing.wing_mass_kg)
	var m_grav := m_w * Units.G * h * sin(m.bank)
	var m_turn := -m_w * _speed * _yaw_rate * h * cos(m.bank)
	hold_limit_nm = float(gb.pilot_moment_max_nm) * feet_load
	var m_pilot := pilot_moment(m, m.bank - _bank_cmd, m.roll_rate, feet_load, inertia)
	var total := wind_moment_nm + m_grav + m_turn + m_pilot - damp * m.roll_rate
	m.roll_rate += total / inertia * dt
	m.bank += m.roll_rate * dt


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
		# v_cap — предел ног (частота и длина шага), а не всей системы: быстрее него ноги не
		# толкают и тормозят (та же линейная сила–скорость), но только опираясь на землю — через
		# долю веса на ногах. Склон и тяга крыла разгоняют и выше: под крутую горку разгружённое
		# крылом тело «несёт», пилот только перебирает ногами.
		var f_run := float(run_cfg.force_n) * (1.0 - _speed / v_cap)
		if f_run < 0.0:
			f_run *= feet_load
		var f_along := aero.dot(dir3) - weight * dir3.y
		_speed = maxf(_speed + (f_run + f_along) / m.mass * dt, 0.0)
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
	var check_alpha := _ever_ran and running and airspeed > float(to.check_min_airspeed_ms)
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
	elif _ever_ran and not running and _run_time > float(to.weak_run_min_time_s):
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
