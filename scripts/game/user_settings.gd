class_name UserSettings
extends RefCounted
## Настройки пилота (NFR-6): правки поверх конфигов пишутся в user://configs/<имя>.json —
## Config подхватывает их третьим слоем. Пишется только то, что меняли, остальное
## остаётся из res://configs. Плюс последний выбор меню — user://last_flight.json.

const DEFAULT_DIR := "user://configs"
const LAST_FLIGHT := "user://last_flight.json"
## Имя пилота (NET-51): user-конфиг game.json → net.pilot_name; пусто/нет — умолчание
## ник Steam (S1.5), затем по языку интерфейса (net_pilot_name_default).
const PILOT_NAME_MAX := 20


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


## Обрезать по краям и до PILOT_NAME_MAX символов (не байт).
static func sanitize_pilot_name(s: String) -> String:
	var trimmed := s.strip_edges()
	if trimmed.length() > PILOT_NAME_MAX:
		trimmed = trimmed.substr(0, PILOT_NAME_MAX)
	return trimmed


static func pilot_name() -> String:
	var raw := String(Config.value("game", "net.pilot_name", ""))
	var name := sanitize_pilot_name(raw)
	if name != "":
		return name
	return default_pilot_name()


## Умолчание (S1.5): ник Steam, если Steam активен, иначе по языку интерфейса.
static func default_pilot_name() -> String:
	var persona := sanitize_pilot_name(SteamService.persona_name())
	if persona != "":
		return persona
	return String(TranslationServer.translate("net_pilot_name_default"))


static func save_pilot_name(name: String, dir: String = DEFAULT_DIR) -> bool:
	return save_patch("game", {"net": {"pilot_name": sanitize_pilot_name(name)}}, dir)


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
	# Несуществующий конфиг крыла — по умолчанию.
	if not Config.list_configs("wings").has(s.wing):
		s.wing = FlightSettings.defaults().wing
	# Прогноз: мусор и числа вне меню — в диапазон.
	s.clamp_forecast()
	if not Config.list_configs("locations").has("locations/" + s.location_id):
		s.location_id = FlightSettings.defaults().location_id
		s.site_id = FlightSettings.defaults().site_id
	return s


## Адрес сервера сетевой игры (NET-50): user-конфиг game.json → net.server_address
## ("IP:порт" или имя; пусто — ещё не вводили).
static func server_address() -> String:
	return String(Config.value("game", "net.server_address", "")).strip_edges()


static func save_server_address(addr: String, dir: String = DEFAULT_DIR) -> void:
	if save_patch("game", {"net": {"server_address": addr.strip_edges()}}, dir):
		Config.reload()
