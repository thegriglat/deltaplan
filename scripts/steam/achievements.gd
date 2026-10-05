extends Node
## Автозагрузка Achievements (контракт S6, ST-6): трекер ачивок по потоку S2.
## Игра шлёт on_flight_started / on_flight_sample / on_flight_finished (AchievementFeed, ST-5).
## Прогресс — user://achievements.json; в Steam — setAchievement + storeStats; без Steam — молча.

signal unlocked(api: String)

const Rules := preload("res://scripts/steam/achievement_rules.gd")
const CONFIG_PATH := "res://configs/achievements.json"
const DEFAULT_PROGRESS_PATH := "user://achievements.json"

var progress_path := DEFAULT_PROGRESS_PATH
## Узел SteamService; по умолчанию — автозагрузка. Тесты подставляют свой.
var service: Node = null

var _defs: Array = []
var _progress: Dictionary = {}
var _ctx: Dictionary = {}
var _acc: Dictionary = {}  # api -> накопители полёта
var _in_flight := false
var _last_t := NAN


func _ready() -> void:
	start()


## Загрузка конфига и прогресса, привязка к Steam. Отдельно от _ready — для тестов.
func start() -> void:
	if service == null and is_inside_tree():
		service = get_node_or_null("/root/SteamService")
	_defs = _read_defs()
	_progress = _read_progress()
	if service != null and service.has_signal("activated") and not service.is_connected("activated", sync_steam):
		service.connect("activated", sync_steam)
	sync_steam()


func is_unlocked(api: String) -> bool:
	return (_progress.unlocked as Dictionary).has(api)


func unlocked_count() -> int:
	return (_progress.unlocked as Dictionary).size()


## Копия прогресса (для UI и тестов).
func progress() -> Dictionary:
	return _progress.duplicate(true)


func on_flight_started(ctx: Dictionary) -> void:
	_ctx = ctx.duplicate()
	_in_flight = true
	_last_t = NAN
	_acc.clear()
	for d: Dictionary in _defs:
		_acc[d.api] = {}


func on_flight_sample(s: Dictionary) -> void:
	if not _in_flight:
		return
	var t := float(s.get("t", NAN))
	var dt := 0.0 if (is_nan(_last_t) or is_nan(t)) else maxf(t - _last_t, 0.0)
	_last_t = t
	var fresh: Array = []
	for d: Dictionary in _defs:
		if is_unlocked(d.api):
			continue
		Rules.sample(d.rule, _acc[d.api], s, dt)
		if Rules.live(d.rule, _acc[d.api], _ctx, s):
			_progress.unlocked[d.api] = int(Time.get_unix_time_from_system())
			fresh.append(d.api)
	_announce(fresh)


func on_flight_finished(fin: Dictionary) -> void:
	if not _in_flight:
		return
	_in_flight = false
	if String(fin.get("kind", "")) != "landed":
		return
	Rules.update_progress(_progress, _ctx, fin)
	var fresh: Array = []
	for d: Dictionary in _defs:
		if is_unlocked(d.api):
			continue
		if Rules.check(d.rule, _acc.get(d.api, {}), _ctx, fin, _progress):
			_progress.unlocked[d.api] = int(Time.get_unix_time_from_system())
			fresh.append(d.api)
	_announce(fresh)


## Сохранить прогресс и сообщить об открытых ачивках (локально, Steam, сигнал).
func _announce(fresh: Array) -> void:
	_save()
	for api: String in fresh:
		print("achievements: unlocked %s" % api)
		_push_to_steam(api)
		unlocked.emit(api)
	if not fresh.is_empty():
		_store_stats()


## Передать Steam всё локально открытое, чего там ещё нет (идемпотентно).
func sync_steam() -> void:
	if service == null or not service.is_active():
		return
	var any := false
	for api: String in _progress.unlocked:
		if not _steam_has(api):
			_push_to_steam(api)
			any = true
	if any:
		_store_stats()


func _steam_has(api: String) -> bool:
	var r: Variant = service.api().call("getAchievement", api)
	return r is Dictionary and r.get("achieved", false) == true


func _push_to_steam(api: String) -> void:
	if service != null and service.is_active():
		service.api().call("setAchievement", api)


func _store_stats() -> void:
	if service != null and service.is_active():
		service.api().call("storeStats")


func _read_defs() -> Array:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	return data.get("achievements", []) if data is Dictionary else []


func _read_progress() -> Dictionary:
	var p := {"version": 1, "unlocked": {}, "places": [], "flights": 0,
			"continents": [], "wings": [], "airtime_s": 0.0}
	if FileAccess.file_exists(progress_path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(progress_path))
		if data is Dictionary:
			for k: String in p:
				if data.has(k) and typeof(data[k]) == typeof(p[k]):
					p[k] = data[k]
			if typeof(data.get("flights")) == TYPE_FLOAT:
				p["flights"] = int(data["flights"])
	return p


func _save() -> void:
	var f := FileAccess.open(progress_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_progress, "\t"))
