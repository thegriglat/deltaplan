extends TestCase
## Логика интеграции без сцены: старт на склоне, статистика, опции запуска,
## выбор меню, пользовательские настройки, заглушка воздуха, атрибуция, экран итога.

const TMP_DIR := "user://test_game_tmp"


func _slope_cfg() -> Dictionary:
	return Config.get_config("game").start_search


## Плоскость, падающая на восток под углом deg.
func _plane_east(deg: float) -> Callable:
	var k := tan(deg_to_rad(deg))
	return func(x: float, _z: float) -> float: return 1000.0 - k * x


func test_start_placement_downhill_heading() -> void:
	var r := StartPlacement.find_launch(_plane_east(20.0), 0.0, 0.0, _slope_cfg())
	check(r.ok, "склон 20° пригоден")
	approx(float(r.heading_deg), 90.0, 1.0, "курс вниз по склону — на восток")
	approx(float(r.slope_deg), 20.0, 0.5, "уклон")
	# Склон на север (высота растёт к югу, +Z): курс 0.
	var north := func(_x: float, z: float) -> float: return 500.0 + z * tan(deg_to_rad(18.0))
	var r2 := StartPlacement.evaluate(north, 0.0, 0.0, _slope_cfg())
	approx(float(r2.heading_deg), 0.0, 1.0, "курс на север")


func test_start_placement_finds_slope_nearby() -> void:
	# Ровное плато до x = 200, дальше склон 22° на восток.
	var k := tan(deg_to_rad(22.0))
	var f := func(x: float, _z: float) -> float: return 800.0 - k * maxf(x - 200.0, 0.0)
	var r := StartPlacement.find_launch(f, 0.0, 0.0, _slope_cfg())
	check(r.ok, "нашёл склон рядом с плато")
	check((r.position as Vector3).x > 200.0, "старт на склоне, а не на плато")
	approx(float(r.heading_deg), 90.0, 2.0, "курс вниз по склону")
	var flat := func(_x: float, _z: float) -> float: return 300.0
	var r2 := StartPlacement.find_launch(flat, 5.0, 7.0, _slope_cfg())
	check(not r2.ok, "на ровном месте склона нет")
	approx((r2.position as Vector3).x, 5.0, 0.01, "старт в самой точке")


func test_flight_stats() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	var t := Telemetry.new()
	t.phase = "running"
	t.position = Vector3(0, 1000, -5)
	st.update(t, 0.1)
	check(not st.took_off, "на разбеге ещё не взлетел")
	t.phase = "flying"
	for i in 100:
		t.position = Vector3(0, 1000 + i * 0.1, -10.0 - i)
		t.altitude_msl = t.position.y
		t.vario = 1.0
		st.update(t, 0.1)
	check(st.took_off, "взлёт")
	approx(st.flight_time_s, 10.0, 0.01, "время в воздухе")
	approx(st.track_length_m, 99.0, 0.5, "путь по следу")
	var sm := st.summary(t.position)
	approx(float(sm.distance_m), 99.0, 0.5, "дистанция от взлёта")
	approx(float(sm.height_gain_m), 9.9, 0.2, "набор")


func test_launch_options() -> void:
	var o := LaunchOptions.parse(
		PackedStringArray(
			[
				"--autostart",
				"--screenshot=/tmp/x.png",
				"--time=12.5",
				"--camera=chase",
				"--wing=training",
				"--latlon=51.5,85.5",
				"--look=30,-20",
				"--filter=game"
			]
		)
	)
	check(o.autostart and not o.smoke, "флаги")
	check(o.screenshot == "/tmp/x.png", "путь скриншота")
	approx(o.time_s, 12.5, 1e-6, "время")
	check(o.camera == "chase", "камера")
	approx(o.look.x, 30.0, 1e-6, "поворот головы")
	var s := o.apply_to(FlightSettings.defaults())
	check(s.wing == "wings/training", "крыло из аргумента")
	check(s.has_pick(), "точка с карты")
	approx(s.pick_lat, 51.5, 1e-6, "широта")
	var smoke := LaunchOptions.parse(PackedStringArray(["--smoke"]))
	check(smoke.autostart and smoke.autopilot, "smoke = автостарт + автопилот")
	check(LaunchOptions.parse(PackedStringArray(["--pause"])).autostart, "--pause — в полёте")


func test_flight_settings_roundtrip() -> void:
	var s := FlightSettings.defaults()
	check(Config.list_configs("wings").has(s.wing), "крыло по умолчанию существует")
	check(s.temperature_c >= 0.0 and s.temperature_c <= 40.0, "температура по умолчанию в диапазоне")
	s.pilot_mass_kg = 77.0
	s.site_id = "tugaya_south"
	var d := FlightSettings.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(d.site_id == "tugaya_south" and d.pilot_mass_kg == 77.0, "запись/чтение")
	check(not d.has_pick(), "без точки на карте")
	check(d.wing_id() == s.wing.get_file(), "id крыла для Glider")


func test_forecast_settings() -> void:
	var def := FlightSettings.defaults()
	# Мусор — в диапазон меню (UserSettings.load_last_flight).
	var path := TMP_DIR.path_join("last_flight.json")
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"temperature_c": 99, "wind_speed_kmh": -5, "wind_from_deg": 725}))
	f.close()
	var loaded := UserSettings.load_last_flight(path)
	approx(loaded.temperature_c, 40.0, 1e-6, "жара зажата")
	approx(loaded.wind_speed_kmh, 0.0, 1e-6, "ветер не отрицательный")
	approx(loaded.wind_from_deg, 5.0, 1e-6, "направление по кругу")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TMP_DIR)
	# Туда-обратно без потерь.
	var s := FlightSettings.defaults()
	s.temperature_c = -7.0
	s.wind_speed_kmh = 25.2
	s.wind_into_launch = false
	s.wind_from_deg = 135.0
	var r := FlightSettings.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(r.forecast() == s.forecast(), "прогноз туда-обратно")
	check(not r.wind_into_launch, "направление туда-обратно")
	# По умолчанию — обычный максимум для даты по умолчанию.
	approx(def.temperature_c, roundf(WeatherModel.typical_max_c(def.month, def.day)), 1.0, "умолчание")


func test_unknown_wing_default() -> void:
	# Нет такого конфига крыла в last_flight.json — крыло по умолчанию, остальное как записано.
	var path := TMP_DIR.path_join("last_flight.json")
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"wing": "wings/no_such_wing", "pilot_mass_kg": 90}))
	f.close()
	var loaded := UserSettings.load_last_flight(path)
	var def := FlightSettings.defaults().wing
	check(loaded.wing == def, "last_flight: нет крыла → %s (%s)" % [def, loaded.wing])
	approx(loaded.pilot_mass_kg, 90.0, 1e-6, "масса сохранилась")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TMP_DIR)


func test_forecast_launch_options() -> void:
	var o := LaunchOptions.parse(PackedStringArray(["--temp=31", "--wind=5", "--from=launch"]))
	var s := o.apply_to(FlightSettings.defaults())
	approx(s.temperature_c, 31.0, 1e-6, "--temp")
	approx(s.wind_speed_kmh, 18.0, 1e-6, "--wind в м/с")
	check(s.wind_into_launch, "--from=launch")
	s = LaunchOptions.parse(PackedStringArray(["--from=225"])).apply_to(s)
	check(not s.wind_into_launch, "--from=<град>")
	approx(s.wind_from_deg, 225.0, 1e-6, "направление")


func test_user_settings_merge() -> void:
	var path := TMP_DIR.path_join("controls.json")
	UserSettings.save_patch("controls", {"mouse": {"mode": "bar"}}, TMP_DIR)
	UserSettings.save_patch("controls", {"invert_pitch": true}, TMP_DIR)
	var d := UserSettings.read_json(path)
	check(d.get("invert_pitch") == true, "второй патч записан")
	check(d.get("mouse", {}).get("mode") == "bar", "первый патч сохранился")
	check(not d.has("keys"), "в user-файл пишется только изменённое")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(TMP_DIR)


func test_calm_air_contract() -> void:
	var a := CalmAir.new()
	a.set_weather({"wind_speed_kmh": 18.0, "wind_from_deg": 270.0, "cloudbase_agl_m": 1500})
	a.set_ground(func(_x: float, _z: float) -> float: return 100.0, Callable())
	var v := a.air_velocity_at(Vector3(5000, 600, 5000))
	approx(v.x, 5.0, 0.01, "западный ветер дует на восток")
	approx(v.z, 0.0, 0.01, "без составляющей север-юг")
	check(v.y < 0.0, "между термиками опускание")
	a.add_static_thermal(0.0, 0.0, 3.0, 100.0)
	a.set_wind(0.0, 0.0)
	approx(a.air_velocity_at(Vector3(0, 600, 0)).y, 2.5, 0.05, "в ядре 3 − 0,5 м/с")
	approx(a.air_velocity_at(Vector3(0, 100, 0)).y, 0.0, 0.01, "у земли потоки гаснут")
	a.free()


func test_assets_credits_parse() -> void:
	var md := (
		"# Ассеты\n## Звуки\n| Файл | Что | Источник | Лицензия | Где |\n|---|---|---|---|---|\n"
		+ "| `a.ogg` | шум | [freesound 1](https://freesound.org/s/1/) Автор | **CC-BY 4.0** | x |\n"
		+ "\nтекст\n## Шрифты\n| Файл | Что | Источник | Лицензия | Где |\n|---|---|---|---|---|\n"
		+ "| `f.ttf` | цифры | DSEG | OFL 1.1 | прибор |\n"
	)
	var tables := AssetsCredits.parse_tables(md)
	check(tables.size() == 2, "две таблицы (%d)" % tables.size())
	check(tables[0].title == "Звуки" and tables[0].rows.size() == 1, "раздел и строка")
	var text := AssetsCredits.to_bbcode(tables, {"res://L.txt": "Licence [x]"})
	check(text.contains("freesound 1 (https://freesound.org/s/1/) Автор"), "ссылка раскрыта")
	check(text.contains("CC-BY 4.0") and not text.contains("**"), "разметка убрана")
	check(text.contains("Licence [lb]x]"), "BBCode экранирован")
	var real := AssetsCredits.build_text(["res://ASSETS.md"], [])
	check(real.contains("Copernicus") and real.contains("J.Zazvurek"), "ASSETS.md: данные и CC-BY")


func test_result_texts() -> void:
	var was_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("ru")
	await _test_result_texts_impl()
	TranslationServer.set_locale(was_locale)


func _test_result_texts_impl() -> void:
	check(ResultScreen.format_time(65.0) == "1:05", "мм:сс")
	check(ResultScreen.format_time(3725.0) == "1:02:05", "чч:мм:сс")
	var info := {"grade": "soft", "vertical_speed_ms": 1.2, "horizontal_speed_ms": 5.0}
	check(ResultScreen.title_for("landed", info) == "Мягкая посадка", "заголовок посадки")
	check(ResultScreen.lines_for("landed", info).size() >= 4, "строки итога")
	var fail := {"reason": "wingtip", "text": GroundRun.failure_text("wingtip")}
	check(ResultScreen.title_for("takeoff_failed", fail) == "Взлёт сорван", "срыв взлёта")
	check(ResultScreen.lines_for("takeoff_failed", fail)[0].contains("Консоль"), "причина")


func test_cloud_whiteout() -> void:
	var w := CloudWhiteout.new()
	w.setup({"density_gain": 1.5, "rise_time_s": 0.3, "fog_density": 0.06})
	for i in 60:
		w.update(1.0, 1.0 / 60.0)
	check(w.amount > 0.95, "в плотном облаке — полная мгла (%.2f)" % w.amount)
	var env := Environment.new()
	env.fog_density = 5e-5
	w.apply(env)
	check(env.fog_density > 0.05 and env.fog_sky_affect > 0.95, "туман густой, небо тоже в мгле")
	for i in 240:
		w.update(0.0, 1.0 / 60.0)
	w.apply(env)
	check(w.amount == 0.0, "вышел из облака — мгла ушла")
	approx(env.fog_density, 5e-5, 1e-9, "исходный туман вернулся")


func test_pilot_animator_sequence() -> void:
	var root := Node3D.new()
	var ap := AnimationPlayer.new()
	root.add_child(ap)
	var lib := AnimationLibrary.new()
	for a: String in ["stand", "walk", "run", "run_air", "climb_in", "prone", "climb_out", "flare"]:
		var anim := Animation.new()
		anim.length = 1.5 if a in ["run_air", "climb_in", "climb_out"] else 1.0
		lib.add_animation(a, anim)
	ap.add_animation_library("", lib)
	var pa := PilotAnimator.new()
	pa.bind(root, Config.get_config("game").pilot_animation)
	check(pa.current() == "stand", "после загрузки — stand")
	pa.update("running", 0.0, 0.0, 0.0, 0.1)
	check(pa.current() == "run", "разбег — run")
	var seen := {}
	var t := 0.0
	while t < 5.0:
		pa.update("flying", 5.0, 1.0, 0.0, 0.05)
		seen[pa.current()] = true
		t += 0.05
	check(seen.has("run_air") and seen.has("climb_in"), "после отрыва: run_air → climb_in")
	check(pa.current() == "prone", "потом лёжа")
	for i in 400:  # долго летит, потом снижается к земле
		pa.update("flying", 200.0, -1.0, 0.0, 0.05)
	pa.update("flying", 10.0, -1.0, 0.0, 0.05)
	check(pa.current() == "climb_out", "у земли — выход из кокона")
	for i in 40:
		pa.update("flying", 5.0, -1.0, 0.0, 0.05)
	check(pa.current() == "flare", "затем выравнивание")
	pa.update("landed", 0.0, 0.0, 0.0, 0.05)
	check(pa.current() == "stand", "после посадки — stand")
	root.free()
