class_name LocationCache
extends RefCounted
## Кеш собранных мест user://locations/<ключ>/ (OA-К4): ключ точки, папка, полнота по build.json.

const BUILD_FILE := "build.json"


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
	return int(_cfg("version", 1))


## Содержимое build.json папки места; пустой словарь — нет или битый.
static func read_build(dir: String) -> Dictionary:
	var p := dir.path_join(BUILD_FILE)
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if d is Dictionary else {}


## Версия сборщика в build.json совпадает с текущей (место пригодно, пусть и без некоторых слоёв).
static func is_current(build: Dictionary) -> bool:
	return not build.is_empty() and int(build.get("builder_version", -1)) == version()


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
