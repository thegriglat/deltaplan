extends Node
## Загрузка JSON-конфигов (NFR-7: все числа — в конфигах).
##
## Имя конфига — путь без расширения относительно папки configs, например "wings/sport".
## Файлы ищутся по порядку, каждый следующий поверх предыдущего (глубокое слияние словарей):
##   1. res://configs/<name>.json            — значения по умолчанию, лежат в репозитории
##   2. <папка exe>/configs/<name>.json      — правки пилота рядом с игрой (только в сборке)
##   3. user://configs/<name>.json           — правки пилота в профиле пользователя
## Ключи, начинающиеся с "_" (например "_doc"), — комментарии, код их игнорирует.

signal reloaded

var _cache: Dictionary = {}


func _ready() -> void:
	apply_engine_settings()


func apply_engine_settings() -> void:
	var sim := get_config("sim")
	Engine.physics_ticks_per_second = int(sim.get("physics_hz", 120))
	Engine.max_physics_steps_per_frame = int(sim.get("max_physics_steps_per_frame", 16))


## Возвращает весь конфиг. Пустой словарь (и ошибка в лог), если файла нет нигде.
func get_config(config_name: String) -> Dictionary:
	if _cache.has(config_name):
		return _cache[config_name]
	var result: Dictionary = {}
	var found := false
	for dir in search_dirs():
		var path := dir.path_join(config_name + ".json")
		if not FileAccess.file_exists(path):
			continue
		var data: Variant = _load_json(path)
		if data is Dictionary:
			result = _deep_merge(result, data)
			found = true
	if not found:
		push_error("Config: не найден конфиг '%s'" % config_name)
	_cache[config_name] = result
	return result


## Значение по ключу; ключ может быть путём через точку: "polar.stall_speed_kmh".
func value(config_name: String, key: String, default: Variant = null) -> Variant:
	var node: Variant = get_config(config_name)
	for part in key.split("."):
		if node is Dictionary and node.has(part):
			node = node[part]
		else:
			if default == null:
				push_error("Config: нет ключа '%s' в '%s'" % [key, config_name])
			return default
	return node


## Имена конфигов в подпапке: list_configs("wings") -> ["kingpost", "sport", "training"].
func list_configs(subdir: String) -> PackedStringArray:
	var names := {}
	for dir in search_dirs():
		var d := DirAccess.open(dir.path_join(subdir))
		if d == null:
			continue
		for f in d.get_files():
			if f.get_extension() == "json":
				names[subdir.path_join(f.get_basename())] = true
	var out := PackedStringArray(names.keys())
	out.sort()
	return out


## Сбросить кеш (после правки файлов пилотом).
func reload() -> void:
	_cache.clear()
	apply_engine_settings()
	reloaded.emit()


func search_dirs() -> PackedStringArray:
	var dirs := PackedStringArray(["res://configs"])
	if not OS.has_feature("editor"):
		dirs.append(OS.get_executable_path().get_base_dir().path_join("configs"))
	dirs.append("user://configs")
	return dirs


func _load_json(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("Config: ошибка в %s, строка %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


static func _deep_merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in over:
		if out.has(k) and out[k] is Dictionary and over[k] is Dictionary:
			out[k] = _deep_merge(out[k], over[k])
		else:
			out[k] = over[k]
	return out
