class_name Locations
extends RefCounted
## Реестр мест (OA-К4, docs/contracts/osm-any.md): встроенные (configs/locations/<id>.json,
## data/terrain/<id>/) и кешированные точки (user://locations/<ключ>/).

const KEY_PREFIX := "pt_"

## Версия формата файлов места (build.json -> format_version): поднимать при любом изменении
## файлов места (имена, кодирование, состав). Кеш места с другой версией удаляется целиком и
## собирается заново. Версия сырых блоков источника — LocationCache.SOURCE_VERSION (отдельная).
const FORMAT_VERSION := 2

## Корень готовых мест вместо кеша (только тесты: tests/run_tests.gd ставит tests/fixtures/locations;
## пустой — настоящий кеш user://locations). Встроенные места в паке не лежат (NO-8).
static var fixtures_root: String = ""

static var _cfg_cache: Dictionary = {}


static func cache_dir() -> String:
	return String(Config.value("world", "location_builder.cache_dir", "user://locations"))


## Id встроенных мест (без префикса locations/).
static func builtin_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for n in Config.list_configs("locations"):
		out.append(n.get_file())
	return out


static func is_builtin(id: String) -> bool:
	return id != "" and Config.list_configs("locations").has("locations/" + id)


## Папка файлов места: фикстуры тестов (если заданы и там есть место) или кеш user://locations/<id>
## (встроенные собираются туда при первом выборе, NO-8; точки — под своим ключом).
static func data_dir(id: String) -> String:
	if fixtures_root != "" and is_builtin(id):
		return fixtures_root.path_join(id)
	return cache_dir().path_join(id)


## Есть ли такое место: встроенное или кешированное с конфигом.
static func exists(id: String) -> bool:
	if is_builtin(id):
		return true
	return _is_cache_key(id) and FileAccess.file_exists(cache_dir().path_join(id).path_join("location.json"))


## Конфиг места; пустой словарь — нет такого.
static func config(id: String) -> Dictionary:
	if id == "":
		return {}
	if is_builtin(id):
		return Config.get_config("locations/" + id)
	if not _is_cache_key(id):
		return {}
	var path := cache_dir().path_join(id).path_join("location.json")
	if not FileAccess.file_exists(path):
		_cfg_cache.erase(id)
		return {}
	var mtime := FileAccess.get_modified_time(path)
	var hit: Dictionary = _cfg_cache.get(id, {})
	if not hit.is_empty() and hit.mtime == mtime:
		return hit.cfg
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		_cfg_cache.erase(id)
		return {}
	_cfg_cache[id] = {"mtime": mtime, "cfg": d}
	return d


## Встроенное место, в детальном квадрате которого лежит точка не ближе builtin_margin_km к краю;
## иначе "".
static func builtin_at(lat: float, lon: float) -> String:
	var margin := float(Config.value("world", "location_builder.builtin_margin_km", 10.0))
	for id in builtin_ids():
		var loc := config(id)
		var layers: Array = loc.get("dem", {}).get("layers", [])
		if layers.is_empty() or not loc.has("center_lat"):
			continue
		var half := float(layers[0].get("size_km", 0.0)) * 0.5 - margin
		var clat := float(loc.center_lat)
		var dy := (lat - clat) * 111.32
		var dx := (lon - float(loc.center_lon)) * 111.32 * cos(deg_to_rad(clat))
		if absf(dx) <= half and absf(dy) <= half:
			return id
	return ""


## Забыть прочитанный конфиг места (после пересборки папки).
static func invalidate(id: String) -> void:
	_cfg_cache.erase(id)


static func _is_cache_key(id: String) -> bool:
	return id.begins_with(KEY_PREFIX) and not id.contains("/") and not id.contains("..")
