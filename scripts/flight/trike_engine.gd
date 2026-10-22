class_name TrikeEngine
extends RefCounted
## Двигатель дельталёта (контракт TP-К2 v1): состояния off/starting/running/stopping, рычаг газа,
## обороты винта, тяга по таблице TT-К1, расход по таблице TP-К1.
## Границы модели: сопротивление остановленного винта не моделируется; тяга на переходах ∝ n²;
## направление и точка приложения тяги — не здесь (TP-6).

var state: String = "off"
var running: bool = false
var throttle: float = 0.0
var prop_rpm: float = 0.0
var engine_rpm: float = 0.0
var thrust_n: float = 0.0
var fuel_l: float = 0.0
var tank_l: float = 1.0
var fuel_frac: float = 0.0
var fuel_mass_kg: float = 0.0
var out_of_fuel: bool = false

var _gear: float = 1.0
var _idle_rpm: float = 0.0
var _v: PackedFloat64Array = PackedFloat64Array()
var _full: PackedFloat64Array = PackedFloat64Array()
var _idle: PackedFloat64Array = PackedFloat64Array()
var _rpm_full: PackedFloat64Array = PackedFloat64Array()
var _burn_rpm: PackedFloat64Array = PackedFloat64Array()
var _burn_lph: PackedFloat64Array = PackedFloat64Array()
var _start_s: float = 1.0
var _stop_s: float = 1.0
var _rate: float = 1.0
var _start_l: float = 0.0
var _density: float = 0.74


func setup(engine_cfg: Dictionary, thrust_cfg: Dictionary, ops_cfg: Dictionary) -> void:
	_gear = float(engine_cfg.get("gear_ratio", 1.0))
	_idle_rpm = float(engine_cfg.get("prop_rpm_idle", 0.0))
	_v = _arr(thrust_cfg.get("v_ms", []))
	_full = _arr(thrust_cfg.get("full_n", []))
	_idle = _arr(thrust_cfg.get("idle_n", []))
	_rpm_full = _arr(thrust_cfg.get("rpm_full", []))
	var fuel: Dictionary = ops_cfg.get("fuel", {})
	tank_l = maxf(float(fuel.get("tank_l", 1.0)), 1e-6)
	_start_l = float(fuel.get("start_l", tank_l))
	_density = float(fuel.get("density_kg_l", 0.74))
	var burn: Dictionary = fuel.get("burn", {})
	_burn_rpm = _arr(burn.get("rpm_engine", []))
	_burn_lph = _arr(burn.get("lph", []))
	var st: Dictionary = ops_cfg.get("starter", {})
	_start_s = maxf(float(st.get("start_s", 1.0)), 1e-6)
	_stop_s = maxf(float(st.get("stop_s", 1.0)), 1e-6)
	_rate = float(ops_cfg.get("throttle", {}).get("rate_per_s", 1.0))
	reset()


func reset(fuel_l_start: float = -1.0) -> void:
	state = "off"
	throttle = 0.0
	prop_rpm = 0.0
	fuel_l = _start_l if fuel_l_start < 0.0 else minf(fuel_l_start, tank_l)
	out_of_fuel = fuel_l <= 0.0
	_update_outputs(0.0, 0.0)


func step(dt: float, airspeed_ms: float, throttle_axis: float, toggle_pressed: bool) -> void:
	throttle = clampf(throttle + clampf(throttle_axis, -1.0, 1.0) * _rate * dt, 0.0, 1.0)
	var rpm_t := _target_rpm(airspeed_ms, throttle)
	var t_t := _target_thrust(airspeed_ms, throttle)
	if state == "off":
		if toggle_pressed and not out_of_fuel:
			state = "starting"
	elif (state == "running" or state == "starting") and toggle_pressed:
		state = "stopping"
	match state:
		"starting":
			prop_rpm = move_toward(prop_rpm, rpm_t, _idle_rpm / _start_s * dt)
			if prop_rpm >= rpm_t:
				prop_rpm = rpm_t
				state = "running"
		"running":
			prop_rpm = rpm_t
		"stopping":
			prop_rpm = maxf(prop_rpm - _idle_rpm / _stop_s * dt, 0.0)
			if prop_rpm <= 0.0:
				prop_rpm = 0.0
				state = "off"
	if state == "starting" or state == "running":
		fuel_l -= _lph(prop_rpm * _gear) / 3600.0 * dt
		if fuel_l <= 0.0:
			fuel_l = 0.0
			out_of_fuel = true
			state = "stopping"
	_update_outputs(rpm_t, t_t)


func _update_outputs(rpm_t: float, t_t: float) -> void:
	running = state == "running"
	engine_rpm = prop_rpm * _gear
	match state:
		"running":
			thrust_n = t_t
		"starting", "stopping":
			var k := prop_rpm / rpm_t if rpm_t > 0.0 else 0.0
			thrust_n = t_t * k * k
		_:
			thrust_n = 0.0
	thrust_n = maxf(thrust_n, 0.0)
	fuel_frac = fuel_l / tank_l
	fuel_mass_kg = fuel_l * _density


func _target_rpm(v: float, g: float) -> float:
	return _idle_rpm + g * (_interp(_v, _rpm_full, v) - _idle_rpm)


func _target_thrust(v: float, g: float) -> float:
	var ti := _interp(_v, _idle, v)
	return ti + g * (_interp(_v, _full, v) - ti)


func _lph(rpm_eng: float) -> float:
	return _interp(_burn_rpm, _burn_lph, rpm_eng)


static func _arr(a) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	for x in a:
		r.append(float(x))
	return r


## Линейная интерполяция, вне таблицы — крайние значения.
static func _interp(xs: PackedFloat64Array, ys: PackedFloat64Array, x: float) -> float:
	var n := mini(xs.size(), ys.size())
	if n == 0:
		return 0.0
	if x <= xs[0]:
		return ys[0]
	if x >= xs[n - 1]:
		return ys[n - 1]
	for i in range(1, n):
		if x <= xs[i]:
			var f := (x - xs[i - 1]) / (xs[i] - xs[i - 1])
			return ys[i - 1] + f * (ys[i] - ys[i - 1])
	return ys[n - 1]
