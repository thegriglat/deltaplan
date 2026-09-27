class_name WanderPilot
extends BotPilot
## Бот «других пилотов в небе» (BotAgent, BotPilots): те же мозги, что у маршрутника (BotPilot:
## термики по вариометру, центровка, «восьмёрка у склона», обход рельефа), но без маршрута —
## «наслаждается видом»: цели перелётов — случайные точки в круге wander_radius_m вокруг
## wander_home (с облаками — под растущим облаком по пути). Сторону виража в термике может
## задать circle_dir_fn (правило «в одном термике — в одну сторону»); traffic_avoid —
## расхождение с другими пилотами (курс traffic_heading_deg задаёт BotPilots).

## Летать без маршрута: цели перелётов — случайные точки у дома.
var wander: bool = true
var wander_home: Vector2 = Vector2.ZERO
## Круг, в котором выбираются цели перелётов, м.
var wander_radius_m: float = 3500.0
## Длина перелёта к новой цели, м.
var wander_leg_min_m: float = 800.0
var wander_leg_max_m: float = 2500.0
## Случайности бота (цели перелётов); сид задаёт BotPilots — детерминированно.
var rng := RandomNumberGenerator.new()
## (pos: Vector2, alt: float, dir: float) -> float — сторона виража в этом термике (±1; 0 —
## своя dir). Пусто — сторона по крылу, как у маршрутника.
var circle_dir_fn: Callable
## Расхождение с другими пилотами: пока true — держать курс traffic_heading_deg.
var traffic_avoid: bool = false
var traffic_heading_deg: float = 0.0

var _wander_ready: bool = false


## Сторона виража: +1 — вправо, −1 — влево.
func circle_dir() -> float:
	return _dir


## Сменить сторону виража в термике (правило «в одну сторону»).
func set_circle_dir(d: float) -> void:
	if d != 0.0:
		_dir = signf(d)


## Куда сейчас сдвигается круг (оценка центра подъёма), (x, z).
func lift_center() -> Vector2:
	return _circle_target(null)


## Выйти из «восьмёрки у склона» в обычный полёт (перелёты, термики).
func stop_ridge() -> void:
	ridge_active = false
	if mode == Mode.RIDGE:
		mode = Mode.CRUISE


## Управление на курс heading_deg (крен не круче max_bank) на скорости v_ms (≤ 0 — трим):
## для взлёта и захода на посадку (BotAgent).
func steer(
	t: Telemetry, dt: float, heading_deg: float, max_bank: float, v_ms: float = 0.0
) -> ControlInput:
	_tick_senses(t, dt)
	_steer_heading(t, heading_deg, max_bank)
	_set_speed(v_ms if v_ms > 0.0 else trim_speed(t.altitude_msl), t)
	return _ctl


## Круг радиуса r вокруг center (dir: +1 — вправо) на скорости v_ms (≤ 0 — трим): сброс
## высоты над посадочной.
func orbit(
	t: Telemetry, dt: float, center: Vector2, r: float, dir: float, v_ms: float = 0.0
) -> ControlInput:
	_tick_senses(t, dt)
	var pos := Vector2(t.position.x, t.position.z)
	var v := maxf(t.groundspeed, 5.0)
	var base := rad_to_deg(atan(v * v / (Units.G * r)))
	_hold_bank(t, _orbit_bank(t, pos, center, r, dir, base, 35.0))
	_set_speed(v_ms if v_ms > 0.0 else trim_speed(t.altitude_msl), t)
	return _ctl


## Первый перелёт — к точке p (x, z), дальше — случайные цели.
func set_first_goal(pos: Vector2, p: Vector2) -> void:
	route_start = pos
	goal = p
	_wander_ready = true


## Усреднённый вариометр (как чувствует пилот), м/с.
func vario_avg() -> float:
	return _vario_avg


## Скорость трима на высоте alt, м/с.
func trim_speed(alt: float) -> float:
	return _v_trim * _speed_scale(alt)


func _tick_senses(t: Telemetry, dt: float) -> void:
	_t += dt
	_dt = dt
	_update_senses(t, dt)


## Расхождение важнее кружения (после обхода рельефа); счёт витков не копит поворот ухода.
func _take_over(t: Telemetry, _pos: Vector2, _dt_s: float) -> bool:
	if not traffic_avoid:
		return false
	_steer_heading(t, traffic_heading_deg, cruise_bank_max_deg + 10.0)
	_set_speed(_stf(0.0, t.altitude_msl), t)
	_prev_heading = t.heading_deg
	_ridge_prev_heading = t.heading_deg
	return true


func _start_circle(t: Telemetry) -> void:
	if circle_dir_fn.is_valid():
		var pos := Vector2(t.position.x, t.position.z)
		set_circle_dir(float(circle_dir_fn.call(pos, t.altitude_msl, _dir)))
	super(t)


func _cruise_target(pos: Vector2, dt: float) -> Vector2:
	if wander:
		_wander_update(pos)
	return super(pos, dt)


## Долетел до цели (или цели ещё нет) — новая случайная точка у дома.
func _wander_update(pos: Vector2) -> void:
	if _wander_ready and pos.distance_to(goal) > 300.0:
		return
	_wander_ready = true
	_has_cloud_target = false
	_visited_clouds.clear()
	route_start = pos
	goal = wander_home
	for i in 12:
		var p := (
			wander_home
			+ Vector2.from_angle(rng.randf() * TAU) * wander_radius_m * sqrt(rng.randf())
		)
		var d := pos.distance_to(p)
		if d >= wander_leg_min_m and d <= wander_leg_max_m:
			goal = p
			return
