class_name UserSettings
extends RefCounted
## Настройки пилота (NFR-6): правки поверх конфигов пишутся в user://configs/<имя>.json —
## Config подхватывает их третьим слоем. Пишется только то, что меняли, остальное
## остаётся из res://configs. Плюс последний выбор меню — user://last_flight.json.

const DEFAULT_DIR := "user://configs"
const LAST_FLIGHT := "user://last_flight.json"


## Дописать patch (вложенный словарь) в user-конфиг config_name и сбросить кеш Config.
static func save_patch(config_name: String, patch: Dictionary, dir: String = DEFAULT_DIR) -> bool:
	var path := dir.path_join(config_name + ".json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var current := read_json(path)
	var merged: Dictionary = Config._deep_merge(current, patch)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("UserSettings: не записать %s (%s)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(merged, "  "))
	f.close()
	return true


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}


static func save_last_flight(s: FlightSettings, path: String = LAST_FLIGHT) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(s.to_dict(), "  "))


## Последний выбор меню поверх значений по умолчанию.
static func load_last_flight(path: String = LAST_FLIGHT) -> FlightSettings:
	var d := read_json(path)
	var s := FlightSettings.defaults()
	if d.is_empty():
		return s
	s = FlightSettings.from_dict(d, s)
	# Файл мог остаться от старой версии: несуществующие конфиги — по умолчанию.
	if not Config.list_configs("wings").has(s.wing):
		s.wing = FlightSettings.defaults().wing
	if not Config.list_configs("weather").has(s.weather):
		s.weather = FlightSettings.defaults().weather
	# Прогноз: мусор и числа вне меню — в диапазон (неизвестный старый пресет уже дал умолчание).
	s.clamp_forecast()
	if not Config.list_configs("locations").has("locations/" + s.location_id):
		s.location_id = FlightSettings.defaults().location_id
		s.site_id = FlightSettings.defaults().site_id
	return s
