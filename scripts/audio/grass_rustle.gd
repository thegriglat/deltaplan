class_name GrassRustle
extends RefCounted
## Шуршание ног о траву (PH-4, PH-К6): честный сигнал близости земли на взлёте и посадке, без HUD.
## Шуршит, когда подошвы ниже верхушек травы в этой точке и движутся относительно земли;
## громкость — от погружения и скорости. Нет травы (высота 0) или стоим — тишина.
## Чистая логика без нод (тестируется headless) + процедурный зацикленный звук (шум с «зёрнами»).
## Параметры — configs/audio.json → flight.rustle.


## Громкость шуршания 0..1 по ногам: feet — [{clearance_m, speed_ms, grass_h_m}] (clearance —
## высота подошвы над землёй, speed_ms — скорость подошвы относительно земли, grass_h_m —
## высота травы под ней, GrassField.height_at). Ноги складываются по мощности (шумы независимы).
static func level(feet: Array, cfg: Dictionary) -> float:
	if not bool(cfg.get("enabled", true)):
		return 0.0
	var v0 := float(cfg.get("min_speed_ms", 0.25))
	var v1 := float(cfg.get("full_speed_ms", 3.0))
	var depth_full := float(cfg.get("full_depth_k", 0.6))
	var sum_sq := 0.0
	for f: Dictionary in feet:
		var h := float(f.get("grass_h_m", 0.0))
		if h <= 0.01:
			continue
		var depth := (h - maxf(float(f.get("clearance_m", 1e3)), 0.0)) / h
		var imm := smoothstep(0.0, depth_full, depth)
		var spd := smoothstep(v0, v1, float(f.get("speed_ms", 0.0)))
		var a := imm * spd
		sum_sq += a * a
	return clampf(sqrt(sum_sq), 0.0, 1.0)


## Громкость слоя, дБ: db при полном уровне; 0 → min_db.
static func level_to_db(lvl: float, cfg: Dictionary, min_db: float = -80.0) -> float:
	if lvl <= 0.0:
		return min_db
	return maxf(float(cfg.get("db", -14.0)) + 20.0 * log(lvl) / log(10.0), min_db)


## Высота тона от скорости ног: быстрее — выше (pitch_range, по full_speed_ms).
static func pitch_for(speed_ms: float, cfg: Dictionary) -> float:
	var pr: Array = cfg.get("pitch_range", [0.85, 1.25])
	var t := clampf(speed_ms / maxf(float(cfg.get("full_speed_ms", 3.0)), 0.1), 0.0, 1.0)
	return lerpf(float(pr[0]), float(pr[1]), t)


## Зацикленный звук: белый шум в полосе band_hz (ФВЧ + ФНЧ по кругу), умноженный на огибающую из
## случайных «зёрен» (grains_per_s в секунду, grain_ms) над постоянным шорохом (floor).
static func make_loop(cfg: Dictionary, seed_value: int = 7) -> AudioStreamWAV:
	var rate := int(cfg.get("sample_rate", 22050))
	var n := int(float(cfg.get("loop_s", 3.0)) * rate)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var band: Array = cfg.get("band_hz", [1200.0, 6500.0])
	var noise := PackedFloat32Array()
	noise.resize(n)
	for i in n:
		noise[i] = rng.randf_range(-1.0, 1.0)
	_circular_lowpass(noise, float(band[1]), rate)
	var lp := noise.duplicate()
	_circular_lowpass(lp, float(band[0]), rate)
	for i in n:
		noise[i] -= lp[i]  # ФВЧ = сигнал − ФНЧ
	var env := PackedFloat32Array()
	env.resize(n)
	var floor_k := float(cfg.get("floor", 0.15))
	for i in n:
		env[i] = floor_k
	var grains := int(float(cfg.get("grains_per_s", 35.0)) * float(n) / rate)
	var g_ms: Array = cfg.get("grain_ms", [8.0, 40.0])
	for _g in grains:
		var start := rng.randi_range(0, n - 1)
		var len_g := int(rng.randf_range(float(g_ms[0]), float(g_ms[1])) * 0.001 * rate)
		var amp := rng.randf_range(0.3, 1.0)
		for k in len_g:
			var w := 0.5 - 0.5 * cos(TAU * float(k) / len_g)
			var idx := (start + k) % n
			env[idx] += amp * w
	var peak := 1e-6
	for i in n:
		noise[i] *= env[i]
		peak = maxf(peak, absf(noise[i]))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(noise[i] / peak * 0.9, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav


## Однополюсный ФНЧ по кругу (два прохода — состояние на стыке сходится).
static func _circular_lowpass(buf: PackedFloat32Array, cutoff_hz: float, rate: int) -> void:
	var a := 1.0 - exp(-TAU * cutoff_hz / rate)
	var y := 0.0
	for _pass in 2:
		for i in buf.size():
			y += a * (buf[i] - y)
			buf[i] = y
