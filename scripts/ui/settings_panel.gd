class_name SettingsPanel
extends Control
## Настройки пилота (FR-23, FR-31, FR-33, NFR-6): громкость вариометра, чувствительность мыши,
## инверсия тангажа, режим мыши (обзор / трапеция), скорость времени суток (VR-5),
## поле зрения камеры (camera.json → fov_deg), каска в виде из кабины (helmet.json → mode),
## другие пилоты в небе (bots.json → count; со следующего полёта), густота травы
## (vegetation.json → grass.density_pct; по умолчанию — из пресета графики; со следующей
## загрузки местности).
## Пишутся в user://configs/*.json (UserSettings), Config подхватывает их поверх res://configs.

signal closed(changed: bool)

## Папка для user-конфигов (тесты подменяют).
var config_dir: String = UserSettings.DEFAULT_DIR

var _volume: HSlider
var _sens: HSlider
var _invert: CheckBox
var _mouse_mode: OptionButton
var _roll_mode: OptionButton
var _sound: OptionButton
var _graphics: OptionButton
var _graphics_names: PackedStringArray = []
var _presets: PackedStringArray = []
var _render_scale_auto: CheckBox
var _render_scale: HSlider
var _time_speed: OptionButton
var _speeds: Array = []
var _fov: HSlider
var _helmet: OptionButton
var _helmet_modes: Array = []
var _bots: HSlider
var _grass: HSlider


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var box := UiKit.centered_panel(self, float(ui.get("panel_width_px", 560)))
	UiKit.label(box, tr("Настройки"), "TitleLabel")
	UiKit.separator(box)
	var vr: Array = ui.get("vario_volume_range_db", [-40.0, 6.0])
	_volume = UiKit.slider_row(
		box, tr("Громкость вариометра"), float(vr[0]), float(vr[1]), 1.0, "%.0f " + tr("дБ")
	)
	var sr: Array = ui.get("look_sensitivity_range", [0.02, 0.5])
	_sens = UiKit.slider_row(
		box, tr("Чувствительность мыши"), float(sr[0]), float(sr[1]), 0.01, "%.2f °/px"
	)
	_invert = CheckBox.new()
	_invert.text = tr("W — от себя, S — на себя")
	UiKit.row(box, tr("Инверсия тангажа"), _invert)
	_mouse_mode = OptionButton.new()
	_mouse_mode.add_item(tr("Обзор (поворот головы)"))
	_mouse_mode.add_item(tr("Трапеция"))
	UiKit.row(box, tr("Мышь"), _mouse_mode)
	_roll_mode = OptionButton.new()
	_roll_mode.add_item(tr("Как раньше"))
	_roll_mode.add_item(tr("Смещение веса (возврат в центр)"))
	UiKit.row(box, tr("Управление креном"), _roll_mode)
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
		UiKit.row(box, tr("Звук вариометра"), _sound)
	_graphics = OptionButton.new()
	_graphics_names = GraphicsPresets.names()
	var presets_cfg: Dictionary = Config.get_config("game").get("graphics_presets", {})
	for g in _graphics_names:
		_graphics.add_item(tr(String(presets_cfg[g].get("name", g))))
	UiKit.row(box, tr("Графика"), _graphics)
	var rsr: Array = Config.get_config("game").get("render_scale_range_pct", [50.0, 100.0])
	var rs_box := HBoxContainer.new()
	rs_box.add_theme_constant_override("separation", 10)
	_render_scale_auto = CheckBox.new()
	_render_scale_auto.text = tr("Как в пресете")
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
	UiKit.row(box, tr("Масштаб рендера"), rs_box)
	var grass_cfg: Dictionary = Config.get_config("vegetation").get("grass", {})
	var gr: Array = grass_cfg.get("density_range_pct", [0.0, 200.0])
	_grass = UiKit.slider_row(
		box,
		tr("Густота травы"),
		float(gr[0]),
		float(gr[1]),
		float(grass_cfg.get("density_step_pct", 10.0)),
		"%.0f%%"
	)
	_graphics.item_selected.connect(_on_graphics_selected)
	_time_speed = OptionButton.new()
	_speeds = Config.value("world", "time.speed_options", [1, 10, 60, 0])
	for v: Variant in _speeds:
		_time_speed.add_item(tr("стоп") if float(v) <= 0.0 else "×%d" % int(v))
	UiKit.row(box, tr("Скорость времени"), _time_speed)
	var cam: Dictionary = Config.get_config("camera")
	var fr: Array = cam.get("fov_range_deg", [60.0, 110.0])
	_fov = UiKit.slider_row(
		box,
		tr("Поле зрения (по вертикали)"),
		float(fr[0]),
		float(fr[1]),
		float(cam.get("fov_step_deg", 5.0)),
		"%.0f°"
	)
	_helmet = OptionButton.new()
	_helmet_modes = Config.value("helmet", "modes", ["none", "open", "visor", "visor_dark"])
	var helmet_names := {
		"none": tr("Без каски"),
		"open": tr("Открытая"),
		"visor": tr("С визором"),
		"visor_dark": tr("С тёмным визором"),
	}
	for m: Variant in _helmet_modes:
		_helmet.add_item(String(helmet_names.get(String(m), String(m))))
	UiKit.row(box, tr("Каска (вид из кабины)"), _helmet)
	var bots_max := float(Config.value("bots", "count_max", 20))
	_bots = UiKit.slider_row(box, tr("Другие пилоты в небе"), 0.0, bots_max, 1.0, "%.0f")
	UiKit.label(box, tr("Настройки сохраняются в профиле пользователя."), "HintLabel")
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("Сохранить"), _on_save)
	UiKit.button(bar, tr("Отмена"), func() -> void: closed.emit(false))
	visibility_changed.connect(_on_visibility_changed)
	load_values()


## Показать текущие значения из Config.
func load_values() -> void:
	var va: Dictionary = Config.get_config("audio").get("vario_audio", {})
	_volume.value = float(va.get("volume_db", -6.0))
	_volume.value_changed.emit(_volume.value)
	_sens.value = float(Config.value("controls", "mouse.look_sensitivity_deg_per_px"))
	_sens.value_changed.emit(_sens.value)
	_invert.button_pressed = bool(Config.value("controls", "invert_pitch"))
	_mouse_mode.select(0 if String(Config.value("controls", "mouse.mode")) == "look" else 1)
	var rm := String(Config.value("controls", "roll_control_mode", "rate"))
	_roll_mode.select(1 if rm == "weight_shift" else 0)
	_graphics.select(maxi(_graphics_names.find(GraphicsPresets.current()), 0))
	_render_scale_auto.button_pressed = bool(Config.value("game", "render_scale_auto", true))
	_render_scale.value = float(Config.value("game", "render_scale_pct", 100.0))
	_render_scale.value_changed.emit(_render_scale.value)
	_render_scale.editable = not _render_scale_auto.button_pressed
	_grass.value = float(Config.value("vegetation", "grass.density_pct", 100.0))
	_grass.value_changed.emit(_grass.value)
	var sp := float(Config.value("world", "time.speed", 1.0))
	var si := 0
	for i in _speeds.size():
		if is_equal_approx(float(_speeds[i]), sp):
			si = i
	_time_speed.select(si)
	_fov.value = float(Config.value("camera", "fov_deg", 60.0))
	_fov.value_changed.emit(_fov.value)
	var hm := String(Config.value("helmet", "mode", "none"))
	_helmet.select(maxi(_helmet_modes.find(hm), 0))
	_bots.value = float(Config.value("bots", "count", 4))
	_bots.value_changed.emit(_bots.value)
	if _sound != null:
		var cur := String(va.get("preset", ""))
		_sound.select(maxi(_presets.find(cur), 0))


## Записать и применить. Возвращает true, если всё записалось.
func save() -> bool:
	var va := {"volume_db": _volume.value}
	if _sound != null and _sound.selected >= 0:
		va["preset"] = _presets[_sound.selected]
	var ok := UserSettings.save_patch("audio", {"vario_audio": va}, config_dir)
	ok = (
		(
			UserSettings
			. save_patch(
				"controls",
				{
					"invert_pitch": _invert.button_pressed,
					"roll_control_mode": "weight_shift" if _roll_mode.selected == 1 else "rate",
					"mouse":
					{
						"look_sensitivity_deg_per_px": _sens.value,
						"mode": "look" if _mouse_mode.selected == 0 else "bar",
					},
				},
				config_dir
			)
		)
		and ok
	)
	if _time_speed.selected >= 0:
		var tp := {"time": {"speed": float(_speeds[_time_speed.selected])}}
		ok = UserSettings.save_patch("world", tp, config_dir) and ok
	ok = UserSettings.save_patch("camera", {"fov_deg": _fov.value}, config_dir) and ok
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
	ok = UserSettings.save_patch("bots", {"count": int(_bots.value)}, config_dir) and ok
	Config.reload()
	var g := _graphics_names[_graphics.selected] if _graphics.selected >= 0 else ""
	if g != "" and g != GraphicsPresets.current():
		ok = GraphicsPresets.select(g, config_dir) and ok
	# густота травы — после пресета (он пишет свою; слайдер при выборе пресета уже показал её)
	var gp := {"grass": {"density_pct": _grass.value}}
	ok = UserSettings.save_patch("vegetation", gp, config_dir) and ok
	Config.reload()
	return ok


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
