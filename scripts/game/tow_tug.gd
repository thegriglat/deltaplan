class_name TowTug
extends RefCounted
## Буксировщик аэробуксировки (TW-К9 v2, docs/contracts/tow.md): Ан-2 едет по траектории.
##
## ЧЕСТНО: это кинематика, не модель полёта. Ан-2 так медленно не летает (на 55-65 км/ч он почти
## у сваливания), струи винта и спутного следа нет, на силу троса самолёт не реагирует (она -
## доли процента его массы). Скорость буксировки - дельтаплана (kinds.md), числа - configs/tow_tug.json.
##
## Мир игры: X восток, Y вверх, -Z север; курс - от севера по часовой, вперёд = (sin h, 0, -cos h).
## API:
##   setup(runway_start, heading_deg, rope_length_m, terrain_height: Callable(x, z) -> float, cfg := {})
##   start()                          # по W: фаза slack
##   set_rope_tension(n: float)       # натяжение троса (TowLine.tension_n), каждый шаг
##   release()                        # отцеп/обрыв: фаза away
##   step(dt, glider_height_agl_m)
## Чтение: pos (точка крепления троса - хвост), vel, basis (-Z вдоль скорости, левый крен на кругах),
## phase: idle / slack / roll / climb / circuit / away; agl_m (высота колёс над землёй),
## gone (после away_s - модель можно убрать).

const GRAVITY := 9.81

var pos := Vector3.ZERO
var vel := Vector3.ZERO
var basis := Basis.IDENTITY
var phase := "idle"
var agl_m := 0.0
var gone := false

var _cfg: Dictionary = {}
var _terrain: Callable
var _heading := 0.0  # рад, от севера по часовой
var _speed_h := 0.0  # горизонтальная скорость
var _vz := 0.0  # вертикальная скорость
var _tension := 0.0
var _away_t := 0.0
var _away_dh := 0.0  # рад, уже довернуто в away
var _bank := 0.0


func setup(
	runway_start: Vector3, heading_deg: float, rope_length_m: float, terrain_height: Callable, cfg: Dictionary = {}
) -> void:
	_cfg = cfg if not cfg.is_empty() else Config.get_config("tow_tug")
	_terrain = terrain_height
	_heading = deg_to_rad(heading_deg)
	var p := runway_start + _fwd(_heading) * rope_length_m
	agl_m = 0.0
	pos = Vector3(p.x, _ground(p.x, p.z) + _f("tail_height_m", 1.5), p.z)
	vel = Vector3.ZERO
	phase = "idle"
	gone = false
	_speed_h = 0.0
	_vz = 0.0
	_tension = 0.0
	_away_t = 0.0
	_away_dh = 0.0
	_bank = 0.0
	_update_basis()


func start() -> void:
	if phase == "idle":
		phase = "slack"


func set_rope_tension(n: float) -> void:
	_tension = n if is_finite(n) else 0.0


func release() -> void:
	if phase != "away":
		phase = "away"
		_away_t = 0.0
		_away_dh = 0.0
		_bank = 0.0


func step(dt: float, glider_height_agl_m: float) -> void:
	if dt <= 0.0 or phase == "idle" or gone:
		return
	var v_tow := _f("tow_speed_kmh", 60.0) / 3.6
	match phase:
		"slack":
			_speed_h = _f("slack_speed_ms", 1.0)
			_vz = 0.0
			_move_ground(dt)
			if _tension > 0.0:
				phase = "roll"
		"roll":
			_speed_h = minf(_speed_h + _f("roll_accel_ms2", 1.2) * dt, v_tow)
			_vz = 0.0
			_move_ground(dt)
			if glider_height_agl_m >= _f("glider_hold_agl_m", 3.0) and _speed_h >= v_tow - 1e-6:
				phase = "climb"
		"climb":
			_air_speeds(v_tow, _f("climb_rate_ms", 2.5))
			_move_air(dt, 0.0)
			if agl_m >= _f("circuit_start_agl_m", 150.0):
				phase = "circuit"
		"circuit":
			_air_speeds(v_tow, _f("circuit_climb_rate_ms", 2.5))
			var r := maxf(_f("circuit_radius_m", 200.0), 1.0)
			_move_air(dt, -_speed_h / r)  # влево: курс уменьшается
			_bank = atan(_speed_h * _speed_h / (GRAVITY * r))
		"away":
			_step_away(dt, v_tow)
	_update_basis()


func _air_speeds(v_tow: float, climb: float) -> void:
	_vz = minf(climb, v_tow)
	_speed_h = sqrt(maxf(v_tow * v_tow - _vz * _vz, 0.0))


func _f(key: String, def: float) -> float:
	return float(_cfg.get(key, def))


func _ground(x: float, z: float) -> float:
	return float(_terrain.call(x, z)) if _terrain.is_valid() else 0.0


static func _fwd(h: float) -> Vector3:
	return Vector3(sin(h), 0.0, -cos(h))


func _move_ground(dt: float) -> void:
	var np := pos + _fwd(_heading) * _speed_h * dt
	np.y = _ground(np.x, np.z) + _f("tail_height_m", 1.5)
	agl_m = 0.0
	vel = (np - pos) / dt
	pos = np


## Дуга: курс доворачивается на dh за шаг, смещение - по среднему курсу (хорда).
func _move_air(dt: float, omega: float) -> void:
	var mid := _heading + omega * dt * 0.5
	var chord := 2.0 * _speed_h / absf(omega) * sin(absf(omega) * dt * 0.5) if absf(omega) > 1e-9 else _speed_h * dt
	var np := pos + _fwd(mid) * chord
	np.y = pos.y + _vz * dt
	var floor_y := _ground(np.x, np.z) + _f("tail_height_m", 1.5)
	np.y = maxf(np.y, floor_y)
	agl_m = np.y - floor_y
	_heading += omega * dt
	vel = Vector3(_fwd(mid).x * _speed_h, _vz, _fwd(mid).z * _speed_h)
	pos = np


func _step_away(dt: float, v_tow: float) -> void:
	_away_t += dt
	var turn := deg_to_rad(_f("away_turn_deg", 30.0))
	var turn_s := maxf(_f("away_turn_s", 4.0), 0.1)
	var omega := 0.0
	if _away_dh < turn:
		omega = turn / turn_s
		var d := minf(omega * dt, turn - _away_dh)
		_away_dh += d
		omega = -d / dt  # влево
	_speed_h = v_tow
	_vz = -_f("away_descent_ms", 2.0)
	_move_air(dt, omega)
	if is_zero_approx(agl_m):
		_vz = 0.0
		vel.y = 0.0
	if _away_t >= _f("away_s", 15.0):
		gone = true


func _update_basis() -> void:
	var f := vel.normalized() if vel.length() > 1e-6 else _fwd(_heading)
	var right := f.cross(Vector3.UP).normalized()
	var up := right.cross(f)
	var b := Basis(right, up, -f)
	basis = Basis(f, -_bank) * b if _bank != 0.0 else b
