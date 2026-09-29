extends Node
## EggPlace (docs/easter_eggs_contracts.md → К8): место и условия пасхалок на реальных локациях.
## Запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_place
## Рельеф грузится напрямую (без главной сцены), OSM — из data/osm/<id>.json.

const LOCATIONS := ["altai", "askarovo", "aushkul", "ongudai"]
const MAIN_SCENE := preload("res://scenes/main.tscn")

static var _cache := {}

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Подмена WorldObjects: EggPlace читает только osm и camp.
class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _load(id: String) -> Dictionary:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		o.osm = OsmData.load_file(
			"res://data/osm/%s.json" % id, t.center_lat, t.center_lon
		)
		_cache[id] = {"terrain": t, "objs": o}
	return _cache[id]


func _place(id: String) -> EggPlace:
	var d := _load(id)
	return EggPlace.build(d.terrain, d.objs)


func _start_xz(t: Terrain) -> Vector2:
	var s := t.get_start_sites()
	if s.is_empty():
		return Vector2.ZERO
	return Vector2(s[0].position.x, s[0].position.z)


func test_all_locations_table() -> void:
	print("         loc       h_m  above_m  mount surf  place(dist_km)        track  starts  build_ms")
	for id in LOCATIONS:
		var d := _load(id)
		var t: Terrain = d.terrain
		var p := _place(id)
		var s := _start_xz(t)
		var np := p.nearest_place(s.x, s.y)
		var surf := p.surface_at(s.x, s.y)
		check(surf >= 0 and surf < SurfaceLayer.CLASS_COUNT, "%s: класс поверхности в списке" % id)
		check(p.valley_msl() <= p.height_at(s.x, s.y), "%s: дно долины не выше старта" % id)
		var osm: OsmData = d.objs.osm
		if osm != null and not osm.places.is_empty():
			check(not np.is_empty(), "%s: nearest_place не пуст" % id)
		var tracks := p.roads(PackedStringArray(["track"]))
		var has_tracks := false
		if osm != null:
			for r in osm.roads:
				has_tracks = has_tracks or String(r.get("t", "")) == "track"
		check(has_tracks == (not tracks.is_empty()), "%s: roads(track) согласовано с OSM" % id)
		print(
			(
				"         %-9s %5.0f %8.0f  %-5s %-5s %-22s %5d %7d %8.1f"
				% [
					id,
					p.height_at(s.x, s.y),
					p.above_valley_m(s.x, s.y),
					str(p.is_mountain(s.x, s.y)),
					SurfaceLayer.CLASS_NAMES[surf],
					(
						"%s (%.1f)" % [np.get("n", "-"), float(np.get("dist_m", 0.0)) / 1000.0]
						if not np.is_empty()
						else "-"
					),
					tracks.size(),
					p.start_sites().size(),
					p.build_ms
				]
			)
		)
		check(p.build_ms <= 20.0, "%s: построение %.1f мс ≤ 20" % [id, p.build_ms])


func test_mountain_and_valley() -> void:
	var p := _place("altai")
	var s := _start_xz(_load("altai").terrain)
	check(p.is_mountain(s.x, s.y), "altai: старт — горы")
	check(p.above_valley_m(s.x, s.y) > 0.0, "altai: старт выше дна долины")
	check(p.slope_deg_at(s.x, s.y) >= 0.0, "крутизна считается")


func test_roads_and_water() -> void:
	var p := _place("altai")
	var s := _start_xz(_load("altai").terrain)
	var any := PackedStringArray(["track", "trunk", "primary"])
	check(p.nearest_road_m(s.x, s.y, any) < INF, "дорога найдена")
	check(p.near_water_m(s.x, s.y) < INF, "вода найдена")
	var none := PackedStringArray(["нет_такого_класса"])
	check(p.nearest_road_m(s.x, s.y, none) == INF, "нет класса — INF")


func test_find_point() -> void:
	var p := _place("altai")
	var s := _start_xz(_load("altai").terrain)
	var accept := func(x: float, z: float) -> bool: return p.height_at(x, z) > p.height_at(s.x, s.y)
	var a := RandomNumberGenerator.new()
	a.seed = 12345
	var b := RandomNumberGenerator.new()
	b.seed = 12345
	var pa: Variant = p.find_point(a, s, 3000.0, accept)
	var pb: Variant = p.find_point(b, s, 3000.0, accept)
	check(pa is Vector3 and pb is Vector3, "точка найдена")
	if pa is Vector3 and pb is Vector3:
		check(pa == pb, "один сид — одна точка")
		check(accept.call(pa.x, pa.z), "точка удовлетворяет accept")
		check(absf(pa.y - p.height_at(pa.x, pa.z)) < 0.01, "точка на рельефе")
		check(Vector2(pa.x - s.x, pa.z - s.y).length() <= 3000.0 + 0.01, "точка в круге")
	var never := func(_x: float, _z: float) -> bool: return false
	check(p.find_point(a, s, 100.0, never, 5) == null, "никто не подошёл — null")


func test_without_osm_and_terrain() -> void:
	var t: Terrain = _load("altai").terrain
	var p := EggPlace.build(t, null)  # runtime-точка с карты: OSM нет
	var s := _start_xz(t)
	check(p.nearest_place(s.x, s.y).is_empty(), "без OSM: посёлка нет")
	check(p.roads(PackedStringArray(["track"])).is_empty(), "без OSM: дорог нет")
	check(p.nearest_road_m(s.x, s.y, PackedStringArray(["track"])) == INF, "без OSM: INF до дороги")
	check(p.near_water_m(s.x, s.y) == INF, "без OSM: INF до воды")
	check(p.camp().is_empty(), "без лагеря: пусто")
	check(p.is_mountain(s.x, s.y), "рельеф есть — горы определяются и без OSM")
	var e := EggPlace.build(null, null)  # рельефа нет совсем
	check(not e.is_mountain(0, 0), "без рельефа: не горы")
	check(e.surface_at(0, 0) == SurfaceLayer.NONE, "без рельефа: NONE")
	check(e.start_sites().is_empty(), "без рельефа: стартов нет")
	var any: Variant = e.find_point(RandomNumberGenerator.new(), Vector2.ZERO, 10.0, Callable())
	check(any is Vector3, "без accept — любая точка")


func test_scheduler_fills_context() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", FlightSettings.defaults())
	game.eggs.update()
	var c: EggContext = game.eggs._ctx
	check(c.place != null, "place построен планировщиком")
	if c.place != null:
		check(c.place.build_ms <= 20.0, "место в игре: %.1f мс ≤ 20" % c.place.build_ms)
		print("         в игре: place %.1f мс, дно %.0f м" % [c.place.build_ms, c.place.valley_msl()])
		check(not c.place.start_sites().is_empty(), "старты есть")
	check(c.month == game.settings.month and c.sky == game.settings.sky, "дата и небо в контексте")
	check(absf(c.wind_ms - game.settings.wind_speed_kmh / 3.6) < 1e-6, "ветер в м/с")
	var before: EggPlace = c.place
	game.eggs.update()
	check(game.eggs._ctx.place == before, "место строится один раз")
	game.restart()
	check(game.eggs._place == null, "reset сбрасывает место")
	main.queue_free()
	await get_tree().process_frame
