class_name MenuAmbientMix
extends RefCounted
## Логика фона меню: огибающая порывов ветра, расписание криков птиц, затухание/появление.
## Без узлов и аудио — детерминированна по сиду (тестируется). Параметры — configs/audio.json → menu.
## Использование: setup(cfg, seed); каждый кадр advance(dt, active) → событие птицы ({} или
## {clip, pan, db}); громкости — wind_db() / grass_db() / lpf_hz() / fade_gain().

var _cfg: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _fade: float = 0.0  # 0..1, линейная амплитуда
var _periods: Array[float] = []
var _phases: Array[float] = []
var _grass_phases: Array[float] = []
var _next_bird_s: float = 0.0
var _bird_clips: int = 0
var _last_clip: int = -1


## cfg — раздел menu; bird_clips — сколько записей птиц (по умолчанию из files.birds).
func setup(cfg: Dictionary, seed_value: int = 0, bird_clips: int = -1) -> void:
	_cfg = cfg
	_rng.seed = seed_value
	_t = 0.0
	_fade = 0.0
	_last_clip = -1
	_bird_clips = bird_clips if bird_clips >= 0 else (cfg.get("files", {}).get("birds", []) as Array).size()
	var base := float(cfg.get("gust_period_s", 28.0))
	var jit := float(cfg.get("gust_period_jitter", 0.25))
	_periods = [
		base * _rng.randf_range(1.0 - jit, 1.0 + jit),
		base * 0.37 * _rng.randf_range(1.0 - jit, 1.0 + jit),
		base * 0.17 * _rng.randf_range(1.0 - jit, 1.0 + jit),
	]
	_phases = [_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU]
	_grass_phases = [_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU]
	var first: Array = cfg.get("birds_first_s", [6.0, 20.0])
	_next_bird_s = _rng.randf_range(float(first[0]), float(first[1]))


## Шаг времени. active — меню видно. Возвращает крик птицы или {}.
func advance(dt: float, active: bool) -> Dictionary:
	var fin := maxf(float(_cfg.get("fade_in_s", 3.0)), 0.001)
	var fout := maxf(float(_cfg.get("fade_out_s", 1.0)), 0.001)
	if active:
		_fade = minf(1.0, _fade + dt / fin)
	else:
		_fade = maxf(0.0, _fade - dt / fout)
	_t += dt
	if _fade <= 0.0 or _bird_clips <= 0:
		return {}  # в тишине расписание птиц стоит
	_next_bird_s -= dt
	if _next_bird_s > 0.0:
		return {}
	var iv: Array = _cfg.get("birds_interval_s", [20.0, 60.0])
	_next_bird_s = _rng.randf_range(float(iv[0]), float(iv[1]))
	return _make_bird()


func _make_bird() -> Dictionary:
	var clip := _rng.randi_range(0, _bird_clips - 1)
	if _bird_clips > 1 and clip == _last_clip:
		clip = (clip + 1 + _rng.randi_range(0, _bird_clips - 2)) % _bird_clips  # не тот же подряд
	_last_clip = clip
	var pan := float(_cfg.get("birds_pan", 0.8))
	var db: Array = _cfg.get("birds_db", [-18.0, -9.0])
	return {
		"clip": clip,
		"pan": _rng.randf_range(-pan, pan),
		"db": _rng.randf_range(float(db[0]), float(db[1])),
	}


## Огибающая порыва 0 (затишье) .. 1 (порыв) в момент t; phases — фазы слоя.
func gust(t: float, phases: Array[float]) -> float:
	var s := (
		0.5 * sin(TAU * t / _periods[0] + phases[0])
		+ 0.3 * sin(TAU * t / _periods[1] + phases[1])
		+ 0.2 * sin(TAU * t / _periods[2] + phases[2])
	)
	return clampf(0.5 + 0.5 * s, 0.0, 1.0)


func gust_now() -> float:
	return gust(_t, _phases)


## Громкость основного ветра без затухания, дБ: от wind_db − глубина до wind_db.
func wind_db() -> float:
	var depth := float(_cfg.get("gust_depth_db", 12.0))
	return float(_cfg.get("wind_db", -20.0)) - depth * (1.0 - gust(_t, _phases))


## Громкость слоя травы (другая фаза порывов), дБ.
func grass_db() -> float:
	var depth := float(_cfg.get("gust_depth_db", 12.0))
	var top := float(_cfg.get("wind_db", -20.0)) + float(_cfg.get("grass_share_db", -6.0))
	return top - depth * (1.0 - gust(_t, _grass_phases))


## Срез ФНЧ ветра, Гц: порыв светлее.
func lpf_hz() -> float:
	var r: Array = _cfg.get("lpf_hz", [900.0, 5000.0])
	return lerpf(float(r[0]), float(r[1]), gust(_t, _phases))


## Амплитуда затухания 0..1 (линейная; −80 дБ и ниже — 0).
func fade_gain() -> float:
	return _fade


func fade_db() -> float:
	return -80.0 if _fade <= 0.0 else maxf(-80.0, 20.0 * log(_fade) / log(10.0))


## Слышно ли что-то (для остановки плееров).
func audible() -> bool:
	return _fade > 0.0 and (wind_db() + fade_db()) > float(_cfg.get("silence_db", -60.0))


func time_to_next_bird() -> float:
	return _next_bird_s
