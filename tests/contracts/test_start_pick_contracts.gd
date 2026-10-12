extends TestCase
## Контрактные тесты start-pick (docs/contracts/start-pick.md): SP-К1 — точный старт в FlightSettings и Game,
## SP-К2 — StartSpot.check, SP-К3 — точный старт в сети, SP-К4 — камни и кусты не на разбеге.
## Проверки формы и инвариантов дописывают владельцы (SP-К1, SP-К2 — SP-1; SP-К3 — SP-3; SP-К4 — SP-4).
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/start-pick.md"
const VERSIONS := {"SP-К1": 1, "SP-К2": 1, "SP-К3": 1, "SP-К4": 1}


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
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


# ---------------------------------------------------------------- SP-К1

static var _terrain: Terrain
static var _spots: Dictionary = {}


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func test_sp_k1_settings_shape() -> void:
	var s := FlightSettings.defaults()
	check(is_nan(s.start_lat) and is_nan(s.start_lon) and is_nan(s.start_heading_deg), "по умолчанию NAN")
	check(not s.has_exact_start(), "по умолчанию точки нет")
	var d0 := s.to_dict()
	check(d0.has("start_lat") and d0.start_lat == null, "нет точки — null")
	check(is_nan(FlightSettings.from_dict({}).start_lat), "from_dict без ключей — NAN")
	s.set_exact_start(51.5, 85.6, -90.0)
	check(s.has_exact_start(), "есть точка")
	check(is_equal_approx(s.start_heading_deg, 270.0), "курс в [0, 360): %f" % s.start_heading_deg)
	s.set_exact_start(51.5, 85.6, 725.0)
	check(is_equal_approx(s.start_heading_deg, 5.0), "725 → 5: %f" % s.start_heading_deg)
	for r: FlightSettings in [FlightSettings.from_dict(s.to_dict()), s.duplicate()]:
		check(
			is_equal_approx(r.start_lat, 51.5) and is_equal_approx(r.start_lon, 85.6),
			"круговой словарь: широта/долгота"
		)
		check(is_equal_approx(r.start_heading_deg, 5.0) and r.has_exact_start(), "круговой словарь: курс")
	s.clear_exact_start()
	check(not s.has_exact_start(), "clear: точки нет")
	check(is_nan(s.start_lat) and is_nan(s.start_lon) and is_nan(s.start_heading_deg), "clear: три NAN")
	var back := FlightSettings.from_dict(s.to_dict())
	check(
		is_nan(back.start_lat) and is_nan(back.start_lon) and is_nan(back.start_heading_deg),
		"NAN ↔ NAN"
	)
	# неполная точка — не точка
	s.start_lat = 51.5
	s.start_lon = 85.6
	check(not s.has_exact_start(), "без курса точки нет")
	# from_dict с base: ключи точки в словаре перекрывают базу, отсутствие — сбрасывает в NAN
	var base := FlightSettings.defaults()
	base.set_exact_start(1.0, 2.0, 3.0)
	check(not FlightSettings.from_dict({}, base).has_exact_start(), "словарь без ключей — NAN")


func test_sp_k1_place_pick_clears() -> void:
	var row := PlacePickRow.new()
	row.settings = FlightSettings.defaults()
	row.pick_label = Label.new()
	var cases := {
		"set_pick": func() -> void: row.set_pick(51.0, 85.0),
		"популярное (точка)": func() -> void: row.choose_place({"lat": 51.1, "lon": 85.1, "name": "x"}),
		"встроенное": func() -> void: row.choose_place({"location": "altai", "site": ""}),
	}
	for k: String in cases:
		row.settings.set_exact_start(51.5, 85.6, 10.0)
		(cases[k] as Callable).call()
		check(not row.settings.has_exact_start(), "%s сбрасывает точный старт" % k)
	row.pick_label.free()
	row.free()


# ---------------------------------------------------------------- SP-К2


## Первая точка сетки детального рельефа (шаг 100 м, внутри отступа), где pred(check) верно;
## кэш по ключу. Пусто — нет такой точки в фикстуре.
func _find(key: String, pred: Callable) -> Variant:
	if _spots.has(key):
		return _spots[key]
	var t := _ongudai()
	var b := t.detail_bounds().grow(-250.0)
	var found: Variant = null
	var z := b.position.y
	while z < b.end.y and found == null:
		var x := b.position.x
		while x < b.end.x:
			if pred.call(StartSpot.check(t, x, z), t, x, z):
				found = Vector2(x, z)
				break
			x += 100.0
		z += 100.0
	_spots[key] = found
	return found


func test_sp_k2_config() -> void:
	var c: Dictionary = Config.get_config("game").get("start_pick", {})
	check(is_equal_approx(float(c.get("max_slope_deg", 0.0)), 40.0), "max_slope_deg 40")
	check(is_equal_approx(float(c.get("edge_margin_m", 0.0)), 200.0), "edge_margin_m 200")
	check(String(c.get("_doc", "")) != "", "_doc")


func test_sp_k2_shape_and_finite() -> void:
	var t := _ongudai()
	var b := t.detail_bounds()
	for p: Vector2 in [b.get_center(), Vector2(0, 0), Vector2(1e6, -1e6), b.position - Vector2(50, 50)]:
		var r := StartSpot.check(t, p.x, p.y)
		for k: String in ["ok", "reason", "height_m", "slope_deg", "downhill_deg"]:
			check(r.has(k), "ключ %s" % k)
		for k: String in ["height_m", "slope_deg", "downhill_deg"]:
			check(is_finite(float(r[k])), "%s конечно в %s" % [k, p])
		check(bool(r.ok) == (r.reason == ""), "ok ⇔ reason пуст")
	check(StartSpot.check(t, 1e6, 0.0).reason == "outside", "далеко за краем — outside")


func test_sp_k2_outside_margin() -> void:
	var t := _ongudai()
	var b := t.detail_bounds()
	var inner := b.grow(-200.0)
	var r := StartSpot.check(t, b.position.x + 100.0, b.get_center().y)
	check(r.reason == "outside", "ближе 200 м к краю — outside (%s)" % r.reason)
	# чуть внутри отступа край уже не причина
	var r2 := StartSpot.check(t, inner.position.x + 5.0, inner.get_center().y)
	check(r2.reason != "outside", "внутри отступа — не outside (%s)" % r2.reason)


func test_sp_k2_water() -> void:
	var t := _ongudai()
	var p: Variant = _find("water", func(r: Dictionary, tt: Terrain, x: float, z: float) -> bool:
		return tt.surface_at(x, z) == SurfaceLayer.WATER)
	if p == null:
		print("  в фикстуре ongudai нет воды на сетке 100 м — water проверяется подставной картой")
		return
	var r := StartSpot.check(t, p.x, p.y)
	check(r.reason == "water" and not r.ok, "вода: %s" % r.reason)


func test_sp_k2_built() -> void:
	var t := _ongudai()
	var p: Variant = _find("built", func(r: Dictionary, tt: Terrain, x: float, z: float) -> bool:
		return tt.surface_at(x, z) == SurfaceLayer.BUILT and r.reason != "outside")
	if p == null:
		print("  в фикстуре ongudai нет застройки на сетке 100 м")
		return
	var r := StartSpot.check(t, p.x, p.y)
	# вода приоритетнее застройки, но точка выбрана по BUILT и не воде
	check(r.reason == "built" and not r.ok, "застройка: %s" % r.reason)


func test_sp_k2_steep_and_ok() -> void:
	var t := _ongudai()
	var lim := float(Config.get_config("game").start_pick.max_slope_deg)
	var steep: Variant = _find("steep", func(r: Dictionary, tt: Terrain, x: float, z: float) -> bool:
		var s := tt.surface_at(x, z)
		return r.reason != "outside" and s != SurfaceLayer.WATER and s != SurfaceLayer.BUILT and float(r.slope_deg) > lim)
	if steep != null:
		var r := StartSpot.check(t, steep.x, steep.y)
		check(r.reason == "steep" and not r.ok, "круче %.0f°: %s" % [lim, r.reason])
	else:
		print("  в фикстуре ongudai нет склона круче %.0f° на сетке 100 м" % lim)
	var good: Variant = _find("ok", func(r: Dictionary, _tt: Terrain, _x: float, _z: float) -> bool:
		return bool(r.ok) and float(r.slope_deg) > 15.0)
	check(good != null, "в фикстуре есть допустимая точка")
	if good != null:
		var r := StartSpot.check(t, good.x, good.y)
		check(r.ok and r.reason == "", "допустимая точка")
		check(absf(float(r.height_m) - t.height_at(good.x, good.y)) < 0.01, "height_m = height_at")
		var ev := StartPlacement.evaluate(t.height_at, good.x, good.y, Config.get_config("game").start_search)
		check(absf(float(r.slope_deg) - float(ev.slope_deg)) < 1e-4, "slope_deg как у StartPlacement")
		check(absf(float(r.downhill_deg) - float(ev.heading_deg)) < 1e-4, "downhill_deg как у StartPlacement")
