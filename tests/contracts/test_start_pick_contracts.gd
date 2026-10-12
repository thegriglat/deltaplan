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
