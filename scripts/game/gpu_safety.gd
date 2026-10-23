class_name GpuSafety
extends RefCounted
## «Безопасная графика» (контракт CR-К4): один переключатель выключает всю тяжёлую GPU-нагрузку —
## display.gpu.* (рубильники эффектов, перечень — configs/game.json → display.gpu), простые облака
## (atmosphere.clouds.renderer = boxes) и расчёт ветра на видеокарте (atmosphere.air_model.enabled = off).
## Включает окно после обрыва (GpuFailureDialog); display.safe_reason = "crash" — пометка в стартовом
## меню и кнопка «Вернуть». Все ключи машинные (user://local/configs). Действует со следующей
## загрузки места (или сразу, если эффект это умеет).

const CRASH := "crash"


## Ключи display.gpu из умолчаний игры (res://configs/game.json), не из пользовательских слоёв.
static func gpu_keys() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open("res://configs/game.json", FileAccess.READ)
	if f == null:
		return out
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		var gpu: Variant = (data.get("display", {}) as Dictionary).get("gpu", {})
		if gpu is Dictionary:
			for k: String in gpu:
				if not k.begins_with("_") and not k.ends_with("_doc"):
					out.append(k)
	return out


static func _patch(on: bool) -> Dictionary:
	var gpu := {}
	for k in gpu_keys():
		gpu[k] = on
	return {
		"game": {"display": {"gpu": gpu}},
		"atmosphere":
		{
			"clouds": {"renderer": "auto" if on else "boxes"},
			"air_model": {"enabled": "auto" if on else "off"},
		},
	}


## Выключить всё тяжёлое; reason — причина (пометка display.safe_reason).
static func apply_safe(reason: String = CRASH, dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var p := _patch(false)
	p.game.display.safe_reason = reason
	var ok := true
	for cfg: String in p:
		ok = UserSettings.save_patch(cfg, p[cfg], dir) and ok
	Config.reload()
	CrashReporter.refresh_switches()  # снимок рубильников в метке сеанса (отчёт о вылете)
	return ok


## Вернуть всё включённым, пометку убрать.
static func restore(dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var p := _patch(true)
	var ok := true
	for cfg: String in p:
		ok = UserSettings.save_patch(cfg, p[cfg], dir) and ok
	ok = _erase_local("game", ["display", "safe_reason"], dir) and ok
	Config.reload()
	CrashReporter.refresh_switches()
	return ok


## Безопасный набор включён окном после обрыва.
static func is_safe_by_crash() -> bool:
	return String(Config.value("game", "display.safe_reason", "")) == CRASH


## Удалить ключ по пути из машинного user-конфига (слияние патчем удалять не умеет).
static func _erase_local(cfg: String, path: Array, dir: String) -> bool:
	var file := UserSettings.local_dir(dir).path_join(cfg + ".json")
	var data := UserSettings.read_json(file)
	var node: Variant = data
	for i in path.size() - 1:
		node = (node as Dictionary).get(path[i]) if node is Dictionary else null
	if not (node is Dictionary) or not (node as Dictionary).has(path[-1]):
		return true
	(node as Dictionary).erase(path[-1])
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true
