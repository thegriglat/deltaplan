class_name RenderDriver
extends RefCounted
## Драйвер рендера (CR-К3): текущий, альтернатива по ОС, сохранённый выбор, перезапуск; решение
## «показать окно после обрыва» (стадия wind, обрыв на старте/в меню, потеря устройства в логе).
## Выбор — game.json → display.rendering_driver (auto | vulkan | d3d12 | metal), машинная настройка.
## Движок читает драйвер до старта, поэтому выбор дублируется в файле переопределения проекта
## (application/config/project_settings_override → user://render_driver.cfg), для auto файла нет.
## --rendering-driver в командной строке перекрывает файл (поведение Godot).

## Файл переопределения настроек проекта; путь совпадает с project.godot.
const OVERRIDE_PATH := "user://render_driver.cfg"
## Какой обрыв уже предложено разобрать (ключ обрыва): окно — один раз на обрыв.
const OFFER_PATH := "user://gpu_offer.json"
const WIND_STAGE := "wind"
const MENU_STAGE := "меню"
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


## Стадия обрыва по телу ожидающего отчёта («- стадия: wind»); "" — строки нет.
static func pending_stage(pending: Dictionary) -> String:
	for line in String(pending.get("body", "")).split("\n"):
		if line.begins_with("- стадия: "):
			return line.trim_prefix("- стадия: ").strip_edges()
	return ""


## Прошлый сеанс оборвался на стадии wind.
static func pending_is_wind(pending: Dictionary) -> bool:
	return pending_stage(pending) == WIND_STAGE


## Обрыв на старте/в меню: стадия загрузки не успела начаться (в отчёте — «меню»).
static func pending_is_menu(pending: Dictionary) -> bool:
	return pending_stage(pending) in ["", MENU_STAGE]


## В хвосте лога прошлого сеанса есть признак потери устройства GPU (CR-К2 v2).
static func pending_has_device_loss(pending: Dictionary) -> bool:
	return GpuLossLogger.summarize(String(pending.get("body", ""))).lost


## Какой обрыв уже предлагали ("" — никакой).
static func offered_key(path: String = OFFER_PATH) -> String:
	return String(UserSettings.read_json(path).get("key", ""))


static func mark_offered(key: String, path: String = OFFER_PATH) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"key": key}))
		f.close()


## Окно после обрыва нужно: ожидающий отчёт есть, оборван на wind, на старте/в меню или в хвосте
## лога потеря устройства, и этот обрыв ещё не предлагали. Отметку не ставит (её ставит показ окна).
static func should_offer_after_crash(
	pending: Dictionary, offered: String = offered_key()
) -> bool:
	if pending.is_empty():
		return false
	if not (pending_is_wind(pending) or pending_is_menu(pending) or pending_has_device_loss(pending)):
		return false
	return crash_key(pending) != offered
