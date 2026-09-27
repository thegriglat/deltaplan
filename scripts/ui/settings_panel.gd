class_name SettingsPanel
extends Control
## Настройки пилота (FR-23, FR-31, FR-33, NFR-6): громкость вариометра, чувствительность мыши,
## инверсия тангажа, режим мыши (обзор / трапеция), скорость времени суток (VR-5).
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
var _time_speed: OptionButton
var _speeds: Array = []


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
	_time_speed = OptionButton.new()
	_speeds = Config.value("world", "time.speed_options", [1, 10, 60, 0])
	for v: Variant in _speeds:
		_time_speed.add_item(tr("стоп") if float(v) <= 0.0 else "×%d" % int(v))
	UiKit.row(box, tr("Скорость времени"), _time_speed)
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
	var sp := float(Config.value("world", "time.speed", 1.0))
	var si := 0
	for i in _speeds.size():
		if is_equal_approx(float(_speeds[i]), sp):
			si = i
	_time_speed.select(si)
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
	Config.reload()
	var g := _graphics_names[_graphics.selected] if _graphics.selected >= 0 else ""
	if g != "" and g != GraphicsPresets.current():
		ok = GraphicsPresets.select(g, config_dir) and ok
	return ok


func _on_visibility_changed() -> void:
	if visible:
		load_values()


func _on_save() -> void:
	save()
	closed.emit(true)
