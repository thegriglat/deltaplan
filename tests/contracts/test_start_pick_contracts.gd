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


# ---- SP-К4: камни и кусты не на разбеге у любого старта ----

static var _t4: Terrain


func _terrain4() -> Terrain:
	if _t4 == null:
		_t4 = Terrain.new()
		_t4.location_id = ""
		_t4.load_location("ongudai")
	return _t4


## Ближайшее расстояние от c до камня/куста по тайлам вокруг c (радиус обзора rad), м; INF — нет.
func _nearest(sc: Object, tile: float, c: Vector2, rad: float) -> Dictionary:
	var best := INF
	var n := 0
	var k0 := Vector2i(floori((c.x - rad) / tile), floori((c.y - rad) / tile))
	var k1 := Vector2i(floori((c.x + rad) / tile), floori((c.y + rad) / tile))
	for tz in range(k0.y, k1.y + 1):
		for tx in range(k0.x, k1.x + 1):
			var d: Dictionary = sc.build_tile(tx, tz)
			var xf: PackedFloat32Array = d.xf
			for i in (d["var"] as PackedInt32Array).size():
				var p := Vector2(xf[i * 12 + 3], xf[i * 12 + 11])
				if p.distance_to(c) <= rad:
					n += 1
					best = minf(best, p.distance_to(c))
	return {"min": best, "n": n}


func _sp4_scatters(t: Terrain) -> Array:
	var rs := RockScatter.new()
	rs.terrain = t
	check(rs.setup(Config.get_config("world").rocks), "SP-К4: модели камней")
	rs._check_key()
	var sh := ShrubScatter.new()
	sh.terrain = t
	check(sh.setup(Config.get_config("vegetation").shrubs), "SP-К4: модели кустов")
	sh._check_key()
	return [[rs, float(Config.get_config("world").rocks.tile_m), "камни"],
		[sh, float(Config.get_config("vegetation").shrubs.tile_m), "кусты"]]


func test_sp_k4_keep_off() -> void:
	var t := _terrain4()
	var runway := float(Config.value("game", "start_search.runway_m", 40.0))
	var sc := _sp4_scatters(t)
	var clr := t.get_start_clearings()
	check(not clr.is_empty(), "SP-К4: встроенные поляны есть")
	for c: Vector3 in clr:
		for e: Array in sc:
			var r := _nearest(e[0], e[1], Vector2(c.x, c.y), runway)
			check(r.n == 0, "SP-К4: встроенный старт, %s в %.0f м: %d" % [e[2], runway, r.n])
	# поляна, добавленная после сборки: центр рядом со встроенным стартом, но вне его круга
	var s0: Vector3 = t.get_start_sites()[0].position
	var x := s0.x + 400.0
	var z := s0.z + 300.0
	var before := {}
	for e: Array in sc:
		before[e[2]] = _nearest(e[0], e[1], Vector2(x, z), runway).n
	print("  SP-К4: до add_start_clearing в %.0f м: %s" % [runway, before])
	t.add_start_clearing(x, z, Terrain.start_clearing_radius_m())
	for e: Array in sc:
		e[0]._check_key()  # ревизия поверхности сбросила кеш и обновила центры
		var r := _nearest(e[0], e[1], Vector2(x, z), runway)
		check(r.n == 0, "SP-К4: добавленная поляна, %s в %.0f м: %d" % [e[2], runway, r.n])
		check(e[0]._key.ends_with("|%d" % t.surface_revision), "SP-К4: %s — ключ кеша по ревизии" % e[2])




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


# ---- SP-К3: точный старт в сети ----


func _exact_settings() -> FlightSettings:
	var s := FlightSettings.defaults()
	s.set_exact_start(50.75321, 86.12345, 123.4)
	return s


func test_sp_k3_zone_roundtrip() -> void:
	var s := _exact_settings()
	var z := s.to_zone(7, 2)
	check(z.startLat == s.start_lat and z.startLon == s.start_lon, "to_zone: точка")
	check(z.startHeadingDeg == s.start_heading_deg, "to_zone: курс")
	var back := FlightSettings.from_zone(z)
	check(back.has_exact_start(), "from_zone: есть точный старт")
	check(is_equal_approx(back.start_lat, s.start_lat) and is_equal_approx(back.start_lon, s.start_lon), "точка")
	check(is_equal_approx(back.start_heading_deg, 123.4), "курс")
	var plain := FlightSettings.from_zone(FlightSettings.defaults().to_zone(7, 2))
	check(not plain.has_exact_start(), "без точки — не задан")


func test_sp_k3_messages() -> void:
	var z := _exact_settings().to_zone(7, 2)
	var json := NetMessages.encode("createZone", {"zone": z})
	var raw: Dictionary = JSON.parse_string(json).createZone.zone
	check(raw.has("startLat") and raw.has("startLon") and raw.has("startHeadingDeg"), "поля шлются")
	var m := NetMessages.decode(json)
	check(is_equal_approx(m.data.zone.startLat, 50.75321), "decode: startLat")
	check(is_equal_approx(m.data.zone.startHeadingDeg, 123.4), "decode: курс")
	var z0 := FlightSettings.defaults().to_zone(7, 2)
	var raw0: Dictionary = JSON.parse_string(NetMessages.encode("createZone", {"zone": z0})).createZone.zone
	check(not raw0.has("startLat") and not raw0.has("startHeadingDeg"), "без точки — полей нет")
	var m0 := NetMessages.decode(NetMessages.encode("createZone", {"zone": z0}))
	check(is_nan(m0.data.zone.startLat) and is_nan(m0.data.zone.startLon), "нет → NAN")
	check(not FlightSettings.from_zone(m0.data.zone).has_exact_start(), "нет → не задан")


func test_sp_k3_world_key() -> void:
	check(WorldKey.VERSION == 2, "VERSION = 2")
	var s := _exact_settings()
	var key := s.world_key(7, 2)
	var kv := WorldKey.split(key)
	check(kv.get("slat") == "50.75321" and kv.get("slon") == "86.12345" and kv.get("hdg") == "123.4", "ключи: %s" % key)
	check(kv.get("v") == "2", "v=2")
	var plain := FlightSettings.defaults().world_key(7, 2)
	var pk := WorldKey.split(plain)
	check(not pk.has("slat") and not pk.has("slon") and not pk.has("hdg"), "без точки ключей нет")
	# хост с точкой → у клиента та же точка (в пределах квантования), место не притянуто
	var parsed := FlightSettings.from_world_key(key, FlightSettings.defaults())
	var c: FlightSettings = parsed.settings
	check(c.has_exact_start(), "клиент: есть точный старт")
	check(absf(c.start_lat - s.start_lat) <= 1e-5 and absf(c.start_lon - s.start_lon) <= 1e-5, "точка ±1e-5")
	check(absf(c.start_heading_deg - s.start_heading_deg) <= 0.1, "курс ±0,1")
	check(c.world_key(7, 2) == key, "ключ клиента = ключ хозяина")
	# база клиента с собственным точным стартом: ключ без точки её сбрасывает
	var base := _exact_settings()
	check(not FlightSettings.from_world_key(plain, base).settings.has_exact_start(), "ключ без точки сбрасывает")
	# точка на склоне встроенной локации не притягивается к встроенному старту
	var loc := FlightSettings.defaults()
	loc.set_exact_start(loc_lat_offset(loc), WorldKey.launch_latlon(loc).y, 10.0)
	var c2: FlightSettings = FlightSettings.from_world_key(loc.world_key(1, 0)).settings
	check(absf(c2.start_lat - loc.start_lat) <= 1e-5, "точка не притянута к старту локации")


func loc_lat_offset(s: FlightSettings) -> float:
	return WorldKey.launch_latlon(s).x + 0.003


func test_sp_k3_net_flight_world_and_queue() -> void:
	var host := _exact_settings()
	var z := host.to_zone(7, 2)
	z["worldKey"] = host.world_key(7, 2)
	var obj := _ZoneHolder.new()
	obj.zone = z
	var s := NetFlight.world_settings(obj, FlightSettings.defaults())
	check(s.has_exact_start(), "NetFlight.world_settings: точный старт")
	check(absf(s.start_lat - host.start_lat) <= 1e-5 and absf(s.start_heading_deg - 123.4) <= 0.1, "значения")
	var start := Vector3(10, 5, -20)
	var spots := NetQueue.spots_for(func(_x: float, _z: float) -> float: return 5.0, start, 123.4, 3)
	check(spots[0].position == start and is_equal_approx(spots[0].heading_deg, 123.4), "очередь от точки и курса")


class _ZoneHolder:
	extends RefCounted
	var zone: Dictionary = {}
