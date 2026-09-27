class_name WindModel
extends RefCounted
## Средний ветер (степенной профиль по высоте) и детерминированная турбулентность
## («замороженное» поле когерентного шума, переносимое ветром — гипотеза Тейлора).

## Направление, куда дует ветер (горизонтальный единичный вектор, мир).
var dir: Vector3 = Vector3(0, 0, 1)
## Скорость ветра на опорной высоте, м/с.
var speed_ref: float = 0.0
## Метеонаправление «откуда», градусы.
var from_deg: float = 0.0

var _ref_h: float = 10.0
var _alpha: float = 0.14
var _z0: float = 1.0
var _max_f: float = 1.8

var _noise: FastNoiseLite
var _noise_norm: float = 1.0
var _inv_scale: float = 1.0
var _evolve: float = 0.0
## Смещения координат шума для трёх компонент (чтобы они были независимы).
var _off_v: Vector3
var _off_z: Vector3


func setup(wind_cfg: Dictionary, turb_cfg: Dictionary, seed_value: int) -> void:
	_ref_h = float(wind_cfg.reference_height_m)
	_alpha = float(wind_cfg.shear_exponent)
	_z0 = float(wind_cfg.roughness_height_m)
	_max_f = float(wind_cfg.max_profile_factor)
	var scale := float(turb_cfg.scale_m)
	_inv_scale = 1.0 / scale
	_evolve = float(turb_cfg.evolve_ms)
	_noise = FastNoiseLite.new()
	_noise.seed = seed_value
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = int(turb_cfg.octaves)
	_noise.frequency = 1.0
	# Смещения — в масштабах вихря, далеко друг от друга, чтобы компоненты не коррелировали.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_off_v = Vector3(
		rng.randf_range(100, 200), rng.randf_range(100, 200), rng.randf_range(100, 200)
	)
	_off_z = Vector3(
		rng.randf_range(300, 400), rng.randf_range(300, 400), rng.randf_range(300, 400)
	)
	_noise_norm = 1.0 / _measure_rms(rng)


## Шум нормируется на единичное СКО: амплитуда в конфиге — это σ пульсаций.
func _measure_rms(rng: RandomNumberGenerator) -> float:
	var sum := 0.0
	var n := 0
	for i in 2048:
		var v := _noise.get_noise_3d(
			rng.randf_range(-500, 500), rng.randf_range(-500, 500), rng.randf_range(-500, 500)
		)
		sum += v * v
		n += 1
	return maxf(sqrt(sum / n), 1.0e-4)


## Ветер «откуда» from_deg (0 — с севера), скорость на опорной высоте, м/с.
func set_wind(speed_ms: float, wind_from_deg: float) -> void:
	speed_ref = maxf(speed_ms, 0.0)
	from_deg = wind_from_deg
	var d := deg_to_rad(wind_from_deg)
	# X — восток, −Z — север; ветер с севера дует на юг (+Z).
	dir = Vector3(-sin(d), 0.0, cos(d))


## Множитель профиля на высоте agl над землёй.
func profile(agl: float) -> float:
	return minf(pow(maxf(agl, _z0) / _ref_h, _alpha), _max_f)


func speed_at(agl: float) -> float:
	return speed_ref * profile(agl)


## Горизонтальный ветер (x, z) на высоте agl.
func vec2_at(agl: float) -> Vector2:
	var s := speed_at(agl)
	return Vector2(dir.x * s, dir.z * s)


## Единичные пульсации (СКО ≈ 1 по каждой компоненте) в точке pos в момент t.
## advect — скорость переноса поля (м/с), обычно ветер над слоем трения.
func gust_unit(pos: Vector3, t: float, advect: float) -> Vector3:
	var q := (
		Vector3(pos.x - dir.x * advect * t, pos.y + _evolve * t, pos.z - dir.z * advect * t)
		* _inv_scale
	)
	return (
		Vector3(
			_noise.get_noise_3d(q.x, q.y, q.z),
			_noise.get_noise_3d(q.x + _off_v.x, q.y + _off_v.y, q.z + _off_v.z),
			_noise.get_noise_3d(q.x + _off_z.x, q.y + _off_z.y, q.z + _off_z.z)
		)
		* _noise_norm
	)
