extends TestCase
## LocationBuilder / LocationCache / Locations (OA-К4, подставные стадии, без сети):
## ключ и сетка, полнота и версия, кеш без вызова стадий, догрузка недостающего, временная папка.

const POINT := Vector2(-33.07, 151.93)  # далеко от встроенных мест; кеш — во временном профиле
var _log: Array = []


## Подставная стадия: пишет файлы, считает вызовы, может отказывать.
class FakeStage:
	extends RefCounted
	var name := ""
	var log: Array
	var fail := false
	var net := 1

	func _init(n: String, l: Array) -> void:
		name = n
		log = l

	func run(ctx: LocationBuildContext) -> Error:
		log.append(name)
		ctx.net_requests += net
		ctx.report(name, 0.5)
		if fail:
			ctx.log_line("%s: отказ" % name)
			return ERR_CANT_CONNECT
		match name:
			"dem":
				var layers: Array = []
				ctx.heights = {}
				ctx.layers = {}
				for id in ["detail", "far"]:
					var h := PackedFloat32Array()
					h.resize(25)
					h.fill(100.0)
					var f := FileAccess.open(ctx.dir.path_join(id + ".f32.zst"), FileAccess.WRITE)
					f.store_buffer(h.to_byte_array().compress(FileAccess.COMPRESSION_ZSTD))
					f.close()
					var info := {"id": id, "file": id + ".f32.zst", "width": 5, "height": 5, "spacing_m": 25.0,
						"origin_x_m": -50.0, "origin_z_m": -50.0, "source": "fake", "water_file": id + "_water.png"}
					layers.append(info)
					ctx.heights[id] = h
					ctx.layers[id] = info
				_write(ctx.dir.path_join("meta.json"), {"location": ctx.key, "center_lat": ctx.center_lat,
					"center_lon": ctx.center_lon, "layers": layers, "attribution": []})
			"surface":
				_write(ctx.dir.path_join("surface.json"), {"layers": []})
		return OK

	static func _write(path: String, d: Dictionary) -> void:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(d))
		f.close()


func _builder(fails: Array = []) -> LocationBuilder:
	var b := LocationBuilder.new()
	b.stages = []
	for n in ["dem", "rivers", "surface"]:
		var st := FakeStage.new(n, _log)
		st.fail = fails.has(n)
		b.stages.append({"name": n, "obj": st})
	return b


func _cleanup() -> void:
	var key := LocationCache.key_for(POINT.x, POINT.y)
	LocationCache.remove_dir(LocationCache.dir_for(key))
	LocationCache.remove_dir(LocationCache.tmp_dir_for(key))


func test_key_and_snap() -> void:
	check(LocationCache.key_for(53.26, 58.54) == "pt_+53.250_+058.550", "ключ 53.26/58.54")
	check(LocationCache.key_for(-5.51, -0.02) == "pt_-05.500_+000.000", "ноль без минуса")
	check(LocationCache.key_for(53.26, 58.54) == LocationCache.key_for(53.274, 58.526), "соседние точки — один центр")
	check(LocationCache.key_for(53.26, 58.54) != LocationCache.key_for(53.31, 58.54), "дальше шага — другой центр")
	check(LocationCache.dir_for("pt_+01.000_+002.000") == "user://locations/pt_+01.000_+002.000", "dir_for")
	var c := LocationCache.snap(47.05, 11.0)
	check(is_equal_approx(c.x, 47.05) and is_equal_approx(c.y, 11.0), "центр на сетке не сдвигается")


func test_build_then_cache() -> void:
	_cleanup()
	_log.clear()
	var b := _builder()
	var r: Dictionary = await b.build(null, POINT.x, POINT.y)
	check(bool(r.ok) and r.missing.is_empty(), "сборка прошла без недостающего")
	check(_log == ["dem", "rivers", "surface"], "стадии по порядку: %s" % str(_log))
	var key := String(r.key)
	var dir := LocationCache.dir_for(key)
	check(LocationCache.is_complete(key), "место полное")
	check(not DirAccess.dir_exists_absolute(LocationCache.tmp_dir_for(key)), "временной папки нет")
	for f in ["meta.json", "detail.f32.zst", "far.f32.zst", "surface.json", "location.json", "build.json"]:
		check(FileAccess.file_exists(dir.path_join(f)), "файл " + f)
	var bj := LocationCache.read_build(dir)
	check(int(bj.net_requests) == 3 and bj.complete == true, "build.json: запросы и complete")
	var loc: Dictionary = Locations.config(key)
	check(String(loc.name) == "%.3f, %.3f" % [loc.center_lat, loc.center_lon], "имя места — координаты: %s" % loc.get("name"))
	check(int(loc.utc_offset_h) == int(roundf(float(loc.center_lon) / 15.0)), "utc_offset_h")
	check((loc.start_sites as Array).is_empty() and String(loc.data_dir) == dir, "start_sites пусты, data_dir")
	check(loc.has("render") and loc.has("dem") and loc.has("rivers"), "шаблон конфига места")
	check(not bj.missing.has("osm") and not bj.seconds.has("osm"), "OSM не стадия")
	check(not Locations.is_builtin(key), "реестр: кеш")
	# повтор — из кеша
	_log.clear()
	var b2 := _builder()
	var r2: Dictionary = await b2.build(null, POINT.x + 0.01, POINT.y + 0.01)
	check(bool(r2.ok) and r2.key == key, "та же точка (в пределах сетки) — тот же ключ")
	check(_log.is_empty() and b2.net_requests == 0, "из кеша: стадии не вызваны, net_requests == 0")
	# другая версия сборщика — заново
	var bad := bj.duplicate()
	bad.builder_version = LocationCache.version() + 1
	_write_json(dir.path_join("build.json"), bad)
	check(not LocationCache.is_complete(key), "другая версия — не полное")
	await _builder().build(null, POINT.x, POINT.y)
	check(LocationCache.is_complete(key) and _log == ["dem", "rivers", "surface"], "версия: пересборка целиком")
	_cleanup()


func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func test_missing_resume() -> void:
	_cleanup()
	_log.clear()
	var r: Dictionary = await _builder(["rivers"]).build(null, POINT.x, POINT.y)
	var key := String(r.key)
	check(bool(r.ok) and r.missing == ["rivers"], "отказ рек — место без слоя, missing: %s" % str(r.missing))
	var bj := LocationCache.read_build(LocationCache.dir_for(key))
	check(bj.complete == false and bj.missing == ["rivers"], "build.json: missing")
	check(String(Locations.config(key).name).contains("."), "имя места — координаты")
	_log.clear()
	var r2: Dictionary = await _builder().build(null, POINT.x, POINT.y)
	check(bool(r2.ok) and r2.missing.is_empty(), "догрузка прошла")
	check(_log == ["rivers"], "догружены только реки: %s" % str(_log))
	check(LocationCache.is_complete(key), "место стало полным")
	# отказ покрова — только покров в missing (OSM в стадиях нет)
	_cleanup()
	_log.clear()
	var r3: Dictionary = await _builder(["surface"]).build(null, POINT.x, POINT.y)
	check(bool(r3.ok) and r3.missing == ["surface"], "отказ покрова: missing %s" % str(r3.missing))
	_log.clear()
	await _builder().build(null, POINT.x, POINT.y)
	check(_log == ["surface"], "догружен покров: %s" % str(_log))
	_cleanup()


## N4: стадии игры — dem → rivers → surface; OSM-стадии нет.
func test_default_stages_without_osm() -> void:
	var names: Array = []
	for st in LocationBuilder.default_stages():
		names.append(st.name)
	check(names == ["dem", "rivers", "surface"], "стадии игры: %s" % str(names))


func test_dem_failure_is_error() -> void:
	_cleanup()
	_log.clear()
	var b := _builder(["dem"])
	var r: Dictionary = await b.build(null, POINT.x, POINT.y)
	var key := String(r.key)
	check(not bool(r.ok) and String(r.error) != "", "отказ рельефа — ошибка")
	check(_log == ["dem"], "после отказа рельефа дальше не идём")
	check(not DirAccess.dir_exists_absolute(LocationCache.dir_for(key)), "места нет")
	check(not DirAccess.dir_exists_absolute(LocationCache.tmp_dir_for(key)), "временной папки нет")
	var r2: Dictionary = await _builder().build(null, 95.0, 0.0)
	check(not bool(r2.ok) and r2.error == "nodata", "широта вне проекции — nodata")


func test_registry_builtin() -> void:
	check(Locations.is_builtin("altai") and not Locations.is_builtin("pt_+01.000_+002.000"), "is_builtin")
	check(not Locations.config("altai").is_empty() and Locations.config("pt_+09.999_+009.999").is_empty(), "config")
	var al: Dictionary = Locations.config("altai")
	check(Locations.builtin_at(float(al.center_lat), float(al.center_lon)) == "altai", "builtin_at центр")
	check(Locations.builtin_at(POINT.x, POINT.y) == "", "builtin_at далеко — пусто")
	var half_km: float = float(al.dem.layers[0].size_km) * 0.5
	var edge_lat: float = float(al.center_lat) + (half_km - 5.0) / 111.32  # ближе 10 км к краю
	check(Locations.builtin_at(edge_lat, float(al.center_lon)) == "", "у края (< 10 км) — не встроенное")
