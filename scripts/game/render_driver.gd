class_name RenderDriver
extends RefCounted
## Драйвер рендера (CR-К3): текущий, альтернатива по ОС, сохранённый выбор, перезапуск; решение
## «показать окно после обрыва» (стадия wind или отказ GPU) и пометка «ветер упрощён после обрыва».
## Выбор — game.json → display.rendering_driver (auto | vulkan | d3d12 | metal), машинная настройка.
## Движок читает драйвер до старта, поэтому выбор дублируется в файле переопределения проекта
## (application/config/project_settings_override → user://render_driver.cfg), для auto файла нет.
## --rendering-driver в командной строке перекрывает файл (поведение Godot).

## Файл переопределения настроек проекта; путь совпадает с project.godot.
const OVERRIDE_PATH := "user://render_driver.cfg"
## Какой обрыв уже предложено разобрать (ключ обрыва): окно — один раз на обрыв.
const OFFER_PATH := "user://gpu_offer.json"
const WIND_STAGE := "wind"
const ARG := "--rendering-driver"


## Драйвер, на котором идёт этот запуск (vulkan, d3d12, metal, opengl3…).
static func current() -> String:
	return RenderingServer.get_current_rendering_driver_name()


## Варианты выбора для ОС (имя OS.get_name()); auto всегда первым. Linux — только auto.
static func options(os_name: String = OS.get_name()) -> PackedStringArray:
	match os_name:
		"Windows":
			return PackedStringArray(["auto", "vulkan", "d3d12"])
		"macOS":
			return PackedStringArray(["auto", "metal", "vulkan"])
	return PackedStringArray(["auto"])


## Драйвер, на который предлагаем переключиться; "" — альтернативы нет.
## Windows vulkan ↔ d3d12; macOS metal ↔ vulkan.
static func alternative(cur: String = "", os_name: String = OS.get_name()) -> String:
	if cur == "":
		cur = current()
	match os_name:
		"Windows":
			if cur == "vulkan":
				return "d3d12"
			if cur == "d3d12":
				return "vulkan"
		"macOS":
			if cur == "metal":
				return "vulkan"
			if cur == "vulkan":
				return "metal"
	return ""


## Ключ ОС в настройке проекта rendering/rendering_device/driver.<os>.
static func os_key(os_name: String = OS.get_name()) -> String:
	match os_name:
		"Windows":
			return "windows"
		"macOS":
			return "macos"
		"Android":
			return "android"
		"iOS":
			return "ios"
	return "linuxbsd"


## Сохранённый выбор (auto, если не задан).
static func configured() -> String:
	var d: Variant = Config.get_config("game").get("display", {})
	return String((d as Dictionary).get("rendering_driver", "auto")) if d is Dictionary else "auto"


## Содержимое файла переопределения; "" для auto (файла нет).
static func override_text(driver: String, os_name: String = OS.get_name()) -> String:
	if driver == "" or driver == "auto":
		return ""
	return '[rendering]\n\nrendering_device/driver.%s="%s"\n' % [os_key(os_name), driver]


## Записать выбор: game.json → display.rendering_driver и файл переопределения (auto — удалить).
## driver вне options(os_name) — отказ. Действует со следующего запуска.
static func save(
	driver: String,
	dir: String = UserSettings.DEFAULT_DIR,
	override_path: String = OVERRIDE_PATH,
	os_name: String = OS.get_name()
) -> bool:
	if not options(os_name).has(driver):
		push_warning("RenderDriver: драйвер %s недоступен на %s" % [driver, os_name])
		return false
	var ok := UserSettings.save_patch("game", {"display": {"rendering_driver": driver}}, dir)
	var abs_path := ProjectSettings.globalize_path(override_path)
	var text := override_text(driver, os_name)
	if text == "":
		if FileAccess.file_exists(override_path):
			ok = DirAccess.remove_absolute(abs_path) == OK and ok
	else:
		var f := FileAccess.open(override_path, FileAccess.WRITE)
		if f == null:
			push_error("RenderDriver: не записать %s" % override_path)
			return false
		f.store_string(text)
		f.close()
	Config.reload()
	return ok


## Аргументы перезапуска: все аргументы запуска, кроме --rendering-driver (и его значения).
static func restart_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var skip := false
	for a in args:
		if skip:
			skip = false
			continue
		if a == ARG:
			skip = true  # значение — следующий аргумент
			continue
		if a.begins_with(ARG + "="):
			continue
		out.append(a)
	return out


## Перезапустить игру (сохранённый выбор подхватится) и выйти. Нужен узел в дереве.
static func restart(tree: SceneTree) -> void:
	var args := restart_args(OS.get_cmdline_args())
	var user := OS.get_cmdline_user_args()
	if not user.is_empty():
		args.append("--")
		args.append_array(user)
	OS.set_restart_on_exit(true, args)
	tree.quit()


# ---- решение «показать окно» ----


## Ключ обрыва по ожидающему отчёту (разный у каждого обрыва: в теле — время запуска).
static func crash_key(pending: Dictionary) -> String:
	return str(String(pending.get("body", "")).hash())


## Прошлый сеанс оборвался на стадии wind (по телу ожидающего отчёта: «- стадия: wind»).
static func pending_is_wind(pending: Dictionary) -> bool:
	for line in String(pending.get("body", "")).split("\n"):
		if line.begins_with("- стадия: "):
			return line.trim_prefix("- стадия: ").strip_edges() == WIND_STAGE
	return false


## Какой обрыв уже предлагали ("" — никакой).
static func offered_key(path: String = OFFER_PATH) -> String:
	return String(UserSettings.read_json(path).get("key", ""))


static func mark_offered(key: String, path: String = OFFER_PATH) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"key": key}))
		f.close()


## Окно после обрыва на wind нужно: ожидающий отчёт есть, оборван на wind и этот обрыв
## ещё не предлагали. Отметку не ставит (её ставит показ окна).
static func should_offer_after_crash(
	pending: Dictionary, offered: String = offered_key()
) -> bool:
	if pending.is_empty() or not pending_is_wind(pending):
		return false
	return crash_key(pending) != offered


# ---- ветер без GPU после обрыва (CR-К3 v2) ----


## Упрощённый ветер из-за обрыва: enabled=off + off_reason=crash (машинная настройка).
static func set_wind_simple(dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var ok := UserSettings.save_patch(
		"atmosphere", {"air_model": {"enabled": "off", "off_reason": "crash"}}, dir
	)
	Config.reload()
	return ok


## «Вернуть расчёт»: enabled=auto, off_reason удаляется из файла.
static func restore_wind(dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var ok := UserSettings.save_patch("atmosphere", {"air_model": {"enabled": "auto"}}, dir)
	ok = clear_off_reason(dir) and ok
	Config.reload()
	return ok


## Удалить air_model.off_reason из машинного user-конфига (слияние патчем удалять не умеет).
static func clear_off_reason(dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var path := UserSettings.local_dir(dir).path_join("atmosphere.json")
	var data := UserSettings.read_json(path)
	var am: Variant = data.get("air_model")
	if not (am is Dictionary) or not (am as Dictionary).has("off_reason"):
		return true
	(am as Dictionary).erase("off_reason")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true


## Ветер упрощён из-за обрыва (для строки в стартовом меню).
static func wind_off_by_crash() -> bool:
	return (
		String(Config.value("atmosphere", "air_model.enabled", "auto")) == "off"
		and String(Config.value("atmosphere", "air_model.off_reason", "")) == "crash"
	)
