class_name LocationCache
extends RefCounted
## Кеш собранных мест user://locations/<ключ>/ (OA-К4): ключ точки, папка, полнота по build.json.

const BUILD_FILE := "build.json"
## Версия сырых блоков источника (user://terrain_cache: COG Copernicus/WorldCover, тайлы Terrarium).
## Поднимать при смене источника или нарезки блоков; смена Locations.FORMAT_VERSION кеш блоков не сбрасывает.
const SOURCE_VERSION := 1
const SOURCE_VERSION_FILE := "source_version.txt"


static func _cfg(key: String, default: Variant) -> Variant:
	return Config.value("world", "location_builder." + key, default)


## Центр места: точка, округлённая к сетке snap_deg, в градусах (без «минус нуля»).
static func snap(lat: float, lon: float) -> Vector2:
	var step := float(_cfg("snap_deg", 0.05))
	return Vector2(_snap1(lat, step), _snap1(lon, step))


static func _snap1(v: float, step: float) -> float:
	var s := roundf(roundf(v / step) * step * 1000.0) / 1000.0
	return 0.0 if is_zero_approx(s) else s


static func key_for(lat: float, lon: float) -> String:
	var c := snap(lat, lon)
	return "pt_%+07.3f_%+08.3f" % [c.x, c.y]


static func dir_for(key: String) -> String:
	return String(_cfg("cache_dir", "user://locations")).path_join(key)


static func tmp_dir_for(key: String) -> String:
	return String(_cfg("cache_dir", "user://locations")).path_join(".tmp_" + key)


static func version() -> int:
	return Locations.FORMAT_VERSION


## Кеш сырых блоков записан для другой SOURCE_VERSION — очистить и записать текущую. Кеш без файла
## версии (до его введения) считается текущим. true — кеш был сброшен.
static func ensure_source_cache(root: String) -> bool:
	var vp := root.path_join(SOURCE_VERSION_FILE)
	var wiped := false
	if FileAccess.file_exists(vp):
		if FileAccess.get_file_as_string(vp).strip_edges() == str(SOURCE_VERSION):
			return false
		remove_dir(root)
		wiped = true
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(vp, FileAccess.WRITE)
	if f != null:
		f.store_string(str(SOURCE_VERSION) + "\n")
		f.close()
	return wiped


## Содержимое build.json папки места; пустой словарь — нет или битый.
static func read_build(dir: String) -> Dictionary:
	var p := dir.path_join(BUILD_FILE)
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if d is Dictionary else {}


## Версия сборщика в build.json совпадает с текущей (место пригодно, пусть и без некоторых слоёв).
static func is_current(build: Dictionary) -> bool:
	return not build.is_empty() and int(build.get("format_version", -1)) == version()


## Место полное: build.json с complete и текущей версией сборщика.
static func is_complete(key: String) -> bool:
	var b := read_build(dir_for(key))
	return is_current(b) and bool(b.get("complete", false))


## Удалить папку со всем содержимым (плоскую; подпапок в месте нет).
static func remove_dir(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
	for sub in da.get_directories():
		remove_dir(dir.path_join(sub))
	DirAccess.remove_absolute(dir)


## Суммарный размер файлов папки, байт.
static func dir_size(dir: String) -> int:
	var da := DirAccess.open(dir)
	if da == null:
		return 0
	var total := 0
	for f in da.get_files():
		var fa := FileAccess.open(dir.path_join(f), FileAccess.READ)
		if fa != null:
			total += fa.get_length()
	return total
