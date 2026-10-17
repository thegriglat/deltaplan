class_name Biome
extends RefCounted
## Регион места по (lat, lon) — RV-К1. Данные: configs/biomes.json (tools/world/bake_biomes.py), читаются один раз.
## Высота не входит: пояса пород по высоте — trees.species.*.min_m/max_m.

const FALLBACK := "boreal"

static var path: String = "res://configs/biomes.json"
static var _data: Dictionary = {}
static var _loaded: bool = false


## Сбросить кеш (после смены path).
static func reset() -> void:
	_data = {}
	_loaded = false


static func _load() -> Dictionary:
	if _loaded:
		return _data
	_loaded = true
	_data = {}
	if not FileAccess.file_exists(path):
		return _data
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d is Dictionary and d.get("tree") is Array and not (d.tree as Array).is_empty() and d.get("classes") is Array:
		_data = d
	return _data


## Id профиля: исключение (первое совпадение, границы включительно), иначе лист дерева. Нет данных — "boreal".
static func at(lat: float, lon: float) -> String:
	var d := _load()
	if d.is_empty():
		return FALLBACK
	for e: Variant in d.get("exceptions", []):
		var ex: Dictionary = e
		var la: Array = ex.lat
		var lo: Array = ex.lon
		if lat >= float(la[0]) and lat <= float(la[1]) and lon >= float(lo[0]) and lon <= float(lo[1]):
			return String(ex.profile)
	return classify_tree(lat, lon)


## Только дерево решений (класс из classes).
static func classify_tree(lat: float, lon: float) -> String:
	var d := _load()
	if d.is_empty():
		return FALLBACK
	var tree: Array = d.tree
	var classes: Array = d.classes
	var n := 0
	for _i in 40:
		if n < 0 or n >= tree.size():
			return FALLBACK
		var node: Array = tree[n]
		if int(node[0]) == -1:
			var k := int(node[1])
			return String(classes[k]) if k >= 0 and k < classes.size() else FALLBACK
		var x := lat if int(node[0]) == 0 else lon
		n = int(node[2]) if x <= float(node[1]) else int(node[3])
	return FALLBACK


## Копия профиля; неизвестный id — {}.
static func profile(id: String) -> Dictionary:
	var p: Variant = _load().get("profiles", {}).get(id)
	return (p as Dictionary).duplicate(true) if p is Dictionary else {}
