extends TestCase
## Волна (VR-27): физика подъёма (WaveField.sample) и лентикуляры (WaveField.crests) —
## одно и то же поле, стоят в одном месте. Проверка на синтетическом гребне и на Онгудае.
## См. docs/plan/atmosphere/06-volna-proverka.md.

const RIDGE_H := 800.0
const RIDGE_W := 1500.0


static func _ridge(x: float, _z: float) -> float:
	return 500.0 + RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo(weather_over: Dictionary = {}, preset: String = "weather/wave") -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config(preset), weather_over)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	return a


## Проверяет в точке первого гребня: подъём в центре линзы, спад через полволны, длина волны.
func _check_crest_matches_lift(a: Atmosphere, cr: Dictionary, tag: String) -> void:
	var lam := a.wave.wavelength()
	var wd := Vector2(a.wind.dir.x, a.wind.dir.z)
	var p: Vector2 = cr.pos
	var y := float(cr.crest) + 1500.0
	var max_ms := float(a.cfg.wave.max_ms)
	var w_here := a.air_velocity_at(Vector3(p.x, y, p.y)).y
	check(
		w_here >= 0.5 * max_ms,
		"%s: в центре линзы подъём >= половины max_ms: %.2f >= %.2f" % [tag, w_here, 0.5 * max_ms]
	)
	var p2 := p + wd * lam * 0.5
	var w_half := a.air_velocity_at(Vector3(p2.x, y, p2.y)).y
	check(w_half < 0.0, "%s: на полволны дальше — опускание: %.2f" % [tag, w_half])
	var n := float(a.wave._n_bv)
	var u := a.wind.speed_at(float(a.cfg.wave.wind_reference_agl_m))
	var lam_expected := TAU * u / n
	check(
		absf(lam - lam_expected) < lam_expected * 0.1,
		"%s: λ совпадает с 2πU/N ± 10%%: %.0f ~ %.0f" % [tag, lam, lam_expected]
	)


func test_synthetic_ridge_lens_matches_lift() -> void:
	var a := _atmo({"thermal_mode": "static"})
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	check(a.wave.enabled, "волна включена")
	var cr: Array = a.wave.crests(Vector3(8000, 0, 0), 15000.0, 40.0)
	check(not cr.is_empty(), "гребни волн найдены на синтетике: %d" % cr.size())
	if not cr.is_empty():
		_check_crest_matches_lift(a, cr[0], "синтетика")
	a.free()


## Роторная болтанка у земли под первым гребнем волны — не меньше 2× фоновой (без волны).
## Ветер умеренный (иначе механическая болтанка при сильном ветре сама упирается в общий
## потолок амплитуды турбулентности — turbulence.max_amplitude_ms, не секция wave).
func test_rotor_turbulence_under_crest() -> void:
	var over := {"thermal_mode": "static", "convective_turbulence_ms": 0.0, "wind_speed_kmh": 15.0}
	var a := _atmo(over)
	a.set_ground(_ridge, _sun)
	a.turbulence_enabled = true
	a.step(0.01)
	var cr: Array = a.wave.crests(Vector3(8000, 0, 0), 15000.0, 40.0)
	check(not cr.is_empty(), "гребень найден для проверки ротора")
	if cr.is_empty():
		a.free()
		return
	# Ротор — под гребнем линии тока (η > 0); crests() отдаёт pos, сдвинутый против ветра
	# на четверть волны (туда, где максимален подъём) — вернёмся к самому гребню η.
	var wd := Vector2(a.wind.dir.x, a.wind.dir.z)
	var p: Vector2 = cr[0].pos + wd * a.wave.wavelength() * 0.25
	var crest_h: float = cr[0].crest
	var agl := 40.0
	var pos := Vector3(p.x, crest_h + agl, p.y)
	var v_wave := _variance_w(a, pos)
	var b := _atmo(Config._deep_merge(over, {"wave_strength": 0.0}))
	b.set_ground(_ridge, _sun)
	b.turbulence_enabled = true
	b.step(0.01)
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
		a.time_s = i * 0.3
		var w := a.air_velocity_at(pos).y
		s += w
		s2 += w * w
	var m := s / n
	return s2 / n - m * m


func test_no_wave_without_preset() -> void:
	var a := _atmo({"thermal_mode": "static"}, "weather/medium")
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	check(not a.wave.enabled, "в обычный день волн нет")
	check(a.wave.crests(Vector3(8000, 0, 0), 15000.0, 40.0).is_empty(), "без волны — нет линз")
	a.free()


func test_ongudai_lens_matches_lift() -> void:
	var t := Terrain.new()
	t.location_id = ""
	var ok := t.load_location("ongudai")
	check(ok, "Онгудай загружен")
	if not ok:
		t.free()
		return
	var a := _atmo({"thermal_mode": "static", "wind_from_deg": 340.0, "wind_speed_kmh": 40.0})
	a.set_ground(t.height_at, func(_x: float, _z: float) -> float: return 1.0)
	a.step(0.01)
	check(a.wave.enabled, "волна включена на Онгудае")
	var site: Dictionary = t.get_start_sites()[0]
	var center: Vector3 = site.position
	var cr: Array = a.wave.crests(center, 15000.0, 40.0)
	check(not cr.is_empty(), "гребни волн найдены на Онгудае: %d" % cr.size())
	if not cr.is_empty():
		_check_crest_matches_lift(a, cr[0], "Онгудай")
	t.free()
	a.free()


## Полёт: держим курс против ветра в первом гребне волны — набор высоты выше базы кучевых
## пресета >= 500 м за 15 мин.
func test_climb_above_cloudbase_in_first_crest() -> void:
	var a := _atmo({"thermal_mode": "static", "wind_speed_kmh": 20.0})
	a.set_ground(_ridge, _sun)
	a.step(0.01)
	var cr: Array = a.wave.crests(Vector3(8000, 0, 0), 15000.0, 40.0)
	check(not cr.is_empty(), "гребень для полёта найден")
	if cr.is_empty():
		a.free()
		return
	var c: Dictionary = cr[0]
	var p: Vector2 = c.pos
	var start_y: float = float(c.crest) + 1500.0
	var cloudbase := a.get_cloudbase_msl()

	var wing: Dictionary = Config.get_config("wings/sport")
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = FlightModel.clamp_pilot_mass(wing, float(pilot.mass_kg))
	var m := FlightModel.new()
	m.setup(wing, pilot)
	var heading := a.wind.from_deg  # курс против ветра (см. WindModel.set_wind / heading_dir)
	m.reset_in_air(Vector3(p.x, start_y, p.y), heading)

	var air_fn := func(pos: Vector3) -> Vector3: return a.air_velocity_at(pos)
	var ground_fn := _ridge
	var dt := 1.0 / 30.0
	var steps := int(round(900.0 / dt))
	var target_heading := heading
	for i in steps:
		a.time_s += dt
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
