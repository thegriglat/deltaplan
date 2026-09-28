class_name BotAgent
extends RefCounted
## Один бот «других пилотов в небе» (BotPilots): своя FlightModel (та же точечная масса по поляре
## и тот же воздух), управление — как у пилота: на земле ходьба и разбег (ControlInput walk/run,
## нос крыла — как у игрока: run_nose_neutral + LaunchNose по ветру), в полёте — WanderPilot
## (BotPilot без маршрута).
## Узлов не держит: визуал (BotGlider) только повторяет состояние — поэтому тестируется headless.
##
## Жизнь: WAIT (стоит на месте ожидания с крылом) → WALK (подход к старту игрока; пока
## предыдущий не побежал — ждёт в стороне, queue_hold) → READY (стоит на старте по курсу) →
## RUN (разбег) → FLY (склон / термики / перелёты — сколько продержится) → LANDED (коснулся
## земли или сел в лес: стоит минуту, потом BotPilots убирает его и ставит снова в очередь
## на старт). Взлёт сорван — снова на старт.

enum State { WAIT, WALK, READY, RUN, FLY, LANDED }

const STATE_NAMES: Array[String] = ["wait", "walk", "ready", "run", "fly", "landed"]

var id: int = 0
var model := FlightModel.new()
var control := ControlInput.new()
var brain := WanderPilot.new()
var state: State = State.WAIT
var wing_id: String = ""
var mass_kg: float = 0.0
## Имя над ботом (BotPilots из configs/bot_names.json по языку; на весь полёт).
var pilot_name: String = ""
## Расцветка паруса: {name, hue_deg, sat, value} (bots.json → visual.sail_schemes).
var scheme: Dictionary = {}
## Место ожидания и курс там.
var spot: Vector3 = Vector3.ZERO
var spot_heading: float = 0.0
## Время начала разбега по расписанию (время BotPilots), с; INF — ещё не назначено.
var run_at_s: float = INF
## Когда начал разбег / оторвался (время BotPilots), с; < 0 — ещё нет.
var run_start_s: float = -1.0
var liftoff_s: float = -1.0
## Сколько раз срывался взлёт.
var failed_runs: int = 0
## Накопленное время до следующего шага физики (BotPilots шагает ботов реже игрока), с.
var acc_s: float = 0.0
## Когда коснулся земли (время BotPilots), с.
var landed_s: float = -1.0
## Предыдущий в очереди ещё не побежал — ждать в стороне от старта (BotPilots).
var queue_hold: bool = true

var _cfg: Dictionary = {}
var _air_fn: Callable
var _ground_fn: Callable
var _launch_pos := Vector3.ZERO
var _launch_heading := 0.0
var _home := Vector2.ZERO
var _nose := LaunchNose.new()
var _auto_nose := 0.0
var _run_nose := 0.3
var _ridge_until_s := 0.0
var _ridge_on := false
var _now := 0.0


## cfg — configs/bots.json; air_fn(pos) -> Vector3, ground_fn(x, z) -> высота.
func setup(
	cfg: Dictionary,
	wing_name: String,
	mass: float,
	air_fn: Callable,
	ground_fn: Callable,
	seed_value: int
) -> void:
	_cfg = cfg
	wing_id = wing_name
	_air_fn = air_fn
	_ground_fn = ground_fn
	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	mass_kg = FlightModel.clamp_pilot_mass(wing, mass)
	pilot.mass_kg = mass_kg
	model = FlightModel.new()
	model.setup(wing, pilot)
	brain = WanderPilot.new()
	brain.setup(wing, pilot, Vector2.ZERO)
	brain.rng.seed = seed_value
	brain.ground_fn = ground_fn
	var wd: Dictionary = cfg.get("wander", {})
	brain.wander_radius_m = float(wd.get("radius_m", 3500.0))
	var leg: Array = wd.get("leg_m", [800.0, 2500.0])
	brain.wander_leg_min_m = float(leg[0])
	brain.wander_leg_max_m = float(leg[1])
	var ctl: Dictionary = Config.get_config("controls").get("ground", {})
	_run_nose = float(ctl.get("run_nose_neutral", 0.3))
	_nose.configure(ctl.get("auto_nose", {}))


## Старт игрока (куда подходить и куда бежать).
func set_site(launch_pos: Vector3, heading_deg: float) -> void:
	_launch_pos = launch_pos
	_launch_heading = heading_deg
	_home = Vector2(launch_pos.x, launch_pos.z)
	brain.wander_home = _home


## Встать на место ожидания с крылом (новый полёт игрока).
func place(p: Vector3, heading_deg: float) -> void:
	spot = p
	spot_heading = heading_deg
	model.reset_on_ground(p, heading_deg)
	FlightTelemetry.fill(model, _air_fn, _ground_fn)
	state = State.WAIT
	run_at_s = INF
	run_start_s = -1.0
	liftoff_s = -1.0
	failed_runs = 0
	queue_hold = true
	landed_s = -1.0
	_nose.reset()
	_auto_nose = 0.0
	control = ControlInput.new()


## Сразу в воздухе (тесты, отладка): летает без цели.
func start_in_air(p: Vector3, heading_deg: float, now_s: float) -> void:
	var wind: Vector3 = _air_fn.call(p) if _air_fn.is_valid() else Vector3.ZERO
	model.reset_in_air(p, heading_deg, 0.0, Vector3(wind.x, 0.0, wind.z))
	FlightTelemetry.fill(model, _air_fn, _ground_fn)
	state = State.FLY
	liftoff_s = now_s - 1.0e3  # без «прямо от склона» и форы после взлёта
	run_start_s = now_s
	_ridge_on = false


func telemetry() -> Telemetry:
	return model.telemetry


func state_name() -> String:
	return STATE_NAMES[state]


## Летит (в воздухе): для расхождения и LOD.
func is_airborne() -> bool:
	return model.mode == FlightModel.Mode.AIR


## Один шаг бота длиной dt; now_s — время BotPilots.
func step(dt: float, now_s: float) -> void:
	_now = now_s
	var t := model.telemetry
	match state:
		State.WAIT:
			_stand(t, dt)
		State.WALK:
			_walk(t, dt)
		State.READY:
			_stand(t, dt)
			if now_s >= run_at_s:
				state = State.RUN
				run_start_s = now_s
		State.RUN:
			_run(t, dt)
		State.FLY:
			_fly(t, dt)
		State.LANDED:
			control.walk = 0.0
			control.run = false
			control.roll = 0.0
			control.pitch = 0.0
	model.step(dt, control, _air_fn, _ground_fn)
	_after_step(now_s)


## Пойти к старту (очередь BotPilots).
func go_to_launch() -> void:
	if state == State.WAIT:
		state = State.WALK


## Сколько идти от места ожидания до старта (через место в очереди), с — оценка.
func walk_time_s() -> float:
	var la: Dictionary = _cfg.get("launch", {})
	var q := _queue_point()
	var d := _flat_dist(spot, q) + _flat_dist(q, _ready_point())
	return d / float(la.get("walk_speed_est_ms", 0.9)) + float(la.get("walk_margin_s", 8.0))


func _after_step(now_s: float) -> void:
	match model.mode:
		FlightModel.Mode.AIR:
			if state == State.RUN:
				state = State.FLY
				liftoff_s = now_s
				_start_flight()
		FlightModel.Mode.FAILED:
			# Взлёт сорван — снова на старт, новый разбег позже.
			failed_runs += 1
			model.reset_on_ground(_ready_point(), _launch_heading)
			state = State.READY
			run_at_s = now_s + float(_cfg.get("launch", {}).get("retry_s", 20.0))
		FlightModel.Mode.LANDED:
			if state == State.FLY:
				state = State.LANDED
				landed_s = now_s


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _bearing(from: Vector2, to: Vector2) -> float:
	var d := to - from
	return fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0)


# ---------------------------------------------------------------- на земле


func _launch_fwd() -> Vector3:
	var h := deg_to_rad(_launch_heading)
	return Vector3(sin(h), 0.0, -cos(h))


func _ready_point() -> Vector3:
	var back := float(_cfg.get("launch", {}).get("ready_behind_m", 2.0))
	return _launch_pos - _launch_fwd() * back


## Место в очереди: позади старта и в стороне (чётные — вправо, нечётные — влево).
func _queue_point() -> Vector3:
	var la: Dictionary = _cfg.get("launch", {})
	var f := _launch_fwd()
	var right := Vector3(-f.z, 0.0, f.x)
	var side := float(la.get("queue_side_m", 9.0)) * (1.0 if id % 2 == 0 else -1.0)
	return _ready_point() - f * float(la.get("queue_back_m", 10.0)) + right * side


func _stand(t: Telemetry, dt: float) -> void:
	_nose.observe(t)
	control.run = false
	control.walk = 0.0
	control.roll = 0.0
	control.pitch = move_toward(control.pitch, _run_nose, dt)


## Подход: к месту в очереди (пока предыдущий не побежал) или к точке позади старта;
## там — развернуться по курсу разбега и стоять.
func _walk(t: Telemetry, dt: float) -> void:
	var rp := _queue_point() if queue_hold else _ready_point()
	var to := Vector2(rp.x - t.position.x, rp.z - t.position.z)
	control.run = false
	control.pitch = move_toward(control.pitch, _run_nose, dt)
	if to.length() > 1.0:
		var want := _bearing(Vector2.ZERO, to)
		var err := wrapf(want - t.heading_deg, -180.0, 180.0)
		control.roll = clampf(err / 15.0, -1.0, 1.0)
		control.walk = 1.0 if absf(err) < 45.0 else 0.0
		return
	control.walk = 0.0
	var err2 := wrapf(_launch_heading - t.heading_deg, -180.0, 180.0)
	control.roll = clampf(err2 / 10.0, -1.0, 1.0) if absf(err2) >= 3.0 else 0.0
	if absf(err2) < 3.0 and not queue_hold:
		state = State.READY


## Разбег как у игрока (InputController на земле + LaunchNose): нос — нейтраль разбега
## плюс автомат по ветру, крен — выравнивание крыла.
func _run(t: Telemetry, dt: float) -> void:
	_nose.observe(t)
	control.run = true
	control.walk = 0.0
	var an: Dictionary = Config.get_config("controls").get("ground", {}).get("auto_nose", {})
	var rng := float(an.get("range", 0.3))
	_auto_nose = clampf(
		_auto_nose + _nose.direction(t) * float(an.get("rate_per_s", 0.6)) * dt, -rng, 0.0
	)
	control.pitch = _run_nose + _auto_nose
	var err := wrapf(_launch_heading - t.heading_deg, -180.0, 180.0)
	control.roll = clampf(-t.bank_deg / 8.0 + err / 20.0, -1.0, 1.0)


# ---------------------------------------------------------------- в полёте


func _start_flight() -> void:
	var rc: Dictionary = _cfg.get("ridge", {})
	var fwd := _launch_fwd()
	var wind: Vector3 = (
		_air_fn.call(_launch_pos + Vector3.UP * 20.0) if _air_fn.is_valid() else Vector3.ZERO
	)
	var headwind := -Vector2(wind.x, wind.z).dot(Vector2(fwd.x, fwd.z))
	_ridge_on = headwind >= float(rc.get("min_wind_ms", 3.0))
	var out := _launch_pos + fwd * float(_cfg.get("wander", {}).get("first_leg_m", 1200.0))
	brain.set_first_goal(Vector2(_launch_pos.x, _launch_pos.z), Vector2(out.x, out.z))
	if _ridge_on:
		var ts: Array = rc.get("time_s", [60.0, 300.0])
		_ridge_until_s = liftoff_s + brain.rng.randf_range(float(ts[0]), float(ts[1]))
		var o := _launch_pos + fwd * float(rc.get("out_m", 110.0))
		brain.setup_ridge(
			Vector2(o.x, o.z),
			_launch_heading + 90.0,
			_launch_heading,
			float(rc.get("leg_m", 300.0))
		)


func _fly(t: Telemetry, dt: float) -> void:
	var la: Dictionary = _cfg.get("launch", {})
	if _now - liftoff_s < float(la.get("clear_s", 8.0)):
		_copy(brain.steer(t, dt, _launch_heading, 15.0))
		return
	var rc: Dictionary = _cfg.get("ridge", {})
	if _ridge_on:
		var high := t.altitude_msl > _launch_pos.y + float(rc.get("exit_above_launch_m", 250.0))
		# Склон не держит (прижимает к земле) — уйти от него в долину, не ждать.
		var pressed := t.altitude_agl < float(rc.get("low_agl_m", 25.0))
		if _now >= _ridge_until_s or high or pressed:
			_ridge_on = false
			brain.stop_ridge()
	_copy(brain.drive(t, dt))


func _copy(c: ControlInput) -> void:
	control.pitch = c.pitch
	control.roll = c.roll
	control.run = false
	control.walk = 0.0
	control.weight_shift = false
