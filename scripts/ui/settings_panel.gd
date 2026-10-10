class_name SettingsPanel
extends Control
## Настройки пилота (FR-23, FR-31, FR-33, NFR-6): имя пилота (net.pilot_name; для сетевой игры,
## NET-51), громкость вариометра, чувствительность мыши,
## инверсия тангажа, режим мыши (обзор / трапеция), скорость времени суток (VR-5),
## поле зрения камеры (camera.json → fov_deg), каска в виде из кабины (helmet.json → mode),
## другие пилоты в небе (bots.json → count; со следующего полёта), имена над ними
## (bots.json → names.show; сразу), густота травы
## (vegetation.json → grass.density_pct; по умолчанию — из пресета графики; со следующей
## загрузки местности), модель ветра (atmosphere.json → air_model.enabled: auto — расчёт по
## рельефу (фазы + Пикар на GPU, air-phase P12), off — эвристика, расчёт не запускается; со следующей загрузки места;
## в сети выбор локальный — у каждого клиента свой).
## Пишутся в user://configs/*.json (UserSettings), Config подхватывает их поверх res://configs.

signal closed(changed: bool)

## Папка для user-конфигов (тесты подменяют).
var config_dir: String = UserSettings.DEFAULT_DIR

var _volume: HSlider
var _sens: HSlider
var _invert: CheckBox
var _roll_mode: OptionButton
var _roll_input: OptionButton
var _sound: OptionButton
var _graphics: OptionButton
var _graphics_names: PackedStringArray = []
var _presets: PackedStringArray = []
var _render_scale_auto: CheckBox
var _render_scale: HSlider
var _vsync: CheckBox
var _fps_limit: OptionButton
var _fps_options: Array = []
var _window_mode: OptionButton
var _resolution: OptionButton
var _resolutions: Array = []
var _time_speed: OptionButton
var _time_speed_row: HBoxContainer
var _speeds: Array = []
## Зона сети (main.gd: game.net != null) — время всегда ×1 (game.gd), строка скрыта и не
## перезаписывается при сохранении.
var _net_mode := false
var _fov: HSlider
var _helmet: OptionButton
var _eye_mode: OptionButton
var _eye_modes: Array = ["back_hidden", "eyes"]
var _helmet_modes: Array = []
var _bots: HSlider
var _names: CheckBox
var _grass: HSlider
var _wind_model: OptionButton
var _language: OptionButton
var _language_codes: Array = []
var _pilot_name: LineEdit
var _motion_on: CheckBox
var _motion_addr: LineEdit
var _motion_rate: HSlider
var _motion_format: OptionButton


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var sp := ScrollPanel.build(self, float(ui.get("panel_width_px", 560)))
	var box: VBoxContainer = sp["box"]
	UiKit.label(box, tr("menu_settings"), "TitleLabel")
	UiKit.separator(box)
	_language = OptionButton.new()
	_language_codes = Language.available().keys()
	for code: Variant in _language_codes:
		_language.add_item(String(Language.available()[code]))
	UiKit.row(box, tr("settings_language"), _language)
	_pilot_name = LineEdit.new()
	_pilot_name.max_length = UserSettings.PILOT_NAME_MAX
	UiKit.row(box, tr("settings_pilot_name"), _pilot_name)
	var vr: Array = ui.get("vario_volume_range_db", [-40.0, 6.0])
	_volume = UiKit.slider_row(
		box, tr("settings_vario_volume"), float(vr[0]), float(vr[1]), 1.0, "%.0f " + tr("unit_db")
	)
	var sr: Array = ui.get("look_sensitivity_range", [0.02, 0.5])
	_sens = UiKit.slider_row(
		box, tr("settings_mouse_sensitivity"), float(sr[0]), float(sr[1]), 0.01, "%.2f °/px"
	)
	_invert = CheckBox.new()
	_invert.text = tr("settings_invert_pitch_hint")
	UiKit.row(box, tr("settings_invert_pitch"), _invert)
	_roll_mode = OptionButton.new()
	_roll_mode.add_item(tr("settings_roll_simple"))
	_roll_mode.add_item(tr("settings_roll_weight_shift"))
	UiKit.row(box, tr("settings_roll_control"), _roll_mode)
	_roll_input = OptionButton.new()
	_roll_input.add_item(tr("settings_roll_input_bar"))
	_roll_input.add_item(tr("settings_roll_input_body"))
	UiKit.row(box, tr("settings_roll_input"), _roll_input)
	# Звук вариометра: пресеты configs/audio.json → vario_audio.presets (если есть).
	var va: Dictionary = Config.get_config("audio").get("vario_audio", {})
	var presets: Variant = va.get("presets", {})
	if presets is Dictionary and not (presets as Dictionary).is_empty():
		_sound = OptionButton.new()
		for k: String in presets:
			if k.begins_with("_") or k.ends_with("_doc"):
				continue
			_presets.append(k)
			var p: Variant = presets[k]
			var title := String(p.get("title", k)) if p is Dictionary else k
			_sound.add_item(tr(title))
		UiKit.row(box, tr("settings_vario_sound"), _sound)
	_graphics = OptionButton.new()
	_graphics_names = GraphicsPresets.names()
	var presets_cfg: Dictionary = Config.get_config("game").get("graphics_presets", {})
	for g in _graphics_names:
		_graphics.add_item(tr(String(presets_cfg[g].get("name", g))))
	UiKit.row(box, tr("settings_graphics"), _graphics)
	var rsr: Array = Config.get_config("game").get("render_scale_range_pct", [50.0, 100.0])
	var rs_box := HBoxContainer.new()
	rs_box.add_theme_constant_override("separation", 10)
	_render_scale_auto = CheckBox.new()
	_render_scale_auto.text = tr("settings_as_in_preset")
	rs_box.add_child(_render_scale_auto)
	_render_scale = HSlider.new()
	_render_scale.min_value = float(rsr[0])
	_render_scale.max_value = float(rsr[1])
	_render_scale.step = float(Config.value("game", "render_scale_step_pct", 5.0))
	_render_scale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_render_scale.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rs_box.add_child(_render_scale)
	var rs_value := Label.new()
	rs_value.custom_minimum_size.x = 60
	rs_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rs_box.add_child(rs_value)
	_render_scale.value_changed.connect(func(x: float) -> void: rs_value.text = "%.0f%%" % x)
	_render_scale_auto.toggled.connect(func(on: bool) -> void: _render_scale.editable = not on)
	UiKit.row(box, tr("settings_render_scale"), rs_box)
	_build_display_rows(box)
	var grass_cfg: Dictionary = Config.get_config("vegetation").get("grass", {})
	var gr: Array = grass_cfg.get("density_range_pct", [0.0, 200.0])
	_grass = UiKit.slider_row(
		box,
		tr("settings_grass_density"),
		float(gr[0]),
		float(gr[1]),
		float(grass_cfg.get("density_step_pct", 10.0)),
		"%.0f%%"
	)
	_graphics.item_selected.connect(_on_graphics_selected)
	_wind_model = OptionButton.new()
	# id: 0 расчёт (auto), 1 эвристика (off)
	_wind_model.add_item(tr("settings_wind_model_calc"), 0)
	_wind_model.add_item(tr("settings_wind_model_simple"), 1)
	UiKit.row(box, tr("settings_wind_model"), _wind_model)
	_time_speed = OptionButton.new()
	_speeds = Config.value("world", "time.speed_options", [1, 10, 60, 0])
	for v: Variant in _speeds:
		_time_speed.add_item(tr("settings_time_stopped") if float(v) <= 0.0 else "×%d" % int(v))
	_time_speed_row = UiKit.row(box, tr("settings_time_speed"), _time_speed)
	var cam: Dictionary = Config.get_config("camera")
	var fr: Array = cam.get("fov_range_deg", [60.0, 110.0])
	_fov = UiKit.slider_row(
		box,
		tr("settings_fov"),
		float(fr[0]),
		float(fr[1]),
		float(cam.get("fov_step_deg", 5.0)),
		"%.0f°"
	)
	_eye_mode = OptionButton.new()
	_eye_mode.add_item(tr("camera_eye_back_hidden"))
	_eye_mode.add_item(tr("camera_eye_eyes"))
	UiKit.row(box, tr("settings_eye_mode"), _eye_mode)
	_helmet = OptionButton.new()
	_helmet_modes = Config.value("helmet", "modes", ["none", "open", "visor", "visor_dark"])
	var helmet_names := {
		"none": tr("helmet_none"),
		"open": tr("helmet_open"),
		"visor": tr("helmet_visor"),
		"visor_dark": tr("helmet_visor_dark"),
	}
	for m: Variant in _helmet_modes:
		_helmet.add_item(String(helmet_names.get(String(m), String(m))))
	UiKit.row(box, tr("settings_helmet"), _helmet)
	var bots_max := float(Config.value("bots", "count_max", 20))
	_bots = UiKit.slider_row(box, tr("settings_bots"), 0.0, bots_max, 1.0, "%.0f")
	_names = CheckBox.new()
	_names.text = tr("settings_pilot_names_hint")
	UiKit.row(box, tr("settings_pilot_names"), _names)
	UiKit.separator(box)
	UiKit.label(box, tr("settings_motion_title"), "HintLabel")
	_motion_on = CheckBox.new()
	_motion_on.text = tr("settings_motion_on_hint")
	UiKit.row(box, tr("settings_motion_on"), _motion_on)
	_motion_addr = LineEdit.new()
	_motion_addr.placeholder_text = "127.0.0.1:33001"
	UiKit.row(box, tr("settings_motion_addr"), _motion_addr)
	_motion_rate = UiKit.slider_row(box, tr("settings_motion_rate"), 10.0, 120.0, 5.0, "%.0f " + tr("unit_hz"))
	_motion_format = OptionButton.new()
	_motion_format.add_item(tr("settings_motion_format_srs"))
	_motion_format.add_item(tr("settings_motion_format_generic"))
	UiKit.row(box, tr("settings_motion_format"), _motion_format)
	UiKit.label(box, tr("settings_saved_hint"), "HintLabel")
	var bar := UiKit.button_bar(sp["footer"])
	UiKit.button(bar, tr("common_save"), _on_save)
	UiKit.button(bar, tr("common_cancel"), func() -> void: closed.emit(false))
	visibility_changed.connect(_on_visibility_changed)
	load_values()


## VSync, предел кадров, режим окна, разрешение (game.json → display, машинные настройки).
func _build_display_rows(box: Control) -> void:
	_vsync = CheckBox.new()
	_vsync.text = tr("settings_vsync_hint")
	UiKit.row(box, tr("settings_vsync"), _vsync)
	_fps_limit = OptionButton.new()
	_fps_options = []
	for v: Variant in Config.value("game", "display_fps_options", [30, 60, 120, 144, 0]):
		_fps_options.append(int(v))  # JSON даёт float — для find() нужны int
		_fps_limit.add_item(tr("settings_fps_unlimited") if int(v) <= 0 else "%d" % int(v))
	UiKit.row(box, tr("settings_fps_limit"), _fps_limit)
	_window_mode = OptionButton.new()
	_window_mode.add_item(tr("settings_window_windowed"), 0)
	_window_mode.add_item(tr("settings_window_fullscreen"), 1)
	UiKit.row(box, tr("settings_window_mode"), _window_mode)
	_resolution = OptionButton.new()
	_resolution.add_item(tr("settings_resolution_current"))
	_resolutions = [Vector2i.ZERO]
	var scr := DisplayServer.screen_get_size()
	for r: Variant in Config.value("game", "display_resolutions", []):
		var v := Vector2i(int((r as Array)[0]), int((r as Array)[1]))
		if scr == Vector2i.ZERO or (v.x <= scr.x and v.y <= scr.y):
			_resolutions.append(v)
			_resolution.add_item("%d × %d" % [v.x, v.y])
	UiKit.row(box, tr("settings_resolution"), _resolution)
	_window_mode.item_selected.connect(func(i: int) -> void: _resolution.disabled = i == 1)


## Зона сети (NET-40/К3): скорость времени не настраивается (game.gd держит ×1) — строка
## скрыта, save() значение не трогает. Вызывать перед открытием панели (main.gd).
func set_net_mode(on: bool) -> void:
	_net_mode = on
	if _time_speed_row != null:
		_time_speed_row.visible = not on


## Показать текущие значения из Config.
func load_values() -> void:
	_language.select(maxi(_language_codes.find(Language.current()), 0))
	var saved_name := String(Config.value("game", "net.pilot_name", ""))
	_pilot_name.text = UserSettings.sanitize_pilot_name(saved_name)
	_pilot_name.placeholder_text = UserSettings.default_pilot_name()
	var va: Dictionary = Config.get_config("audio").get("vario_audio", {})
	_volume.value = float(va.get("volume_db", -6.0))
	_volume.value_changed.emit(_volume.value)
	_sens.value = float(Config.value("controls", "mouse.look_sensitivity_deg_per_px"))
	_sens.value_changed.emit(_sens.value)
	_invert.button_pressed = bool(Config.value("controls", "invert_pitch"))
	var rm := String(Config.value("controls", "roll_control_mode", "rate"))
	_roll_mode.select(1 if rm == "weight_shift" else 0)
	_roll_input.select(1 if String(Config.value("controls", "roll_input", "body")) == "body" else 0)
	_graphics.select(maxi(_graphics_names.find(GraphicsPresets.current()), 0))
	_render_scale_auto.button_pressed = bool(Config.value("game", "render_scale_auto", true))
	_render_scale.value = float(Config.value("game", "render_scale_pct", 100.0))
	_render_scale.value_changed.emit(_render_scale.value)
	_render_scale.editable = not _render_scale_auto.button_pressed
	_vsync.button_pressed = bool(Config.value("game", "display.vsync", true))
	var fps := int(Config.value("game", "display.max_fps", 144))
	var fi := _fps_options.find(fps)
	_fps_limit.select(fi if fi >= 0 else _fps_options.find(0))
	var fs := String(Config.value("game", "display.window_mode", "windowed")) == "fullscreen"
	_window_mode.select(1 if fs else 0)
	_resolution.disabled = fs
	var ws: Array = Config.value("game", "display.window_size", [0, 0])
	_resolution.select(maxi(_resolutions.find(Vector2i(int(ws[0]), int(ws[1]))), 0))
	_grass.value = float(Config.value("vegetation", "grass.density_pct", 100.0))
	_grass.value_changed.emit(_grass.value)
	var wm := String(Config.value("atmosphere", "air_model.enabled", "auto"))
	_wind_model.select(_wind_model.get_item_index(1 if wm == "off" else 0))
	var sp := float(Config.value("world", "time.speed", 1.0))
	var si := 0
	for i in _speeds.size():
		if is_equal_approx(float(_speeds[i]), sp):
			si = i
	_time_speed.select(si)
	_fov.value = float(Config.value("camera", "fov_deg", 60.0))
	_fov.value_changed.emit(_fov.value)
	var em := String(Config.value("camera", "cockpit.eye_mode", "back_hidden"))
	_eye_mode.select(maxi(_eye_modes.find(em), 0))
	var hm := String(Config.value("helmet", "mode", "none"))
	_helmet.select(maxi(_helmet_modes.find(hm), 0))
	_bots.value = float(Config.value("bots", "count", 4))
	_bots.value_changed.emit(_bots.value)
	_names.button_pressed = bool(Config.value("bots", "names.show", true))
	_motion_on.button_pressed = bool(Config.value("motion_rig", "enabled", false))
	_motion_addr.text = "%s:%d" % [
		String(Config.value("motion_rig", "host", "127.0.0.1")), int(Config.value("motion_rig", "port", 33001))
	]
	_motion_rate.value = float(Config.value("motion_rig", "rate_hz", 60))
	_motion_rate.value_changed.emit(_motion_rate.value)
	_motion_format.select(1 if String(Config.value("motion_rig", "format", "srs")) == "generic" else 0)
	if _sound != null:
		var cur := String(va.get("preset", ""))
		_sound.select(maxi(_presets.find(cur), 0))


## Записать и применить. Возвращает true, если всё записалось.
func save() -> bool:
	var ok_name := UserSettings.save_pilot_name(_pilot_name.text, config_dir)
	var va := {"volume_db": _volume.value}
	if _sound != null and _sound.selected >= 0:
		va["preset"] = _presets[_sound.selected]
	var ok := UserSettings.save_patch("audio", {"vario_audio": va}, config_dir) and ok_name
	ok = (
		(
			UserSettings
			. save_patch(
				"controls",
				{
					"invert_pitch": _invert.button_pressed,
					"roll_control_mode": "weight_shift" if _roll_mode.selected == 1 else "rate",
					"roll_input": "body" if _roll_input.selected == 1 else "bar",
					"mouse": {"look_sensitivity_deg_per_px": _sens.value},
				},
				config_dir
			)
		)
		and ok
	)
	if not _net_mode and _time_speed.selected >= 0:
		var tp := {"time": {"speed": float(_speeds[_time_speed.selected])}}
		ok = UserSettings.save_patch("world", tp, config_dir) and ok
	var cam_patch := {
		"fov_deg": _fov.value,
		"cockpit": {"eye_mode": String(_eye_modes[maxi(_eye_mode.selected, 0)])},
	}
	ok = UserSettings.save_patch("camera", cam_patch, config_dir) and ok
	if _helmet.selected >= 0:
		var hp := {"mode": String(_helmet_modes[_helmet.selected])}
		ok = UserSettings.save_patch("helmet", hp, config_dir) and ok
	ok = (
		UserSettings.save_patch(
			"game",
			{
				"render_scale_auto": _render_scale_auto.button_pressed,
				"render_scale_pct": _render_scale.value,
			},
			config_dir
		)
		and ok
	)
	var size: Vector2i = _resolutions[maxi(_resolution.selected, 0)]
	var dp := {
		"display":
		{
			"vsync": _vsync.button_pressed,
			"max_fps": int(_fps_options[maxi(_fps_limit.selected, 0)]),
			"window_mode": "fullscreen" if _window_mode.selected == 1 else "windowed",
			"window_size": [size.x, size.y],
		}
	}
	ok = UserSettings.save_patch("game", dp, config_dir) and ok
	var bp := {"count": int(_bots.value), "names": {"show": _names.button_pressed}}
	ok = UserSettings.save_patch("bots", bp, config_dir) and ok
	if _language.selected >= 0:
		var code := String(_language_codes[_language.selected])
		if code != Language.current():
			ok = Language.select(code, config_dir) and ok
	Config.reload()
	var g := _graphics_names[_graphics.selected] if _graphics.selected >= 0 else ""
	if g != "" and g != GraphicsPresets.current():
		ok = GraphicsPresets.select(g, config_dir) and ok
	# густота травы — после пресета (он пишет свою; слайдер при выборе пресета уже показал её)
	var gp := {"grass": {"density_pct": _grass.value}}
	ok = UserSettings.save_patch("vegetation", gp, config_dir) and ok
	# модель ветра: «расчёт» = auto (как по умолчанию), «упрощённый» = off; со следующей загрузки места
	var wp := {
		"air_model":
		{
			"enabled": "off" if _wind_model.get_selected_id() == 1 else "auto",
		}
	}
	ok = UserSettings.save_patch("atmosphere", wp, config_dir) and ok
	ok = _save_motion() and ok
	Config.reload()
	GraphicsPresets.apply_display(true)
	return ok


## «host:port» → {host, port}; пусто, если адрес неверный (тогда вывод выключен).
static func parse_motion_address(text: String) -> Dictionary:
	var t := text.strip_edges()
	var at := t.rfind(":")
	if at <= 0 or at == t.length() - 1:
		return {}
	var port_text := t.substr(at + 1)
	if not port_text.is_valid_int():
		return {}
	var port := int(port_text)
	var host := t.substr(0, at).strip_edges()
	if host.is_empty() or port < 1 or port > 65535:
		return {}
	return {"host": host, "port": port}


## Вывод движения (MR-К3): неверный адрес — вывод выключен, прежний адрес остаётся. Применяется сразу
## (Config.reload → Game.motion.configure).
func _save_motion() -> bool:
	var addr := parse_motion_address(_motion_addr.text)
	var patch := {
		"enabled": _motion_on.button_pressed and not addr.is_empty(),
		"rate_hz": int(_motion_rate.value),
		"format": "generic" if _motion_format.selected == 1 else "srs",
	}
	if not addr.is_empty():
		patch["host"] = addr.host
		patch["port"] = addr.port
	return UserSettings.save_patch("motion_rig", patch, config_dir)


## Выбран другой пресет графики — слайдер «Густота травы» показывает густоту этого пресета.
func _on_graphics_selected(i: int) -> void:
	var all: Dictionary = Config.get_config("game").get("graphics_presets", {})
	if i < 0 or i >= _graphics_names.size():
		return
	var p: Dictionary = all.get(_graphics_names[i], {})
	var v: Variant = p.get("configs", {}).get("vegetation", {}).get("grass", {}).get("density_pct")
	if v != null:
		_grass.value = float(v)


func _on_visibility_changed() -> void:
	if visible:
		load_values()


func _on_save() -> void:
	save()
	closed.emit(true)
