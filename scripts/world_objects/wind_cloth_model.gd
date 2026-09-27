class_name WindClothModel
extends RefCounted
## Поведение ветроуказателя или ленты по локальному воздуху (VR-7, VR-0).
## Без нод — тестируется headless.
## Вход — скорость воздуха у вертлюга (Atmosphere.air_velocity_at, м/с, мир).
## Выход: yaw (поворот вокруг Y: локальная −Z смотрит ПО ветру),
## pitch (наклон от вертикального потока),
## fill 0..1 (0 — висит, 1 — вытянут), flutter_amp (доля длины) и flutter_phase (рад) для шейдера.
## Параметры — configs/world_objects.json → windsock / streamers.

## Шаг интегрирования поворота не больше этого (устойчивость жёсткой пружины), с.
const MAX_SUBSTEP_S := 0.02

var yaw: float = 0.0
var yaw_rate: float = 0.0
var pitch: float = 0.0
var fill: float = 0.0
var speed_ms: float = 0.0
var gust_sigma_ms: float = 0.0
var flutter_amp: float = 0.0
var flutter_phase: float = 0.0

var _full_ms: float = 7.8
var _lift_ms: float = 1.1
var _curve: float = 0.6
var _speed_tau: float = 0.35
var _k_per_ms: float = 6.0
var _k_min: float = 1.5
var _damping: float = 2.2
var _max_pitch: float = 0.44
var _gust_window: float = 3.0
var _fl_base: float = 0.05
var _fl_gust: float = 0.12
var _fl_max: float = 0.3
var _fl_hz_per_ms: float = 0.35
var _fl_min_hz: float = 0.6
var _mean_ms: float = 0.0
var _var_ms2: float = 0.0
var _started: bool = false


func _init(cfg: Dictionary = {}) -> void:
	if not cfg.is_empty():
		configure(cfg)


func configure(cfg: Dictionary) -> void:
	_full_ms = Units.kmh(float(cfg.full_wind_kmh))
	_lift_ms = Units.kmh(float(cfg.lift_wind_kmh))
	_curve = float(cfg.droop_curve)
	_speed_tau = float(cfg.speed_tau_s)
	_k_per_ms = float(cfg.yaw_stiffness)
	_k_min = float(cfg.yaw_min_stiffness)
	_damping = float(cfg.yaw_damping)
	_max_pitch = deg_to_rad(float(cfg.max_pitch_deg))
	_gust_window = float(cfg.gust_window_s)
	_fl_base = float(cfg.flutter_base)
	_fl_gust = float(cfg.flutter_per_gust)
	_fl_max = float(cfg.flutter_max)
	_fl_hz_per_ms = float(cfg.flutter_hz_per_ms)
	_fl_min_hz = float(cfg.flutter_min_hz)


## Сразу поставить в равновесие по ветру (при появлении объекта, без «раскручивания»).
func reset(air: Vector3) -> void:
	var h := Vector2(air.x, air.z)
	speed_ms = air.length()
	_mean_ms = speed_ms
	_var_ms2 = 0.0
	if h.length() > 1.0e-3:
		yaw = target_yaw(air)
	yaw_rate = 0.0
	fill = fill_for_speed(speed_ms)
	pitch = _target_pitch(air)
	_started = true


func step(dt: float, air: Vector3) -> void:
	if not _started:
		reset(air)
	if dt <= 0.0:
		return
	var v := air.length()
	speed_ms += (v - speed_ms) * (1.0 - exp(-dt / _speed_tau))
	var a := 1.0 - exp(-dt / _gust_window)
	_mean_ms += (v - _mean_ms) * a
	_var_ms2 += ((v - _mean_ms) * (v - _mean_ms) - _var_ms2) * a
	gust_sigma_ms = sqrt(maxf(_var_ms2, 0.0))
	fill = fill_for_speed(speed_ms)
	_step_yaw(dt, air)
	pitch += (_target_pitch(air) - pitch) * (1.0 - exp(-dt / _speed_tau))
	flutter_amp = minf(_fl_base * (0.3 + 0.7 * fill) + _fl_gust * gust_sigma_ms, _fl_max)
	var hz := maxf(_fl_min_hz, _fl_hz_per_ms * speed_ms)
	flutter_phase = fmod(flutter_phase + TAU * hz * dt, TAU * 64.0)


## Наполнение конуса при установившейся скорости: 0 — висит, 1 — горизонтально.
func fill_for_speed(v: float) -> float:
	var x := clampf((v - _lift_ms) / maxf(_full_ms - _lift_ms, 1.0e-3), 0.0, 1.0)
	return pow(x, _curve)


## Угол поворота вокруг Y, при котором локальная −Z смотрит по горизонтальному ветру.
static func target_yaw(air: Vector3) -> float:
	return atan2(-air.x, -air.z)


## Куда показывает конус (горизонтальный единичный вектор, мир).
func pointing() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _target_pitch(air: Vector3) -> float:
	var h := Vector2(air.x, air.z).length()
	return clampf(atan2(air.y, maxf(h, 0.3)), -_max_pitch, _max_pitch) * fill


func _step_yaw(dt: float, air: Vector3) -> void:
	var h := Vector2(air.x, air.z).length()
	var k := maxf(_k_min, _k_per_ms * h)
	var err := 0.0
	if h > 1.0e-3:
		err = wrapf(target_yaw(air) - yaw, -PI, PI)
	var n := ceili(dt / MAX_SUBSTEP_S)
	var sub := dt / n
	for i in n:
		if h > 1.0e-3:
			err = wrapf(target_yaw(air) - yaw, -PI, PI)
		yaw_rate += (k * err - _damping * yaw_rate) * sub
		yaw = wrapf(yaw + yaw_rate * sub, -PI, PI)
