class_name WindModel
extends RefCounted
## Средний ветер (степенной профиль по высоте) и детерминированная турбулентность
## («замороженное» поле когерентного шума, переносимое ветром — гипотеза Тейлора).
## Профиль — WindProfile (C2 v4, одна функция с решателем): α по устойчивости из ветра, высоты
## солнца и облачности (set_conditions), насыщение на z_sat; пересчёт при смене ветра и условий.

## Направление, куда дует ветер (горизонтальный единичный вектор, мир).
var dir: Vector3 = Vector3(0, 0, 1)
## Скорость ветра на опорной высоте, м/с.
var speed_ref: float = 0.0
## Метеонаправление «откуда», градусы.
var from_deg: float = 0.0
## Высота над рельефом, выше которой крупные вихри в полную силу (turbulence.large_fade_agl_m).
var large_fade_agl: float = 150.0

## Высота над морем, на которой задан ветер прогноза (старт), м; NAN — ветер от высоты над морем
## не зависит (только профиль над рельефом). Задаёт Atmosphere.set_wind(…, ref_msl).
var ref_msl: float = NAN
## Условия устойчивости (Atmosphere: погода и час): высота солнца, °, облачность 0..1.
var sun_elev_deg: float = 52.0
var cover: float = 0.0

var _ref_h: float = 10.0
var _alt_gain: float = 0.0
var _alt_min: float = 1.0
var _alt_max: float = 1.0
var _alpha: float = 0.24
var _z0: float = 1.0
var _max_f: float = 1.0

var _noise: FastNoiseLite
var _noise_norm: float = 1.0
var _inv_scale: float = 1.0
var _evolve: float = 0.0
## Смещения координат шума для трёх компонент (чтобы они были независимы).
var _off_v: Vector3
var _off_z: Vector3
## Крупные вихри (turbulence.large_scale_m): 1/масштаб и их доля СКО на высоте.
var _inv_large: float = 0.0
var _amp_large: float = 0.0
var _off_l: Vector3


func setup(wind_cfg: Dictionary, turb_cfg: Dictionary, seed_value: int) -> void:
	_ref_h = float(wind_cfg.reference_height_m)
	_z0 = float(wind_cfg.roughness_height_m)
	_alt_gain = float(wind_cfg.get("altitude_gain_per_km", 0.0))
	_alt_min = float(wind_cfg.get("altitude_min_factor", 1.0))
	_alt_max = float(wind_cfg.get("altitude_max_factor", 1.0))
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
	_off_l = Vector3(
		rng.randf_range(500, 600), rng.randf_range(500, 600), rng.randf_range(500, 600)
	)
	_noise_norm = 1.0 / _measure_rms(rng)
	# Два масштаба: основная энергия — в крупных вихрях, мелкие (scale_m, раскачивают крыло
	# по крену) слабее по закону Колмогорова σ ∝ (l/L)^(1/3). Суммарное СКО — 1.
	var large := float(turb_cfg.get("large_scale_m", 0.0))
	large_fade_agl = maxf(float(turb_cfg.get("large_fade_agl_m", 150.0)), 1.0)
	if large > scale:
		_inv_large = 1.0 / large
		var amp_small := pow(scale / large, 1.0 / 3.0)
		_amp_large = sqrt(1.0 - amp_small * amp_small)
	else:
		_inv_large = 0.0
		_amp_large = 0.0


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
	_update_profile()


## Условия устойчивости для профиля: высота солнца (°) и облачность 0..1 (класс Тёрнера).
func set_conditions(sun_elev: float, cover_frac: float) -> void:
	sun_elev_deg = sun_elev
	cover = clampf(cover_frac, 0.0, 1.0)
	_update_profile()


## α и предел профиля из WindProfile (z0 и f — как у решателя: AirCase.Z0, F_COR).
func _update_profile() -> void:
	_alpha = WindProfile.alpha(speed_ref, sun_elev_deg, cover)
	_max_f = WindProfile.max_profile(_alpha, speed_ref, AirCase.Z0, AirCase.F_COR)


## Показатель профиля и ветер на высоте / U10 (для отладки и тестов).
func profile_params() -> Vector2:
	return Vector2(_alpha, _max_f)


## Множитель профиля на высоте agl над землёй.
func profile(agl: float) -> float:
	return minf(pow(maxf(agl, _z0) / _ref_h, _alpha), _max_f)


func speed_at(agl: float) -> float:
	return speed_ref * profile(agl)


## Множитель ветра от высоты над стартом (ветер прогноза — на старте; в горах выше старта ветер
## сильнее, в долине ниже — слабее). 1 — если опорная высота не задана.
func altitude_factor(msl: float) -> float:
	if is_nan(ref_msl):
		return 1.0
	return clampf(1.0 + _alt_gain * (msl - ref_msl) / 1000.0, _alt_min, _alt_max)


## Скорость ветра на высоте agl над рельефом в точке с высотой msl над морем, м/с.
func speed_at_pos(agl: float, msl: float) -> float:
	return speed_ref * profile(agl) * altitude_factor(msl)


## Горизонтальный ветер (x, z) на высоте agl.
func vec2_at(agl: float) -> Vector2:
	var s := speed_at(agl)
	return Vector2(dir.x * s, dir.z * s)


## Единичные пульсации (СКО ≈ 1 по каждой компоненте) в точке pos в момент t.
## advect — скорость переноса поля (м/с), обычно ветер над слоем трения.
## large_k 0..1 — доля крупных вихрей от полной (0 — только мелкие с СКО 1: у земли, бурление в
## облаке). Горизонталь: мелкие + крупные, СКО 1 при любом large_k. Вертикаль — только мелкие с той
## же долей: крупные вертикальные движения — термики и опускания, они в модели отдельно.
func gust_unit(pos: Vector3, t: float, advect: float, large_k: float = 1.0) -> Vector3:
	var p := Vector3(pos.x - dir.x * advect * t, pos.y + _evolve * t, pos.z - dir.z * advect * t)
	var n := _noise3(p * _inv_scale)
	var a_l := _amp_large * clampf(large_k, 0.0, 1.0)
	if a_l > 1.0e-4:
		var a_s := sqrt(1.0 - a_l * a_l)
		var nl := _noise3(p * _inv_large + _off_l)
		n = Vector3(n.x * a_s + nl.x * a_l, n.y * a_s, n.z * a_s + nl.z * a_l)
	return n * _noise_norm


func _noise3(q: Vector3) -> Vector3:
	return Vector3(
		_noise.get_noise_3d(q.x, q.y, q.z),
		_noise.get_noise_3d(q.x + _off_v.x, q.y + _off_v.y, q.z + _off_v.z),
		_noise.get_noise_3d(q.x + _off_z.x, q.y + _off_z.y, q.z + _off_z.z)
	)
