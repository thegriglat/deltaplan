class_name FlightRecords
extends RefCounted
## Локальные рекорды (FR-37, NFR-6): лучшие время в воздухе, дальность и высота по локации и
## крылу; для маршрутных заданий — лучшее время скоростного участка и дальность по заданию.
## Хранение — JSON в user://records.json (путь в configs/tasks/settings.json → records.path).
##
## Файл: {"version": 1, "records": {"<ключ>": {"<категория>": {value, date, wing, location}}}}
## ключ — "free|<локация>|<крыло>" или "task|<id задания>|<крыло>".

const VERSION := 1
## Категории: ключ результата → true, если больше — лучше.
const FREE_CATEGORIES := {
	"flight_time_s": true,
	"distance_m": true,
	"max_altitude_msl_m": true,
}
const TASK_CATEGORIES := {
	"speed_section_time_s": false,
	"distance_m": true,
}

var path: String = "user://records.json"
var min_flight_time_s: float = 10.0
var records: Dictionary = {}


## path_override — для тестов; по умолчанию путь из настроек.
func _init(path_override: String = "", settings: Dictionary = {}) -> void:
	if settings.is_empty():
		settings = Config.get_config("tasks/settings")
	var r: Dictionary = settings.get("records", {})
	path = path_override if path_override != "" else String(r.get("path", path))
	min_flight_time_s = float(r.get("min_flight_time_s", min_flight_time_s))
	load_records()


func load_records() -> void:
	records = {}
	if not FileAccess.file_exists(path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary and data.get("records") is Dictionary:
		records = data.records
	else:
		push_warning("FlightRecords: файл %s повреждён, рекорды начинаются заново" % path)


func save() -> bool:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("FlightRecords: не записать %s" % path)
		return false
	f.store_string(JSON.stringify({"version": VERSION, "records": records}, "\t"))
	return true


## Учесть полёт. result: {location, wing, flight_time_s, distance_m, max_altitude_msl_m, [date],
## [task: TaskTracker.result()]} — FlightStats.summary + локация, крыло и итог задания.
## Возвращает новые рекорды: {"<категория>": {value, previous}} (пусто — рекордов нет),
## категории задания — с префиксом "task_". Сохраняет файл, если есть новые.
func add_flight(result: Dictionary) -> Dictionary:
	var out := {}
	if float(result.get("flight_time_s", 0.0)) < min_flight_time_s:
		return out
	var wing := String(result.get("wing", ""))
	var location := String(result.get("location", ""))
	var free_key := "free|%s|%s" % [location, wing]
	_merge(out, _apply(free_key, FREE_CATEGORIES, result, result, ""))
	var task: Dictionary = result.get("task", {})
	var task_id := String(task.get("task_id", ""))
	if task_id != "":
		var values := task.duplicate()
		if not bool(task.get("made_goal", false)):
			values.erase("speed_section_time_s")  # время — только для долетевших
		var key := "task|%s|%s" % [task_id, wing]
		_merge(out, _apply(key, TASK_CATEGORIES, values, result, "task_"))
	if not out.is_empty():
		save()
	return out


## Рекорд или {} : get_record("free|altai|sport", "distance_m") → {value, date, ...}.
func get_record(key: String, category: String) -> Dictionary:
	return records.get(key, {}).get(category, {})


func free_records(location: String, wing: String) -> Dictionary:
	return records.get("free|%s|%s" % [location, wing], {})


func task_records(task_id: String, wing: String) -> Dictionary:
	return records.get("task|%s|%s" % [task_id, wing], {})


func clear() -> void:
	records = {}
	save()


## values — откуда брать значения категорий, meta — дата, крыло, локация.
func _apply(
	key: String, categories: Dictionary, values: Dictionary, meta: Dictionary, prefix: String
) -> Dictionary:
	var out := {}
	var slot: Dictionary = records.get(key, {})
	for cat: String in categories:
		if not values.has(cat):
			continue
		var v := float(values[cat])
		if is_nan(v) or is_inf(v) or v <= 0.0:
			continue
		var more_is_better: bool = categories[cat]
		var old: Dictionary = slot.get(cat, {})
		var better := old.is_empty()
		if not better:
			var ov := float(old.value)
			better = v > ov if more_is_better else v < ov
		if better:
			out[prefix + cat] = {"value": v, "previous": old.get("value", null)}
			slot[cat] = {
				"value": v,
				"date": String(meta.get("date", Time.get_datetime_string_from_system())),
				"wing": String(meta.get("wing", "")),
				"location": String(meta.get("location", "")),
			}
	if not slot.is_empty():
		records[key] = slot
	return out


static func _merge(into: Dictionary, what: Dictionary) -> void:
	for k: String in what:
		into[k] = what[k]
