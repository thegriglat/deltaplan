class_name Favorites
extends RefCounted
## Избранные условия полёта (QL-12): место, час, ветер, облачность, температура, крыло —
## FlightSettings.to_dict(). Хранится в user://favorites.json: {next_id, items: [{id, ts, settings}]}.
## Новые — первыми; больше MAX_ITEMS не хранится (девятое вытесняет самое старое).

const PATH := "user://favorites.json"
const MAX_ITEMS := 8


static func _load_root(path: String) -> Dictionary:
	var root: Dictionary = {"next_id": 1, "items": []}
	if not FileAccess.file_exists(path):
		return root
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d is Dictionary:
		root.next_id = int(d.get("next_id", 1))
		var items: Variant = d.get("items", [])
		if items is Array:
			root.items = items.filter(func(e: Variant) -> bool: return e is Dictionary and e.get("settings") is Dictionary)
	return root


static func _save_root(path: String, root: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Favorites: не записать %s (%s)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(root, "  "))
	f.close()


## Записи, новые первыми: [{id, ts, settings: Dictionary}].
static func list(path: String = PATH) -> Array:
	return _load_root(path).items


## Добавить условия; возвращает id. Такие же уже есть — поднимаются наверх, без дубля.
static func add(s: FlightSettings, path: String = PATH, ts: float = -1.0) -> int:
	var root := _load_root(path)
	var d := s.to_dict()
	var items: Array = root.items
	for i in items.size():
		if JSON.stringify(FlightSettings.from_dict(items[i].settings).to_dict()) == JSON.stringify(d):
			items.remove_at(i)
			break
	var id: int = root.next_id
	root.next_id = id + 1
	items.push_front({"id": id, "ts": Time.get_unix_time_from_system() if ts < 0.0 else ts, "settings": d})
	while items.size() > MAX_ITEMS:
		items.pop_back()
	root.items = items
	_save_root(path, root)
	return id


static func remove(id: int, path: String = PATH) -> void:
	var root := _load_root(path)
	var items: Array = root.items
	for i in items.size():
		if int(items[i].get("id", -1)) == id:
			items.remove_at(i)
			break
	_save_root(path, root)


## Настройки записи id (null — нет такой).
static func settings_of(id: int, path: String = PATH) -> FlightSettings:
	for e: Dictionary in list(path):
		if int(e.get("id", -1)) == id:
			return FlightSettings.from_dict(e.settings)
	return null


## Автоназвание: «Онгудай, 13:00, 3 м/с СЗ, Sport».
static func auto_name(s: FlightSettings) -> String:
	var t := func(k: String) -> String: return TranslationServer.translate(k)
	var place: String
	if s.has_pick():
		place = t.call("menu_point") % [s.pick_lat, s.pick_lon]
	else:
		var loc: Dictionary = Config.get_config("locations/" + s.location_id)
		place = t.call(String(loc.get("name", s.location_id)))
	var ms := roundi(s.wind_speed_kmh / 3.6)
	var wind: String = t.call("setup_wind_calm")
	if ms > 0:
		var dir: String = (
			String(t.call("setup_wind_into_launch")).to_lower()
			if s.wind_into_launch
			else t.call(FlightSetupScreen.COMPASS[posmod(roundi(s.wind_from_deg / 45.0), 8)])
		)
		wind = t.call("fav_wind") % [ms, dir]
	place = place.split(" — ")[-1]
	return "%s, %s, %s, %s" % [place, SunClock.format_hour(s.start_hour), wind, s.wing_id().capitalize()]
