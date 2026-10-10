class_name LocationBuilder
extends RefCounted
## Сборщик места для точки (OA-К4): стадии DemStage → RiverStage → SurfaceStage во
## временной папке user://locations/.tmp_<ключ>, затем переименование; build.json — последним.
## Полное место (build.json complete, format_version та же) берётся из кеша без стадий и сети.
## Отказ рельефа — ошибка; отказ рек/покрова — место без слоя, имя в build.json → missing,
## следующий запуск догружает только недостающее.

signal progress(stage: String, fraction: float)

## Стадии по порядку: [{name, obj}] (obj — с методом run(ctx)). Пусто — стадии игры;
## тесты подставляют свои. Имя "dem" — обязательная, остальные могут отказать.
var stages: Array = []
## true — сеть запрещена (только кеши и локальные файлы).
var offline: bool = false
## Правки конфига места поверх шаблона (проверки без сети: dem_sources).
var spec_override: Dictionary = {}
## Встроенное место (OA-7): абсолютная папка результата (data/terrain/<id>) и его ключ — id;
## центр не привязывается к сетке, спецификация — конфиг места целиком (fixed_spec), кеш и
## location.json не используются. Файлы .import в папке сохраняются.
var out_dir: String = ""
var fixed_key: String = ""
var fixed_spec: Dictionary = {}
## Итоги последней сборки: секунды по стадиям, число запросов в сеть.
var seconds: Dictionary = {}
var net_requests: int = 0
var log_lines: PackedStringArray = PackedStringArray()

var _ctx: LocationBuildContext


## Собрать (или взять из кеша) место вокруг точки. {ok, key, error, missing}; error —
## "nodata" (вне проекции), "network" (нет рельефа), "failed", "cancelled".
func build(host: Node, lat: float, lon: float) -> Dictionary:
	seconds = {}
	net_requests = 0
	log_lines = PackedStringArray()
	var fixed := out_dir != ""
	var key := fixed_key if fixed else LocationCache.key_for(lat, lon)
	var result := {"ok": false, "key": key, "error": "", "missing": []}
	if absf(lat) > float(Config.value("world", "runtime_terrain.max_abs_lat", 84.0)):
		result.error = "nodata"
		return result
	var final_dir := out_dir if fixed else LocationCache.dir_for(key)
	var old := {} if fixed else LocationCache.read_build(final_dir)
	if not fixed:
		LocationCache.ensure_source_cache(String(Config.value("world", "runtime_terrain.cache_dir", "user://terrain_cache")))
		# место другой версии формата (или без неё) удаляется целиком, собирается заново
		if DirAccess.dir_exists_absolute(final_dir) and not LocationCache.is_current(old):
			LocationCache.remove_dir(final_dir)
			Locations.invalidate(key)
	if LocationCache.is_current(old):
		if bool(old.get("complete", false)):
			result.ok = true
			return result
	else:
		old = {}
	# что делать: всё (нет места) или только недостающее
	var todo: Array = _all_names()
	var have_dem := false
	if not old.is_empty():
		todo = (old.get("missing", []) as Array).duplicate()
		have_dem = true
	var snapc := Vector2(lat, lon) if fixed else LocationCache.snap(lat, lon)
	var clat: float = lat if fixed else snapc.x  # Vector2 — float32; встроенному нужна точность double
	var clon: float = lon if fixed else snapc.y
	var ctx := LocationBuildContext.new()
	_ctx = ctx
	ctx.key = key
	ctx.center_lat = clat
	ctx.center_lon = clon
	ctx.host = host
	ctx.offline = offline
	ctx.spec = _spec(key, snapc)
	ctx.progress.connect(func(stage: String, f: float) -> void: progress.emit(stage, f))
	var tmp := LocationCache.tmp_dir_for(key)
	LocationCache.remove_dir(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	ctx.dir = tmp
	if have_dem:
		_copy_dir(final_dir, tmp)
		if not _load_dem(ctx, tmp):
			have_dem = false
			todo = _all_names()
			LocationCache.remove_dir(tmp)
			DirAccess.make_dir_recursive_absolute(tmp)
	var missing: Array = []
	var run_names: Array = []
	for st in stages_list():
		if st.name == "dem" and have_dem:
			continue
		if st.name == "dem" or todo.has(st.name):
			run_names.append(st.name)
	var prev_seconds: Dictionary = old.get("seconds", {})
	for st in stages_list():
		if not run_names.has(st.name):
			continue
		var t0 := Time.get_ticks_usec()
		var err: int = await st.obj.run(ctx)
		seconds[st.name] = snappedf((Time.get_ticks_usec() - t0) / 1e6, 0.01)
		if ctx.cancelled:
			result.error = "cancelled"
			LocationCache.remove_dir(tmp)
			return result
		if err != OK:
			log_lines.append("стадия %s: ошибка %d" % [st.name, err])
			if st.name == "dem":
				result.error = "network" if not offline else "failed"
				log_lines.append_array(ctx.log_lines)
				LocationCache.remove_dir(tmp)
				return result
			missing.append(st.name)
	# недостающие, до которых дело не дошло, остаются недостающими
	for n in todo:
		if not run_names.has(n) and not missing.has(n) and n != "dem":
			missing.append(n)
	log_lines.append_array(ctx.log_lines)
	net_requests = ctx.net_requests
	# конфиг места (имя — координаты) и build.json — последним
	if not fixed:
		_write_json(tmp.path_join("location.json"), _location_json(ctx, snapc, key))
	var all_seconds := prev_seconds.duplicate()
	all_seconds.merge(seconds, true)
	var b := {
		"format_version": LocationCache.version(),
		"key": key,
		"center_lat": clat,
		"center_lon": clon,
		"built_utc": Time.get_datetime_string_from_system(true) + "Z",
		"complete": missing.is_empty(),
		"missing": missing,
		"seconds": all_seconds,
		"net_requests": int(old.get("net_requests", 0)) + net_requests,
		"sources": _sources(ctx, missing),
	}
	_write_json(tmp.path_join(LocationCache.BUILD_FILE), b)
	var rn: int = OK
	if fixed:
		rn = _install_fixed(tmp, final_dir)
	else:
		if DirAccess.dir_exists_absolute(final_dir):
			LocationCache.remove_dir(final_dir)
		rn = DirAccess.rename_absolute(tmp, final_dir)
	if rn != OK:
		log_lines.append("не переименована папка места (%d)" % rn)
		LocationCache.remove_dir(tmp)
		result.error = "failed"
		return result
	Locations.invalidate(key)
	result.ok = true
	result.missing = missing
	return result


## Прервать сборку (стадии выходят между шагами).
func cancel() -> void:
	if _ctx != null:
		_ctx.cancelled = true


func stages_list() -> Array:
	if stages.is_empty():
		stages = default_stages()
	return stages


func _all_names() -> Array:
	var out: Array = []
	for st in stages_list():
		out.append(st.name)
	return out


## Стадии игры; загрузка через load() — класс-имена и автозагрузки доступны не в каждом контексте.
static func default_stages() -> Array:
	var out: Array = []
	for pair in [
		["dem", "dem_stage"],
		["rivers", "river_stage"],
		["surface", "surface_stage"],
	]:
		var path := "res://scripts/terrain/build/%s.gd" % pair[1]
		if ResourceLoader.exists(path):
			out.append({"name": pair[0], "obj": (load(path) as GDScript).new()})
		else:
			out.append({"name": pair[0], "obj": _Absent.new()})
	return out


## Заглушка стадии, которой ещё нет в коде: всегда отказ (слой — в missing).
class _Absent:
	func run(_ctx: LocationBuildContext) -> Error:
		return ERR_UNAVAILABLE


func _spec(key: String, c: Vector2) -> Dictionary:
	var tpl: Dictionary = Config.value("world", "location_builder.template", {})
	var spec: Dictionary = fixed_spec.duplicate(true) if out_dir != "" else tpl.duplicate(true)
	spec.merge(spec_override, true)
	spec.center_lat = c.x
	spec.center_lon = c.y
	spec.data_dir = out_dir if out_dir != "" else LocationCache.dir_for(key)
	return spec


func _location_json(ctx: LocationBuildContext, c: Vector2, key: String) -> Dictionary:
	var loc: Dictionary = ctx.spec.duplicate(true)
	loc.erase("dem_sources")
	loc.center_lat = c.x
	loc.center_lon = c.y
	loc.utc_offset_h = int(roundf(c.y / 15.0))
	loc.data_dir = LocationCache.dir_for(key)
	loc.name = _place_name(c)
	loc.start_sites = []
	return loc


## Имя места точки — её координаты (встроенные места берут имя из своего конфига).
static func _place_name(c: Vector2) -> String:
	return "%.3f, %.3f" % [c.x, c.y]


func _sources(ctx: LocationBuildContext, missing: Array) -> Array:
	var out: Array = []
	for id in ctx.layers:
		var s := String(ctx.layers[id].get("source", ""))
		if s != "" and not out.has(s):
			out.append(s)
	if not missing.has("surface"):
		out.append("worldcover")
	return out


## Высоты и слои из уже собранной папки — для стадий, которым нужен результат рельефа.
func _load_dem(ctx: LocationBuildContext, dir: String) -> bool:
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	if not meta is Dictionary:
		return false
	ctx.heights = {}
	ctx.layers = {}
	for info: Dictionary in meta.get("layers", []):
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		if l == null:
			return false
		ctx.heights[String(info.id)] = l.heights
		ctx.layers[String(info.id)] = info
	return not ctx.layers.is_empty()


## Встроенное место: старые файлы результата (кроме .import) заменяются новыми из tmp.
static func _install_fixed(tmp: String, final_dir: String) -> int:
	DirAccess.make_dir_recursive_absolute(final_dir)
	var da := DirAccess.open(final_dir)
	if da == null:
		return ERR_CANT_OPEN
	for f in da.get_files():
		if not f.ends_with(".import"):
			da.remove(f)
	var ta := DirAccess.open(tmp)
	for f in ta.get_files():
		var e := DirAccess.copy_absolute(tmp.path_join(f), final_dir.path_join(f))
		if e != OK:
			return e
	LocationCache.remove_dir(tmp)
	return OK


static func _copy_dir(from: String, to: String) -> void:
	var da := DirAccess.open(from)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


static func _write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "  ") + "\n")
		f.close()
