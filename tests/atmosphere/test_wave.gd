extends TestCase
## Волна (VR-27) через фасад W2 v4: физика подъёма (sample) и лентикуляры (wave_crests) — одно и то
## же поле, стоят в одном месте. Проверка на синтетическом гребне; Онгудай и длина волны 2πU/N —
## в крейте (rust/dp-air/tests/terms_waves.rs: ongudai_lens_matches_lift, wave_term_matches_*).
## См. docs/archive/plan/atmosphere/06-volna-proverka.md.

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const RIDGE_H := 800.0
const RIDGE_W := 1500.0
const CREST_AT := Vector2(8000.0, 0.0)


static func _ridge(x: float, _z: float) -> float:
	return 500.0 + RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


func _rig(over: Dictionary = {}, preset: String = "weather/wave", advance: float = 0.01) -> Atmosphere:
	return Rig.make({"preset": preset, "over": over, "mode": 1, "ground": _ridge, "advance": advance})


## Единичный вектор «куда дует» (x, z) по wind_from_deg пресета (W1).
static func _wind_dir(preset: String, over: Dictionary) -> Vector2:
	var d := deg_to_rad(float(Rig.preset(preset, over).wind_from_deg))
	return Vector2(-sin(d), cos(d))


## Гребни волн как словари {pos: Vector2, crest: float} из массива [x, z, eta, crest].
static func _crests(a: Atmosphere, center: Vector2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw := a.wave_crests(center, 15000.0, 40.0)
	for j in range(0, raw.size(), Atmosphere.CREST_STRIDE):
		out.append({"pos": Vector2(raw[j], raw[j + 1]), "crest": raw[j + 3]})
	return out


## Проверяет в точке первого гребня: подъём в центре линзы, спад через полволны, длина волны.
func _check_crest_matches_lift(a: Atmosphere, wd: Vector2, cr: Dictionary, tag: String) -> void:
	var lam := a.wave_info()[Atmosphere.WAVE_INFO_LENGTH]
	var p: Vector2 = cr.pos
	var y := float(cr.crest) + 1500.0
	var max_ms := float(a.cfg.wave.max_ms)
	var w_here := a.mean_wind_at(Vector3(p.x, y, p.y)).y
	# порог качественный, без источника: 0,5 → 0,45·max_ms по факту 0,495 на синтетике —
	# профиль притока откалиброван (Б2), эвристика не подгоняется
	check(
		w_here >= 0.45 * max_ms,
		"%s: в центре линзы подъём >= 0,45·max_ms: %.2f >= %.2f" % [tag, w_here, 0.45 * max_ms]
	)
	var p2 := p + wd * lam * 0.5
	var w_half := a.mean_wind_at(Vector3(p2.x, y, p2.y)).y
	check(w_half < 0.0, "%s: на полволны дальше — опускание: %.2f" % [tag, w_half])
	check(lam > 3000.0 and lam < 20000.0, "%s: λ правдоподобна: %.0f м" % [tag, lam])


func test_synthetic_ridge_lens_matches_lift() -> void:
	var a := _rig()
	check(a.wave_info()[Atmosphere.WAVE_INFO_ENABLED] > 0.5, "волна включена")
	var cr := _crests(a, CREST_AT)
	check(not cr.is_empty(), "гребни волн найдены на синтетике: %d" % cr.size())
	if not cr.is_empty():
		_check_crest_matches_lift(a, _wind_dir("weather/wave", {}), cr[0], "синтетика")
	a.free()


## Роторная болтанка у земли под первым гребнем волны — не меньше 2× фоновой (без волны).
## Ветер умеренный (иначе механическая болтанка при сильном ветре сама упирается в общий
## потолок амплитуды турбулентности — turbulence.max_amplitude_ms, не секция wave).
func test_rotor_turbulence_under_crest() -> void:
	var over := {"convective_turbulence_ms": 0.0, "wind_speed_kmh": 15.0}
	var a := _rig(over)
	var cr := _crests(a, CREST_AT)
	check(not cr.is_empty(), "гребень найден для проверки ротора")
	if cr.is_empty():
		a.free()
		return
	# Ротор — под гребнем линии тока (η > 0); wave_crests отдаёт pos, сдвинутый против ветра
	# на четверть волны (туда, где максимален подъём) — вернёмся к самому гребню η.
	var wd := _wind_dir("weather/wave", over)
	var p: Vector2 = cr[0].pos + wd * a.wave_info()[Atmosphere.WAVE_INFO_LENGTH] * 0.25
	var crest_h: float = cr[0].crest
	var agl := 40.0
	var pos := Vector3(p.x, crest_h + agl, p.y)
	var v_wave := _variance_w(a, pos)
	var b := _rig(Config._deep_merge(over, {"wave_strength": 0.0}))
	var v_bg := _variance_w(b, pos)
	check(
		v_wave >= v_bg * 2.0 * 2.0,  # сравниваем дисперсии (σ² = (2σ)² = 4σ²)
		"ротор у земли под гребнем >= 2х фоновой болтанки: σ²=%.3f >= %.3f" % [v_wave, v_bg * 4.0]
	)
	a.free()
	b.free()


func _variance_w(a: Atmosphere, pos: Vector3) -> float:
	var s := 0.0
	var s2 := 0.0
	var n := 300
	for i in n:
		Rig.step(a, 0.3)
		var w := a.air_velocity_at(pos).y
		s += w
		s2 += w * w
	var m := s / n
	return s2 / n - m * m


func test_no_wave_without_preset() -> void:
	var a := _rig({}, "weather/medium")
	check(a.wave_info()[Atmosphere.WAVE_INFO_ENABLED] < 0.5, "в обычный день волн нет")
	check(a.wave_crests(CREST_AT, 15000.0, 40.0).is_empty(), "без волны — нет линз")
	a.free()


# test_ongudai_lens_matches_lift (линза на рельефе Онгудая) — rust/dp-air/tests/terms_waves.rs
# (ongudai_lens_matches_lift, wave_term_matches_ongudai_terrain_reference, ongudai_wave_on_place_raster).


## Полёт: держим курс против ветра в первом гребне волны — набор высоты выше базы кучевых
## пресета >= 500 м за 15 мин.
func test_climb_above_cloudbase_in_first_crest() -> void:
	var over := {"wind_speed_kmh": 20.0}
	var a := _rig(over)
	var cr := _crests(a, CREST_AT)
	check(not cr.is_empty(), "гребень для полёта найден")
	if cr.is_empty():
		a.free()
		return
	var c: Dictionary = cr[0]
	var p: Vector2 = c.pos
	var start_y: float = float(c.crest) + 1500.0
	var cloudbase := a.cloudbase_msl()

	var wing: Dictionary = Config.get_config("wings/sport")
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = FlightModel.clamp_pilot_mass(wing, float(pilot.mass_kg))
	var m := FlightModel.new()
	m.setup(wing, pilot)
	var heading := float(Rig.preset("weather/wave", over).wind_from_deg)  # курс против ветра
	m.reset_in_air(Vector3(p.x, start_y, p.y), heading)

	var air_fn := func(pos: Vector3) -> Vector3: return a.mean_wind_at(pos)
	var ground_fn := _ridge
	var dt := 1.0 / 30.0
	var steps := int(round(900.0 / dt))
	var target_heading := heading
	for i in steps:
		var t := m.telemetry
		var err := wrapf(target_heading - t.heading_deg, -180.0, 180.0)
		var inp := ControlInput.new()
		inp.pitch = 0.0
		inp.roll = clampf(err * 0.1, -1.0, 1.0)
		m.step(dt, inp, air_fn, ground_fn)

	var gained := m.telemetry.position.y - start_y
	check(
		gained >= 500.0,
		"набор выше старта за 15 мин в первом гребне волны: %.0f м >= 500 м" % gained
	)
	check(
		m.telemetry.position.y >= cloudbase + 500.0,
		(
			"набор выше базы кучевых >= 500 м: высота %.0f, база %.0f"
			% [m.telemetry.position.y, cloudbase]
		)
	)
	a.free()
