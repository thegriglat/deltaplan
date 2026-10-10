class_name ControlBarSettings
extends VBoxContainer
## Раздел «Трапеция / джойстик» вкладки «Управление» (CB-2): устройство, оси, инверсии,
## мёртвая зона, экспонента, калибровка (нейтраль / края / сброс), индикатор.
## Пишет gamepad.* (CB-К1) через patch(); сохраняет общая кнопка «Сохранить» панели.

## Источники для тестов: devices_fn() -> [{id, guid, name}], raw_fn(axis: int) -> float (для выбранного устройства).
var devices_fn: Callable = BarAxis.devices
var raw_fn: Callable = _live_raw

var _devices: Array = []
var _device: OptionButton
var _guid := ""
var _name := ""
var _roll_axis: SpinBox
var _pitch_axis: SpinBox
var _inv_roll: CheckBox
var _inv_pitch: CheckBox
var _deadzone: HSlider
var _expo: HSlider
var _range_btn: Button
var _cal := {"roll": [-1.0, 0.0, 1.0], "pitch": [-1.0, 0.0, 1.0]}
var _recording := false
var _rec := {}
var _raw_label: Label
var _bar_roll: ProgressBar
var _bar_pitch: ProgressBar
var _gp_base: Dictionary = {}  ## текущий gamepad из Config (чувствительность и пр.)


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	UiKit.separator(self)
	UiKit.label(self, tr("settings_bar_title"), "HintLabel")
	_device = OptionButton.new()
	_device.item_selected.connect(_on_device_selected)
	UiKit.row(self, tr("settings_bar_device"), _device)
	_roll_axis = _axis_spin()
	UiKit.row(self, tr("settings_bar_roll_axis"), _roll_axis)
	_pitch_axis = _axis_spin()
	UiKit.row(self, tr("settings_bar_pitch_axis"), _pitch_axis)
	_inv_roll = CheckBox.new()
	UiKit.row(self, tr("settings_bar_invert_roll"), _inv_roll)
	_inv_pitch = CheckBox.new()
	UiKit.row(self, tr("settings_bar_invert_pitch"), _inv_pitch)
	_deadzone = UiKit.slider_row(self, tr("settings_bar_deadzone"), 0.0, 0.5, 0.01, "%.2f")
	_expo = UiKit.slider_row(self, tr("settings_bar_expo"), 0.0, 1.0, 0.05, "%.2f")
	var bar := UiKit.button_bar(self)
	UiKit.button(bar, tr("settings_bar_neutral"), set_neutral)
	_range_btn = UiKit.button(bar, tr("settings_bar_range"), toggle_range)
	UiKit.button(bar, tr("settings_bar_reset"), reset_calibration)
	_raw_label = UiKit.label(self, "")
	_bar_roll = _indicator_bar()
	UiKit.row(self, tr("settings_bar_roll"), _bar_roll)
	_bar_pitch = _indicator_bar()
	UiKit.row(self, tr("settings_bar_pitch"), _bar_pitch)
	load_values()


func _axis_spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = 0
	s.max_value = 7
	s.step = 1
	return s


func _indicator_bar() -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = -1.0
	b.max_value = 1.0
	b.step = 0.001
	b.show_percentage = false
	b.custom_minimum_size.y = 14
	return b


## Показать gamepad из Config.
func load_values() -> void:
	if _device == null:
		return
	_gp_base = Config.get_config("controls").get("gamepad", {})
	_guid = String(_gp_base.get("device_guid", ""))
	_name = String(_gp_base.get("device_name", ""))
	_roll_axis.value = int(_gp_base.get("roll_axis", 0))
	_pitch_axis.value = int(_gp_base.get("pitch_axis", 1))
	_inv_roll.button_pressed = bool(_gp_base.get("invert_roll", false))
	_inv_pitch.button_pressed = bool(_gp_base.get("invert_pitch", false))
	_deadzone.value = float(_gp_base.get("deadzone", 0.08))
	_deadzone.value_changed.emit(_deadzone.value)
	_expo.value = float(_gp_base.get("expo", 0.3))
	_expo.value_changed.emit(_expo.value)
	for ax in ["roll", "pitch"]:
		_cal[ax] = BarAxis.cal_of(_gp_base, ax).duplicate()
	_recording = false
	_range_btn.text = tr("settings_bar_range")
	refresh_devices()


## Список устройств: «Первое подключённое», подключённые, при необходимости «не подключено: …».
func refresh_devices() -> void:
	_devices = devices_fn.call()
	_device.clear()
	_device.add_item(tr("settings_bar_device_first"))
	var sel := 0
	for d: Dictionary in _devices:
		_device.add_item(String(d.name))
		if _guid != "" and sel == 0 and String(d.guid) == _guid:
			sel = _device.item_count - 1
	if _guid != "" and sel == 0:
		_device.add_item(tr("settings_bar_device_missing") % _name)
		sel = _device.item_count - 1
	_device.select(sel)


func _on_device_selected(i: int) -> void:
	if i == 0:
		_guid = ""
		_name = ""
	elif i <= _devices.size():
		_guid = String(_devices[i - 1].guid)
		_name = String(_devices[i - 1].name)


func _axes() -> Dictionary:
	return {"roll": int(_roll_axis.value), "pitch": int(_pitch_axis.value)}


## Нейтраль: текущие сырые значения осей → center (min/max раздвигаются при необходимости).
func set_neutral() -> void:
	var ax := _axes()
	for k: String in ax:
		var c := float(raw_fn.call(ax[k]))
		var a: Array = _cal[k]
		_cal[k] = [minf(float(a[0]), c - 0.01), c, maxf(float(a[2]), c + 0.01)]


## Края: первое нажатие — начать запись min/max, второе — стоп и применить.
func toggle_range() -> void:
	if not _recording:
		_recording = true
		_rec = {}
		for k: String in _axes():
			var c := float(raw_fn.call(_axes()[k]))
			_rec[k] = [c, c]
		_range_btn.text = tr("settings_bar_range_stop")
		return
	_recording = false
	_range_btn.text = tr("settings_bar_range")
	for k: String in _rec:
		var a: Array = _cal[k]
		var c := float(a[1])
		var lo := float(a[0])
		var hi := float(a[2])
		if c - float(_rec[k][0]) > 0.05:
			lo = float(_rec[k][0])
		if float(_rec[k][1]) - c > 0.05:
			hi = float(_rec[k][1])
		_cal[k] = [lo, c, hi]


func reset_calibration() -> void:
	_recording = false
	_range_btn.text = tr("settings_bar_range")
	_cal = {"roll": [-1.0, 0.0, 1.0], "pitch": [-1.0, 0.0, 1.0]}


## Текущий gamepad-патч (CB-К1) — для UserSettings.save_patch("controls", {"gamepad": …}).
func patch() -> Dictionary:
	return {
		"device_guid": _guid,
		"device_name": _name,
		"roll_axis": int(_roll_axis.value),
		"pitch_axis": int(_pitch_axis.value),
		"invert_roll": _inv_roll.button_pressed,
		"invert_pitch": _inv_pitch.button_pressed,
		"deadzone": _deadzone.value,
		"expo": _expo.value,
		"calibration": _cal.duplicate(true),
	}


func _gp_now() -> Dictionary:
	var gp := _gp_base.duplicate()
	gp["deadzone"] = _deadzone.value
	gp["expo"] = _expo.value
	return gp


func _process(_dt: float) -> void:
	if _raw_label == null or not is_visible_in_tree():
		return
	update_indicator()


## Сырые значения осей и итог BarAxis.axis_value (как в полёте); при записи краёв — копит min/max.
func update_indicator() -> void:
	var ax := _axes()
	var rr := float(raw_fn.call(ax.roll))
	var rp := float(raw_fn.call(ax.pitch))
	if _recording:
		for k in ["roll", "pitch"]:
			var v := rr if k == "roll" else rp
			_rec[k] = [minf(float(_rec[k][0]), v), maxf(float(_rec[k][1]), v)]
	var gp := _gp_now()
	var vr := BarAxis.axis_value(rr, _cal.roll, _inv_roll.button_pressed, gp)
	var vp := BarAxis.axis_value(rp, _cal.pitch, _inv_pitch.button_pressed, gp)
	_raw_label.text = tr("settings_bar_raw") % [rr, rp]
	_bar_roll.value = vr
	_bar_pitch.value = vp


func _live_raw(axis: int) -> float:
	var dev := BarAxis.pick_device(_guid, devices_fn.call())
	return Input.get_joy_axis(dev, axis) if dev >= 0 else 0.0
