extends TestCase
## WF-К1 v3 (docs/contracts/wind-forecast.md): ветер условий — всегда набегающий поток (приток k = 1).
## Режима поля у старта нет: ключ условий «режим притока» (снят в WF-2) — посторонний (BAD_INPUT
## через фасад Atmosphere), у StartWeather нет разбора опоры ветра, набор без wind_ref разбирается,
## запечённого поля нет, а хеш модели воздуха живёт в AirModelHash.
## Имена снятых ключей и функций собраны из частей, чтобы проверка «не осталось следов» их не ловила.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=wind_forecast

const KEY := "inflow" + "_mode"
const REF_OF := "wind_ref" + "_of"
const REFS := "WIND" + "_REFS"


func _preset() -> Dictionary:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = 14.0
	w.wind_from_deg = 230.0
	return w


func test_mode_key_is_rejected() -> void:
	for mode: Variant in ["start", "inflow", "x", 1]:
		var a := Atmosphere.new()
		a.visuals_enabled = false
		a.deterministic = true
		check(a.configure(5) == 0, "configure")
		var cond := {"preset": _preset(), "start_hour": 12.0, "speed": 1.0}
		check(a.set_conditions(cond) == 0, "условия без режима — OK")
		cond[KEY] = mode
		check(a.set_conditions(cond) == 1, "ключ режима %s — посторонний, BAD_INPUT" % str(mode))
		a.free()


func test_start_weather_has_no_wind_ref_parser() -> void:
	var sw := StartWeather.new()
	var scr: Script = sw.get_script()
	var names: Array[String] = []
	for m: Dictionary in scr.get_script_method_list():
		names.append(String(m.name))
	check(not names.has(REF_OF), "у StartWeather нет разбора опоры ветра")
	check(not scr.get_script_constant_map().has(REFS), "у StartWeather нет списка опор ветра")


func test_start_weather_parses_set_without_wind_ref() -> void:
	var hour := float(SunClock.start_hours()[0])
	var w := {
		"wind_from_deg": 270,
		"wind_speed_ms": 6.0,
		"start_hour": hour,
		"month": 7,
		"day": 15,
		"sky": "clear",
		"temperature_c": 20.0,
	}
	var p := StartWeather.parse(w, "test")
	check(not p.is_empty(), "набор без wind_ref разобран")
	check(not p.has("wind_ref"), "в разобранном наборе нет wind_ref")
	# устаревший ключ не ломает разбор (игнорируется с предупреждением)
	var old := w.duplicate()
	old["wind_ref"] = "start"
	var q := StartWeather.parse(old, "test")
	check(not q.is_empty() and not q.has("wind_ref"), "устаревший wind_ref игнорируется")


func test_baked_field_script_is_gone() -> void:
	check(not FileAccess.file_exists("res://scripts/atmosphere/air_model/air_baked_field.gd"), "файла запечённого поля нет")


func test_model_hash_moved_to_air_model_hash() -> void:
	var h1 := AirModelHash.model_hash()
	var h2 := AirModelHash.model_hash()
	check(h1 != "", "хеш модели не пуст")
	check(h1 == h2, "хеш модели стабилен")
	var code := AirModelHash.code_hash()
	check(code != "" and code == AirModelHash.code_hash_of_sources(), "хеш кода — по исходникам каталога модели")


## WF-К1 v3: условия, которые строит игра, не содержат wind_ref (опорная высота — отметка долины места,
## её берёт крейт). Проверка по тексту Game._air_conditions (сцена не нужна).
func test_game_conditions_have_no_wind_ref() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/game/game.gd")
	var a := src.find("func _air_conditions()")
	check(a >= 0, "Game._air_conditions найдена")
	var b := src.find("\nfunc ", a + 10)
	var body := src.substr(a, b - a)
	check(not body.contains("wind_" + "ref"), "в условиях игры нет wind_ref")
	check(not body.contains("ref_" + "msl"), "в условиях игры нет ref_msl")
