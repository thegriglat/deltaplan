extends TestCase
## RW-3a: потребители игры и мира работают через фасад W2 (docs/contracts/rust-wind.md). Здесь —
## то, что игра берёт у фасада сверх контрактных тестов: место из рельефа без остановки кадров
## (Atmosphere.place_from_terrain), поле Пикара внутри фасада, мягкая смена условий по часам,
## пустой воздух отвечает нулями, воздух по сети не ходит.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=rust_wind_consumers

const ID := "ongudai"


func _root() -> Node:
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	return tree_root.get_child(tree_root.get_child_count() - 1)


func _forecast(wind_from: float = 270.0) -> Dictionary:
	return {
		"forecast":
		{"temperature_c": 26.0, "wind_speed_kmh": 14.0, "wind_from_deg": wind_from, "sky": "clear"},
		"start_hour": 12.0,
		"speed": 1.0,
		"wind_ref": {"ref_msl": 1000.0, "gain_per_km": 1.0},
		"inflow_mode": "start",
	}


func _ready_up(a: Atmosphere, max_iter: int = 4000) -> bool:
	for i in max_iter:
		if a.is_ready():
			return true
		a.pump(8000)
		await (Engine.get_main_loop() as SceneTree).process_frame
	return a.is_ready()


func test_empty_air_answers_zero() -> void:
	var a := Atmosphere.new()
	a.visuals_enabled = false
	check(a.air_velocity_at(Vector3(10, 500, 10)) == Vector3.ZERO, "air_velocity_at до сборки — нули")
	check(a.mean_wind_at(Vector3(10, 500, 10)) == Vector3.ZERO, "mean_wind_at до сборки — нули")
	check(a.turbulence_intensity_at(Vector3(10, 500, 10)) == 0.0, "σ до сборки — 0")
	check(a.cloud_density_at(Vector3(10, 500, 10)) == 0.0, "облачность до сборки — 0")
	check(a.get_cloudbase_msl() == 0.0, "кромка до сборки — 0")
	check(a.thermals_near(Vector3.ZERO, 1000.0).is_empty(), "термиков до сборки нет")
	a.free()


func test_place_from_terrain_and_field_in_facade() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location(ID), "Онгудай загрузился")
	t.wait_relief()
	var utc := float(Config.get_config("locations/" + ID).get("utc_offset_h", NAN))
	var host := Node.new()
	_root().add_child(host)
	var a := Atmosphere.new()
	a.visuals_enabled = false
	host.add_child(a)
	# место без остановки кадров — те же растры, что у AirPlaceData.from_terrain
	var p: AirPlaceData = await a.place_from_terrain(t, utc, 7, 15)
	check(p != null and p.validate() == "", "place_from_terrain: место годится")
	var ref := AirPlaceData.from_terrain(t, utc, 7, 15)
	if p != null and ref != null:
		check(p.header.grid == ref.header.grid, "сетка та же")
		check(p.heights == ref.heights and p.water == ref.water, "высоты и вода те же")
		check(p.surface_cls == ref.surface_cls and p.surface_moist == ref.surface_moist, "поверхность та же")
		check(p.header.loc.climate == ref.header.loc.climate, "климат тот же")
		check(p.header.start_sites == ref.header.start_sites, "площадки те же")
	if p == null:
		a.free()
		host.queue_free()
		t.free()
		return
	# условия-прогноз + место из рельефа → поле Пикара внутри фасада (в headless: аналитика)
	check(a.configure(77) == 0, "configure(seed)")
	var cond := _forecast()
	cond["overrides"] = {"wind_from_deg": 123.0}  # «встречный»: румб игры поверх прогноза
	check(a.set_conditions(cond) == 0, "set_conditions: прогноз")
	check(a.load_place(p) == 0, "load_place")
	check(a.set_focuses(PackedVector3Array([Vector3(0, 900, 0)]), PackedFloat32Array([1.0])) == 0, "set_focuses")
	check(a.start_at(0.0) in [0, 3], "start_at(0) асинхронен (OK или NOT_READY до сборки)")
	var st0: Dictionary = a.status()
	check(int(st0.state) == Atmosphere.STATE_LOADING, "после start_at — LOADING")
	check(await _ready_up(a), "дошёл до READY")
	var st: Dictionary = a.status()
	check(a.runtime != null, "поле Пикара создано внутри фасада (место из рельефа + прогноз)")
	check(float(st.wind_progress) >= 1.0, "поле подано (в headless — аналитика): прогресс 1")
	check(String(st.wind) == "simple", "headless: подпись «упрощённый ветер»: %s" % st.wind)
	var w: Dictionary = a.get_weather()
	check(absf(float(w.wind_from_deg) - 123.0) < 1.0e-6, "румб игры поверх прогноза: %.1f" % w.wind_from_deg)
	check(absf(float(w.wind_speed_kmh) - 14.0) < 1.0e-6, "скорость — из прогноза")
	check(is_equal_approx(a.wind.ref_msl, 1000.0), "опора ветра — wind_ref")
	var q := Vector3(200.0, p.height_at(200.0, 0.0) + 120.0, 0.0)
	var s := a.sample(q)
	check(Vector3(s.x, s.y, s.z) == a.air_velocity_at(q), "sample (W2) = air_velocity_at (горячий путь модели полёта)")
	# условия-часы: те же, кроме часа и скорости — перепривязка хода дня без смены погоды
	var updated := [0]
	a.weather_updated.connect(func() -> void: updated[0] += 1)
	var w_before: Dictionary = a.get_weather()
	var c2 := cond.duplicate(true)
	c2["start_hour"] = 13.5
	c2["speed"] = 2.0
	check(a.set_conditions(c2) == 0, "set_conditions: другой час и скорость")
	check(updated[0] == 0, "перепривязка часов — без сигнала погоды")
	check(a.get_weather() == w_before, "погода не менялась")
	check(is_equal_approx(a.day.start_hour, 13.5) and is_equal_approx(a.day.speed, 2.0), "ход дня перепривязан")
	# смена места: выгрузка гасит поле и сбрасывает всё, что связано с местом
	a.unload_place()
	check(int(a.status().state) == Atmosphere.STATE_EMPTY, "unload_place — EMPTY")
	check(a.configure(78) == 0, "после unload_place configure снова можно")
	a.free()
	host.queue_free()
	t.free()


func test_net_does_not_sync_air() -> void:
	var zs: Dictionary = NetMessages.MESSAGES.get("ZoneState", {})
	check(not zs.has("thermalSources") and not zs.has("cloudField"), "ZoneState — только часы и очередь")
	var src := FileAccess.get_file_as_string("res://scripts/game/net_flight.gd")
	for tok in ["air_forced", "set_air_forced", "air_sources_mask", "apply_net_snapshot", "sync_thermal_sources", "sync_cloud_field"]:
		check(not src.contains(tok), "NetFlight без %s" % tok)
