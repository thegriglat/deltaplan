class_name RecentPlaces
extends RefCounted
## Недавние места, выбранные на карте (экран «Полёт…», FR-17) — не встроенные площадки локаций.
## Хранится в user://recent_places.json: {next_id, places: [{id, lat, lon, ts, pinned,
## custom_name, osm_name}]}. Новые — сверху; точки ближе DEDUP_DISTANCE_M считаются одной (её
## координаты и время обновляются). Закреплённые (pinned) — всегда сверху и не вытесняются;
## непристёгнутых хранится не больше MAX_UNPINNED (лишние — самые старые по времени — убираются).
## custom_name — своё имя (✎, не трогается автоподписью); osm_name — ближайший населённый пункт
## из уже закешированных данных (res://data/osm/<id>.json, без сети — resolve_osm_name).
## display_name: custom_name → osm_name → координаты «50.6000, 86.4000».

const PATH := "user://recent_places.json"
const MAX_UNPINNED := 8
const DEDUP_DISTANCE_M := 300.0
const OSM_DIR := "res://data/osm"


static func _load_root(path: String) -> Dictionary:
	var root: Dictionary = {"next_id": 1, "places": []}
	if not FileAccess.file_exists(path):
		return root
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d is Dictionary:
		root.next_id = int(d.get("next_id", 1))
		var places: Variant = d.get("places", [])
		if places is Array:
			root.places = places
	return root


static func _save_root(path: String, root: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("RecentPlaces: не записать %s (%s)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(root, "  "))
	f.close()


## Места для показа: закреплённые сверху (по времени), затем недавние — тоже по убыванию времени.
static func list(path: String = PATH) -> Array[Dictionary]:
	var root := _load_root(path)
	var places: Array[Dictionary] = []
	for p: Dictionary in root.places:
		places.append(p)
	places.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ap := bool(a.get("pinned", false))
			var bp := bool(b.get("pinned", false))
			if ap != bp:
				return ap
			return float(a.get("ts", 0)) > float(b.get("ts", 0))
	)
	return places


## Плоское расстояние по широте/долготе, м (годится для дедупа ~300 м и поиска в пределах локации).
static func distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var mlat := TerrainGeo.meters_per_deg_lat()
	var mlon := TerrainGeo.meters_per_deg_lon((lat1 + lat2) * 0.5)
	var dy := (lat1 - lat2) * mlat
	var dx := (lon1 - lon2) * mlon
	return sqrt(dx * dx + dy * dy)


## Добавить точку (или обновить существующую в пределах DEDUP_DISTANCE_M — на верх списка,
## своё время и координаты). osm_name — если уже известно (resolve_osm_name); "" — подпишется
## координатами, имя можно дозаполнить позже (refresh_missing_names/update_osm_name).
## Возвращает id записи (для set_pinned/rename/remove). ts_override — своё время (тесты);
## < 0 — текущее время.
static func add(
	lat: float, lon: float, osm_name: String = "", path: String = PATH, ts_override: float = -1.0
) -> int:
	var root := _load_root(path)
	var places: Array = root.places
	var found: Dictionary = {}
	for p: Dictionary in places:
		if distance_m(lat, lon, float(p.get("lat", 0.0)), float(p.get("lon", 0.0))) <= DEDUP_DISTANCE_M:
			found = p
			break
	var now := ts_override if ts_override >= 0.0 else float(Time.get_unix_time_from_system())
	var id: int
	if not found.is_empty():
		found.lat = lat
		found.lon = lon
		found.ts = now
		if osm_name != "" and String(found.get("osm_name", "")) == "":
			found.osm_name = osm_name
		id = int(found.id)
	else:
		id = int(root.next_id)
		root.next_id = id + 1
		places.append(
			{
				"id": id,
				"lat": lat,
				"lon": lon,
				"ts": now,
				"pinned": false,
				"custom_name": "",
				"osm_name": osm_name,
			}
		)
	_trim(places)
	_save_root(path, root)
	return id


## Непристёгнутых — не больше MAX_UNPINNED (лишние — самые старые по времени — убираются);
## закреплённые не считаются и не вытесняются.
static func _trim(places: Array) -> void:
	var unpinned: Array = places.filter(
		func(p: Dictionary) -> bool: return not bool(p.get("pinned", false))
	)
	if unpinned.size() <= MAX_UNPINNED:
		return
	unpinned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.ts) > float(b.ts))
	for drop: Dictionary in unpinned.slice(MAX_UNPINNED):
		places.erase(drop)


static func _find(root: Dictionary, id: int) -> Dictionary:
	for p: Dictionary in root.places:
		if int(p.get("id", -1)) == id:
			return p
	return {}


## Своё имя (кнопка «✎») — не трогается автоподписью из OSM.
static func rename(id: int, name: String, path: String = PATH) -> void:
	var root := _load_root(path)
	var p := _find(root, id)
	if not p.is_empty():
		p.custom_name = name.strip_edges()
		_save_root(path, root)


static func set_pinned(id: int, pinned: bool, path: String = PATH) -> void:
	var root := _load_root(path)
	var p := _find(root, id)
	if not p.is_empty():
		p.pinned = pinned
		_trim(root.places)
		_save_root(path, root)


static func remove(id: int, path: String = PATH) -> void:
	var root := _load_root(path)
	var places: Array = root.places
	for i in range(places.size() - 1, -1, -1):
		if int((places[i] as Dictionary).get("id", -1)) == id:
			places.remove_at(i)
	_save_root(path, root)


## После полёта / когда данные локации закешировались (res://data/osm/<id>.json) — уточнить имя
## места без сети (не трогает своё имя, custom_name).
static func update_osm_name(lat: float, lon: float, name: String, path: String = PATH) -> void:
	if name == "":
		return
	var root := _load_root(path)
	var changed := false
	for p: Dictionary in root.places:
		if distance_m(lat, lon, float(p.get("lat", 0.0)), float(p.get("lon", 0.0))) <= DEDUP_DISTANCE_M:
			p.osm_name = name
			changed = true
	if changed:
		_save_root(path, root)


## Дозаполнить имена мест без имени из уже закешированных OSM-данных (без сети) — вызывать при
## открытии списка: данные могли появиться позже (другая локация докачалась и закешировалась).
static func refresh_missing_names(path: String = PATH, osm_dir: String = OSM_DIR) -> void:
	var root := _load_root(path)
	var changed := false
	for p: Dictionary in root.places:
		if String(p.get("osm_name", "")) == "":
			var name := resolve_osm_name(float(p.get("lat", 0.0)), float(p.get("lon", 0.0)), osm_dir)
			if name != "":
				p.osm_name = name
				changed = true
	if changed:
		_save_root(path, root)


## Подпись для показа: своё имя → ближайший посёлок из OSM → координаты.
static func display_name(p: Dictionary) -> String:
	var custom := String(p.get("custom_name", ""))
	if custom != "":
		return custom
	var osm_name := String(p.get("osm_name", ""))
	if osm_name != "":
		return osm_name
	return "%.4f, %.4f" % [float(p.get("lat", 0.0)), float(p.get("lon", 0.0))]


## Ближайший населённый пункт по уже закешированным данным локаций (res://data/osm/*.json,
## без сетевых запросов) — только если точка попадает в bbox файла (с небольшим запасом).
static func resolve_osm_name(lat: float, lon: float, osm_dir: String = OSM_DIR) -> String:
	var da := DirAccess.open(osm_dir)
	if da == null:
		return ""
	var best_name := ""
	var best_dist := INF
	const MARGIN_DEG := 0.05
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname.get_extension() == "json":
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(osm_dir.path_join(fname)))
			if d is Dictionary:
				var bbox: Array = d.get("bbox_latlon", [])
				if (
					bbox.size() == 4
					and lat >= float(bbox[0]) - MARGIN_DEG
					and lat <= float(bbox[2]) + MARGIN_DEG
					and lon >= float(bbox[1]) - MARGIN_DEG
					and lon <= float(bbox[3]) + MARGIN_DEG
				):
					var clat := float(d.get("center_lat", 0.0))
					var clon := float(d.get("center_lon", 0.0))
					for pl: Dictionary in d.get("places", []):
						var ll := TerrainGeo.local_to_latlon(
							float(pl.get("x", 0.0)), float(pl.get("z", 0.0)), clat, clon
						)
						var dist := distance_m(lat, lon, ll.x, ll.y)
						if dist < best_dist:
							best_dist = dist
							best_name = String(pl.get("n", ""))
		fname = da.get_next()
	da.list_dir_end()
	return best_name
