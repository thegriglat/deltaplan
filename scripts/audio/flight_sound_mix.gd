class_name FlightSoundMix
extends RefCounted
## Логика звуков полёта (FR-28) без нод — тестируется headless.
## Вход — поля состояния (set_state), выход — громкости и высоты тона лупов (compute)
## и события разовых звуков (advance). Воспроизведение — в FlightAudio.
## Алгоритмы — docs/research/sounds.md §3, числа — configs/audio.json → flight.

## Имена лупов (совпадают с ключами files в конфиге).
const AIRFLOW_LOOPS: PackedStringArray = ["rush", "rumble", "wires", "ears", "fast"]
const SAIL_LOOPS: PackedStringArray = ["wing", "luff"]
const RUN_LOOPS: PackedStringArray = ["breath"]
const AMBIENT_LOOPS: PackedStringArray = ["meadow", "birds", "cowbells", "grass", "gusts"]

# Состояние (СИ, кроме скорости в км/ч — формулы из исследования в км/ч).
var airspeed_kmh: float = 0.0
var groundspeed_ms: float = 0.0
var agl_m: float = 0.0
var phase: String = "standing"
var stall_amount: float = 0.0
var turbulence: float = 0.0
var sideslip_deg: float = 0.0
var load_factor: float = 1.0
var ground_wind_ms: float = 0.0
var surface: String = "grass"

var _cfg: Dictionary = {}
var _air: Dictionary = {}
var _sail: Dictionary = {}
var _frame: Dictionary = {}
var _run: Dictionary = {}
var _amb: Dictionary = {}
var _min_db: float = -80.0
var _rng := RandomNumberGenerator.new()
var _step_timer_s: float = 0.0
var _run_time_s: float = 0.0
var _prev_phase: String = "standing"
var _pant_in_s: float = -1.0


## cfg — раздел flight из configs/audio.json.
func setup(cfg: Dictionary, seed_value: int = 0) -> void:
	_cfg = cfg
	_air = cfg.get("airflow", {})
	_sail = cfg.get("sail", {})
	_frame = cfg.get("frame", {})
	_run = cfg.get("run", {})
	_amb = cfg.get("ambient", {})
	_min_db = float(cfg.get("min_db", -80.0))
	surface = String(_run.get("surface_default", "grass"))
	ground_wind_ms = float(_amb.get("wind_default_ms", 3.0))
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


## Состояние из телеметрии и extra (phase, stall_amount, turbulence, sideslip_deg,
## load_factor, ground_wind_ms, surface — всё необязательно).
func set_state(t: Telemetry, extra: Dictionary) -> void:
	airspeed_kmh = Units.to_kmh(t.airspeed)
	groundspeed_ms = t.groundspeed
	agl_m = maxf(t.altitude_agl, 0.0)
	var default_phase := "landed" if t.on_ground else "flying"
	phase = String(extra.get("phase", default_phase))
	var stall_default := 1.0 if t.stalled else 0.0
	stall_amount = clampf(float(extra.get("stall_amount", stall_default)), 0.0, 1.0)
	turbulence = clampf(float(extra.get("turbulence", 0.0)), 0.0, 1.0)
	sideslip_deg = float(extra.get("sideslip_deg", 0.0))
	# Перегрузка: из extra, иначе — координированный вираж 1/cos(крен).
	var bank := deg_to_rad(clampf(absf(t.bank_deg), 0.0, 80.0))
	load_factor = float(extra.get("load_factor", 1.0 / cos(bank)))
	ground_wind_ms = float(extra.get("ground_wind_ms", _amb.get("wind_default_ms", 3.0)))
	surface = String(extra.get("surface", _run.get("surface_default", "grass")))


## Громкости и высоты тона: {имя_лупа: Vector2(дБ, pitch_scale)}, плюс "lp_cutoff_hz", "pan".
func compute() -> Dictionary:
	var out := {}
	_compute_airflow(out)
	_compute_sail(out)
	_compute_run(out)
	_compute_ambient(out)
	return out


## Продвинуть время на dt, вернуть события разовых звуков: [{type, gain_db, pitch}],
## type — "step", "snap", "creak", "pant".
func advance(dt: float) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	_advance_steps(dt, events)
	_advance_poisson(dt, events)
	_advance_breath(dt, events)
	_prev_phase = phase
	return events


## Запланировать одышку через delay_s (после посадки).
func schedule_pant(delay_s: float) -> void:
	_pant_in_s = delay_s


## Поправка громкости удара по вертикальной скорости, дБ.
func landing_gain_db(result: Dictionary) -> float:
	var lnd: Dictionary = _cfg.get("landing", {})
	var grade := String(result.get("grade", "soft"))
	var base := float(lnd.get(grade + "_db", 0.0))
	var vz := absf(float(result.get("vertical_speed_ms", lnd.get("impact_ref_ms", 3.0))))
	var ref := float(lnd.get("impact_ref_ms", 3.0))
	var rng_db: Array = lnd.get("impact_range_db", [-6.0, 3.0])
	var corr := 20.0 * log(maxf(vz, 0.01) / ref) / log(10.0)
	return base + clampf(corr, float(rng_db[0]), float(rng_db[1]))


## Случайное число 0..1 (общий генератор — воспроизводимо с seed).
func randf01() -> float:
	return _rng.randf()


func rand_jitter(amount: float) -> float:
	return _rng.randf_range(-amount, amount)


# ---------- Лупы ----------


func _compute_airflow(out: Dictionary) -> void:
	var v := maxf(airspeed_kmh, 0.0)
	var r := maxf(v / float(_air.get("v_ref_kmh", 40.0)), 1e-4)
	var lg := log(r) / log(10.0)
	var rush := _cap(float(_air.rush_db) + 10.0 * float(_air.rush_exp) * lg, "rush_max_db")
	var prange: Array = _air.get("rush_pitch_range", [0.4, 2.5])
	out["rush"] = Vector2(rush, clampf(r, float(prange[0]), float(prange[1])))
	var rumble := float(_air.rumble_db) + 10.0 * float(_air.rumble_exp) * lg
	rumble = _cap(rumble, "rumble_max_db")
	# Болтанка и срыв потока прибавляются только когда поток вообще есть.
	var presence := _smooth(_pair(_air, "ears_in_kmh"), v)
	rumble += (
		(float(_air.turb_gain_db) * turbulence + float(_air.stall_buffet_db) * stall_amount)
		* presence
	)
	out["rumble"] = Vector2(rumble, 0.7 + 0.3 * r)
	var wires := _cap(float(_air.wires_db) + 10.0 * float(_air.wires_exp) * lg, "wires_max_db")
	wires += _db(_smooth(_pair(_air, "wires_on_kmh"), v))
	out["wires"] = Vector2(wires, r)
	var ears_gain := presence * (1.0 - _smooth(_pair(_air, "ears_fade_kmh"), v))
	out["ears"] = Vector2(float(_air.ears_db) + _db(ears_gain), 1.0)
	var fast_gain := _smooth(_pair(_air, "fast_fade_kmh"), v)
	out["fast"] = Vector2(float(_air.fast_db) + _db(fast_gain), 0.85 + 0.15 * r)
	var cutoff := float(_air.lp_base_hz) + float(_air.lp_per_kmh_hz) * v
	out["lp_cutoff_hz"] = minf(cutoff, float(_air.lp_max_hz))
	var beta := float(_air.pan_beta_deg)
	out["pan"] = clampf(sideslip_deg / beta, -1.0, 1.0) * float(_air.pan_max)


func _compute_sail(out: Dictionary) -> void:
	var v := maxf(airspeed_kmh, 0.0)
	var r := maxf(v / float(_air.get("v_ref_kmh", 40.0)), 1e-4)
	var lg := log(r) / log(10.0)
	var nz := maxf(load_factor, 0.1)
	var wing := float(_sail.wing_db) + 40.0 * lg + 20.0 * log(nz) / log(10.0)
	out["wing"] = Vector2(_cap_in(wing, _sail, "wing_max_db"), 0.9 + 0.2 * r)
	var s := luff_amount()
	out["luff"] = Vector2(float(_sail.luff_db) + _db(s), 0.8 + 0.4 * r)


## Сила трепетания паруса 0..1: малая скорость или сваливание, но только при потоке.
func luff_amount() -> float:
	var v := maxf(airspeed_kmh, 0.0)
	var sp: Vector2 = _pair(_sail, "luff_speed_kmh")
	var low := 1.0 - smoothstep(sp.x, sp.y, v)
	var flow := _smooth(_pair(_sail, "luff_min_airspeed_kmh"), v)
	return clampf(maxf(low, stall_amount) * flow, 0.0, 1.0)


func _compute_run(out: Dictionary) -> void:
	var db := _min_db
	if phase == "running":
		var ramp := clampf(_run_time_s / maxf(float(_run.breath_ramp_s), 0.01), 0.0, 1.0)
		db = lerpf(float(_run.breath_start_db), float(_run.breath_db), ramp)
	out["breath"] = Vector2(db, 1.0)


func _compute_ambient(out: Dictionary) -> void:
	var near := 1.0 - _smooth(_pair(_amb, "agl_fade_m"), agl_m)
	var cow := 1.0 - _smooth(_pair(_amb, "cowbells_agl_fade_m"), agl_m)
	var w_ref := float(_amb.wind_ref_ms)
	var wind_db := 20.0 * log(maxf(ground_wind_ms, 0.01) / w_ref) / log(10.0)
	wind_db = minf(wind_db, float(_amb.wind_max_db_over))
	out["meadow"] = Vector2(float(_amb.meadow_db) + _db(near), 1.0)
	out["birds"] = Vector2(float(_amb.birds_db) + _db(near), 1.0)
	out["cowbells"] = Vector2(float(_amb.cowbells_db) + _db(cow), 1.0)
	out["grass"] = Vector2(float(_amb.grass_db) + wind_db + _db(near), 1.0)
	out["gusts"] = Vector2(float(_amb.gusts_db) + wind_db + _db(near), 1.0)
	for k in AMBIENT_LOOPS:
		var p: Vector2 = out[k]
		out[k] = Vector2(maxf(p.x, _min_db), p.y)


# ---------- События ----------


func _advance_steps(dt: float, events: Array[Dictionary]) -> void:
	var walking := phase == "walking"
	var running := phase == "running"
	if not (walking or running):
		_step_timer_s = 0.0
		return
	var stride := float(_run.stride_run_m if running else _run.stride_walk_m)
	var interval := stride / maxf(groundspeed_ms, 0.01)
	if interval > float(_run.max_step_interval_s):
		_step_timer_s = 0.0
		return
	interval = maxf(interval, float(_run.min_step_interval_s))
	_step_timer_s += dt
	if _step_timer_s >= interval:
		_step_timer_s = fmod(_step_timer_s, interval)
		var base := float(_run.step_db if running else _run.step_walk_db)
		var ev := {"type": "step", "surface": surface}
		ev["gain_db"] = base + rand_jitter(float(_run.step_gain_jitter_db))
		ev["pitch"] = 1.0 + rand_jitter(float(_run.step_pitch_jitter))
		events.append(ev)


func _advance_poisson(dt: float, events: Array[Dictionary]) -> void:
	# Хлопки паруса: λ = rate · s².
	var s := luff_amount()
	var lam := float(_sail.snap_rate_hz) * s * s
	if lam > 0.0 and _rng.randf() < 1.0 - exp(-lam * dt):
		var pitch := 1.0 + rand_jitter(float(_sail.snap_pitch_jitter))
		events.append({"type": "snap", "gain_db": float(_sail.snap_db) + _db(s), "pitch": pitch})
	# Скрипы каркаса: нагрузка от перегрузки и болтанки, только в полёте.
	if phase != "flying":
		return
	var lr: Vector2 = _pair(_frame, "creak_load_range")
	var load := smoothstep(lr.x, lr.y, load_factor)
	load = clampf(load + turbulence * float(_frame.creak_turb_weight), 0.0, 1.0)
	var lam_c := float(_frame.creak_rate_hz) * load
	if lam_c > 0.0 and _rng.randf() < 1.0 - exp(-lam_c * dt):
		var jit := rand_jitter(float(_frame.creak_gain_jitter_db))
		events.append({"type": "creak", "gain_db": float(_frame.creak_db) + jit, "pitch": 1.0})


func _advance_breath(dt: float, events: Array[Dictionary]) -> void:
	if phase == "running":
		_run_time_s += dt
	elif _prev_phase == "running":
		# Остановились на земле после долгого бега — одышка; взлетели — просто успокоились.
		var stopped := phase != "flying"
		if stopped and _run_time_s >= float(_run.pant_min_run_s):
			events.append({"type": "pant", "gain_db": float(_run.pant_db), "pitch": 1.0})
		_run_time_s = 0.0
	if _pant_in_s >= 0.0:
		_pant_in_s -= dt
		if _pant_in_s < 0.0:
			events.append({"type": "pant", "gain_db": float(_run.pant_db), "pitch": 1.0})


# ---------- Вспомогательные ----------


## Линейная громкость 0..1 → дБ (с нижним пределом).
func _db(gain: float) -> float:
	if gain <= 0.0:
		return _min_db
	return maxf(20.0 * log(gain) / log(10.0), _min_db)


func _cap(db: float, key: String) -> float:
	return _cap_in(db, _air, key)


func _cap_in(db: float, section: Dictionary, key: String) -> float:
	return clampf(db, _min_db, float(section.get(key, 0.0)))


func _smooth(range_v: Vector2, x: float) -> float:
	return smoothstep(range_v.x, range_v.y, x)


static func _pair(section: Dictionary, key: String) -> Vector2:
	var a: Array = section.get(key, [0.0, 1.0])
	return Vector2(float(a[0]), float(a[1]))
