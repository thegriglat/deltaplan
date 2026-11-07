class_name AirModelHash
extends RefCounted
## Хеш модели воздуха (TI-К3 v3, WF-К1 v2): ключ записей кеша полей и заголовка места крейта
## (AirPlaceData.fill_crate_inputs → header.model_hash). Код (code_hash) и секции air_model и
## air_phase configs/atmosphere.json, weather_model.json, surface_heat.json. Вынесен из
## прежнего класса запечённых полей (их в игре нет); поведение прежнее.

## Файл с хешем кода модели в экспорте (.gd токенизированы, .glsl импортированы — исходники из pck
## не прочитать); в сборке (tools/build.sh) его пока никто не пишет.
const CODE_HASH_FILE := "res://data/air_model_hash.txt"

static var _code_hash_cache := ""


## Хеш кода модели по исходникам: *.gd и *.glsl каталога модели. "" — исходники
## не читаются (экспорт).
static func code_hash_of_sources() -> String:
	var dir := "res://scripts/atmosphere/air_model"
	var names := Array(DirAccess.get_files_at(dir))
	names.sort()
	var lines := PackedStringArray()
	for n: String in names:
		if (n.ends_with(".gd") or n.ends_with(".glsl")):
			lines.append("%s:%s" % [n, FileAccess.get_sha256(dir.path_join(n))])
	if lines.is_empty():
		return ""
	return "\n".join(lines).sha256_text()


## Хеш кода модели: по исходникам, а если они не читаются (экспорт) — из CODE_HASH_FILE. "" — нет ни
## того, ни другого.
static func code_hash() -> String:
	if _code_hash_cache != "":
		return _code_hash_cache
	var h := code_hash_of_sources()
	if h == "" and FileAccess.file_exists(CODE_HASH_FILE):
		h = FileAccess.get_file_as_string(CODE_HASH_FILE).strip_edges()
	_code_hash_cache = h
	return h


## Конфиг без слоёв профиля пилота (user://configs, user://local/configs): те — настройки машины и
## пилота (в т. ч. весь atmosphere.air_model как машинный ключ S7), на модель не влияют, а хеш от
## профиля делал запись кеша «устаревшей» в другом профиле. Берутся res://configs и правки
## рядом с игрой (их пилот правит осознанно: изменённая модель — кеш не берётся).
static func _model_config(config_name: String) -> Dictionary:
	var dirs := PackedStringArray(["res://configs"])
	if not OS.has_feature("editor"):
		dirs.append(OS.get_executable_path().get_base_dir().path_join("configs"))
	var out := {}
	for d in dirs:
		var path := d.path_join(config_name + ".json")
		if not FileAccess.file_exists(path):
			continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			out = _merge(out, data)
	return out


static func _merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k: Variant in over:
		if out.has(k) and out[k] is Dictionary and over[k] is Dictionary:
			out[k] = _merge(out[k], over[k])
		else:
			out[k] = over[k]
	return out


## Хеш модели воздуха (TI-К3 v3): код (code_hash) и секции air_model и air_phase configs/atmosphere.json,
## weather_model.json, surface_heat.json (слои конфигов — _model_config, без профиля пилота).
## "" — кода не узнать: кеш не брать.
static func model_hash() -> String:
	var lines := PackedStringArray()
	var code := code_hash()
	if code == "":
		return ""
	lines.append("code:" + code)
	var atm := _model_config("atmosphere")
	for part: Array in [
		["air_model", atm.get("air_model", {})],
		["air_phase", atm.get("air_phase", {})],
		["weather_model", _model_config("weather_model")],
		["surface_heat", _model_config("surface_heat")],
	]:
		lines.append("%s:%s" % [part[0], JSON.stringify(part[1], "", true).sha256_text()])
	return "\n".join(lines).sha256_text().substr(0, 16)
