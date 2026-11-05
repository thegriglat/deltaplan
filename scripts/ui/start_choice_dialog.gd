class_name StartChoiceDialog
extends ConfirmationDialog
## Окно выбора старта по «Лететь» (TA-К1): «Дельтаплан» (с буксировкой: нет / виды места) или «Дельталёт».
## Одно окно, без второго вопроса. Не показывается в сети, при быстром старте из избранного, в «Тренировке».

signal chosen(vehicle: String, tow_kind: String)
signal cancelled

var tow_opt: OptionButton  ## «Нет» + виды места
var air_check: CheckBox  ## «В воздухе» (ASM-К3)
var air_height: HSlider  ## высота над стартом, м
var air_start_agl_m: float = -1.0  ## итог: высота старта в воздухе или -1 (с земли); ставится до chosen
var glider_btn: Button
var trike_btn: Button
var cancel_btn: Button
var _tow_ids: PackedStringArray = []  ## виды пунктов tow_opt ("" — «Нет»)
var _done := false


func _init() -> void:
	title = tr("start_choice_title")
	exclusive = true
	min_size = Vector2i(460, 0)
	get_ok_button().hide()  # свои кнопки
	get_cancel_button().hide()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	tow_opt = OptionButton.new()
	tow_opt.name = "TowOption"
	UiKit.row(box, tr("start_choice_tow"), tow_opt)
	air_check = CheckBox.new()
	air_check.name = "AirCheck"
	air_check.text = tr("start_choice_air")
	box.add_child(air_check)
	air_height = UiKit.slider_row(
		box,
		tr("start_choice_air_height"),
		float(Config.value("game", "air_start.agl_min_m", 60.0)),
		float(Config.value("game", "air_start.agl_max_m", 1000.0)),
		float(Config.value("game", "air_start.agl_step_m", 10.0)),
		"%.0f " + tr("unit_m")
	)
	air_height.name = "AirHeight"
	air_check.toggled.connect(_on_air_toggled)
	glider_btn = add_button(tr("start_choice_glider"), false, "glider")
	trike_btn = add_button(tr("start_choice_trike"), false, "trike")
	cancel_btn = add_button(tr("common_cancel"), true, "cancel")
	glider_btn.name = "Glider"
	trike_btn.name = "Trike"
	cancel_btn.name = "Cancel"
	custom_action.connect(_on_action)
	canceled.connect(_finish.bind("cancel"))


func _on_air_toggled(on: bool) -> void:
	tow_opt.disabled = on
	air_height.get_parent().get_parent().visible = on


## Место для окна по настройкам: точка с карты — {}; иначе площадка site_id (нет — первая; нет start_sites — {}).
static func site_for(s: FlightSettings) -> Dictionary:
	if s.has_pick():
		return {}
	var starts: Array = Locations.config(s.location_id).get("start_sites", [])
	for st: Dictionary in starts:
		if String(st.get("id", "")) == s.site_id:
			return st
	return starts[0] if not starts.is_empty() else {}


## Пункты буксировки: id видов ("" — «Нет» первым).
func tow_ids() -> PackedStringArray:
	return _tow_ids


func open(settings: FlightSettings, site: Dictionary) -> void:
	_done = false
	_tow_ids = PackedStringArray([""])
	tow_opt.clear()
	tow_opt.add_item(tr("setup_tow_none"))
	var names := {"winch_static": "setup_tow_winch", "aerotow": "setup_tow_aerotow"}
	var kinds := FlightSetupScreen.tow_kinds_for_site(site)
	for k: String in kinds:
		_tow_ids.append(k)
		tow_opt.add_item(tr(String(names[k])))
	var want := FlightSettings.normalize_tow(settings.tow_kind)
	if want == "" or not (want in kinds):
		want = FlightSetupScreen.default_tow_kind(site)
	tow_opt.select(maxi(_tow_ids.find(want), 0))
	var def := float(Config.value("game", "air_start.agl_default_m", 300.0))
	air_height.value = settings.air_start_agl_m if settings.has_air_start() else def
	air_check.set_pressed_no_signal(settings.has_air_start())
	_on_air_toggled(air_check.button_pressed)
	air_height.value_changed.emit(air_height.value)
	popup_centered()
	(trike_btn if settings.vehicle == "trike" else glider_btn).grab_focus()


func _on_action(action: StringName) -> void:
	_finish(String(action))


func _finish(choice: String) -> void:
	if _done:
		return
	_done = true
	hide()
	air_start_agl_m = -1.0
	match choice:
		"glider":
			if air_check.button_pressed:
				air_start_agl_m = air_height.value
				chosen.emit("glider", "")
				return
			var i := tow_opt.selected
			chosen.emit("glider", _tow_ids[i] if i >= 0 and i < _tow_ids.size() else "")
		"trike":
			chosen.emit("trike", "")
		_:
			cancelled.emit()
