class_name GraphicsPresets
extends RefCounted
## Пресеты графики (configs/game.json → graphics_presets): каждый — набор правок конфигов,
## которые пишутся в user://configs (как любые настройки пилота) и подхватываются Config.
## Первый запуск: пресет по видеокарте (graphics_autodetect) — «Низкое» для встроенной графики.


## Имена пресетов в порядке показа.
static func names() -> PackedStringArray:
	var out: PackedStringArray = []
	for k: String in Config.get_config("game").get("graphics_presets", {}):
		if not k.begins_with("_"):
			out.append(k)
	return out


## Текущий пресет ("" — ещё не выбран).
static func current() -> String:
	return String(Config.value("game", "graphics", ""))


## Пресет для видеокарты adapter по эвристике из конфига.
static func detect(adapter: String) -> String:
	var ad: Dictionary = Config.get_config("game").get("graphics_autodetect", {})
	var low := adapter.to_lower()
	for s: String in ad.get("low_if_adapter_contains", []):
		if low.contains(s.to_lower()):
			return "low"
	return String(ad.get("default", "high"))


## Пресет не выбран и автовыбор включён — определить по видеокарте и записать.
## true — что-то записано.
static func ensure_detected(dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var ad: Dictionary = Config.get_config("game").get("graphics_autodetect", {})
	if current() != "" or not bool(ad.get("enabled", false)):
		return false
	var adapter := RenderingServer.get_video_adapter_name()
	var p := detect(adapter)
	print("Графика: видеокарта «%s» → пресет %s" % [adapter, p])
	return select(p, dir)


## Записать пресет в user-конфиги и перечитать Config.
static func select(preset: String, dir: String = UserSettings.DEFAULT_DIR) -> bool:
	var all: Dictionary = Config.get_config("game").get("graphics_presets", {})
	if not all.has(preset):
		push_warning("GraphicsPresets: нет пресета %s" % preset)
		return false
	var p: Dictionary = all[preset]
	var ok := UserSettings.save_patch("game", {"graphics": preset}, dir)
	var cfgs: Dictionary = p.get("configs", {})
	for name: String in cfgs:
		ok = UserSettings.save_patch(name, cfgs[name], dir) and ok
	Config.reload()
	return ok


## Настройки окна текущего пресета: сглаживание и доля разрешения 3D.
static func apply_viewport(vp: Viewport) -> void:
	var all: Dictionary = Config.get_config("game").get("graphics_presets", {})
	var p: Dictionary = all.get(current(), {})
	var v: Dictionary = p.get("viewport", {})
	if v.is_empty():
		return
	var msaa := int(v.get("msaa_3d", 2))
	vp.msaa_3d = (
		Viewport.MSAA_DISABLED
		if msaa <= 0
		else (Viewport.MSAA_2X if msaa <= 2 else Viewport.MSAA_4X)
	)
	vp.scaling_3d_scale = clampf(float(v.get("scale_3d", 1.0)), 0.25, 1.0)
