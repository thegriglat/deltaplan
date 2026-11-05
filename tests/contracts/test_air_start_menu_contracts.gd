extends TestCase
## Контрактные тесты air-start-menu (docs/contracts/air-start-menu.md): ASM-К1 — поле старта в воздухе
## в FlightSettings и пределы конфига; ASM-К2 (постановка в Game) — tests/game/test_air_start_menu.gd.
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/air-start-menu.md"
const VERSIONS := {"ASM-К1": 1, "ASM-К2": 2}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]), "%s v%d в frontmatter" % [id, VERSIONS[id]])
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


func test_config_limits() -> void:
	var mn := float(Config.value("game", "air_start.agl_min_m", -1.0))
	var mx := float(Config.value("game", "air_start.agl_max_m", -1.0))
	check(mn >= 44.0, "минимум не ниже 2× кроны 22 м: %s" % mn)
	check(mx > mn, "максимум больше минимума")
	var d := float(Config.value("game", "air_start.agl_default_m", -1.0))
	check(d >= mn and d <= mx, "умолчание в пределах")
	check(float(Config.value("game", "air_start.agl_step_m", -1.0)) > 0.0, "шаг > 0")


func test_normalize() -> void:
	var mn := float(Config.value("game", "air_start.agl_min_m", 50.0))
	var mx := float(Config.value("game", "air_start.agl_max_m", 1000.0))
	check(FlightSettings.normalize_air_start(NAN) == -1.0, "NAN → -1")
	check(FlightSettings.normalize_air_start(-5.0) == -1.0, "< 0 → -1")
	check(FlightSettings.normalize_air_start(INF) == mx, "INF → максимум")
	check(FlightSettings.normalize_air_start(0.0) == mn, "0 → минимум")
	check(FlightSettings.normalize_air_start(1e6) == mx, "выше максимума")
	for v in [-1.0, 0.0, 20.0, 300.0, 1e5, NAN]:
		var a := FlightSettings.normalize_air_start(v)
		check(FlightSettings.normalize_air_start(a) == a, "идемпотентна %s" % v)


func test_settings_field() -> void:
	var s := FlightSettings.defaults()
	check(s.air_start_agl_m == -1.0 and not s.has_air_start(), "по умолчанию с земли")
	check(not FlightSettings.from_dict({}).has_air_start(), "нет ключа → с земли")
	s.tow_kind = "aerotow"
	s.set_air_start(300.0)
	check(s.has_air_start() and s.air_start_agl_m == 300.0, "set_air_start(300)")
	check(s.tow_kind == "" and s.vehicle == "glider", "буксировка снята")
	var r := FlightSettings.from_dict(s.to_dict())
	check(r.air_start_agl_m == 300.0, "to_dict/from_dict")
	check(s.duplicate().air_start_agl_m == 300.0, "duplicate")
	s.set_air_start(-1.0)
	check(not s.has_air_start(), "set_air_start(-1) — с земли")
	var d := {"vehicle": "trike", "air_start_agl_m": 300.0}
	check(FlightSettings.from_dict(d).air_start_agl_m == -1.0, "дельталёт — только с земли")
	d = {"vehicle": "glider", "tow_kind": "winch_static", "air_start_agl_m": 200.0}
	var w := FlightSettings.from_dict(d)
	check(w.has_air_start() and w.tow_kind == "", "from_dict: воздух снимает буксировку")
	var t := FlightSettings.defaults()
	t.vehicle = "trike"
	t.set_air_start(300.0)
	check(not t.has_air_start(), "set_air_start у дельталёта — с земли")
