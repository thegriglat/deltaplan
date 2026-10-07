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


## Настройки окна текущего пресета: сглаживание и масштаб 3D (bilinear или FSR 1, configs/game.json
## → graphics_presets.*.viewport.scaling_mode). Поверх пресета — «Масштаб рендера» из настроек
## (render_scale_auto/render_scale_pct), независимая настройка, тоже через FSR 1.
static func apply_viewport(vp: Viewport) -> void:
	apply_display(false)
	var all: Dictionary = Config.get_config("game").get("graphics_presets", {})
	var p: Dictionary = all.get(current(), {})
	var v: Dictionary = p.get("viewport", {})
	var sharpness := float(v.get("fsr_sharpness", 0.2))
	if not v.is_empty():
		var msaa := int(v.get("msaa_3d", 2))
		vp.msaa_3d = (
			Viewport.MSAA_DISABLED
			if msaa <= 0
			else (Viewport.MSAA_2X if msaa <= 2 else Viewport.MSAA_4X)
		)
		_apply_scaling(
			vp,
			String(v.get("scaling_mode", "bilinear")),
			clampf(float(v.get("scale_3d", 1.0)), 0.25, 1.0),
			sharpness
		)
	if not bool(Config.value("game", "render_scale_auto", true)):
		var pct := clampf(float(Config.value("game", "render_scale_pct", 100.0)), 50.0, 100.0)
		if pct >= 100.0:
			_apply_scaling(vp, "bilinear", 1.0, sharpness)
		else:
			_apply_scaling(vp, "fsr", pct / 100.0, sharpness)


## Режим и масштаб 3D окна: "fsr" — FSR 1 (Viewport.SCALING_3D_MODE_FSR), иначе — bilinear.
static func _apply_scaling(vp: Viewport, mode: String, scale: float, sharpness: float) -> void:
	vp.scaling_3d_mode = (
		Viewport.SCALING_3D_MODE_FSR if mode == "fsr" else Viewport.SCALING_3D_MODE_BILINEAR
	)
	vp.scaling_3d_scale = scale
	vp.fsr_sharpness = sharpness


## Аргументы Godot, задающие режим/размер окна на этот запуск (перекрывают сохранённое).
const WINDOW_ARGS: PackedStringArray = ["--resolution", "--fullscreen", "-f", "--windowed", "-w"]


static func cmdline_overrides_window() -> bool:
	for a in OS.get_cmdline_args():
		if a in WINDOW_ARGS:
			return true
	return false


## VSync, предел кадров, режим и размер окна из game.json → display (машинные настройки).
## force=false — при запуске: режим/размер не трогаем, если их задали в командной строке.
static func apply_display(force: bool = true) -> void:
	var d: Dictionary = Config.get_config("game").get("display", {})
	Engine.max_fps = maxi(0, int(d.get("max_fps", 144)))
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if bool(d.get("vsync", true)) else DisplayServer.VSYNC_DISABLED
	)
	if DisplayServer.get_name() == "headless" or (not force and cmdline_overrides_window()):
		return
	var fullscreen := String(d.get("window_mode", "windowed")) == "fullscreen"
	var mode := DisplayServer.window_get_mode()
	var is_fs := (
		mode == DisplayServer.WINDOW_MODE_FULLSCREEN
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	)
	if fullscreen:
		if not is_fs:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var sz: Array = d.get("window_size", [0, 0])
	if sz.size() >= 2 and int(sz[0]) > 0 and int(sz[1]) > 0:
		var want := Vector2i(int(sz[0]), int(sz[1]))
		if DisplayServer.window_get_size() != want:
			DisplayServer.window_set_size(want)
			var scr := DisplayServer.window_get_current_screen()
			var origin := DisplayServer.screen_get_position(scr)
			DisplayServer.window_set_position(
				origin + (DisplayServer.screen_get_size(scr) - want) / 2
			)
