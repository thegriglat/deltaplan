class_name StartMenu
extends Control
## Главное меню (FR-27): фон — фото на весь экран, по центру вертикально — название
## и кнопки действий. Выбор крыла/погоды/старта — отдельный экран «Полёт…» (FlightSetupScreen);
## в полёт — только «Лететь» (под ней — строка с текущим выбором, summary_text).
## Ничего не запускает само — сигналы наверх (главной сцене).

signal fly_requested(settings: FlightSettings)
signal setup_requested
## «Сетевая игра» (NET-50): открыть экран NetScreen.
signal net_requested
signal settings_requested
signal about_requested
signal controls_requested
signal quit_requested
## Переключатель языка «◀ Русский ▶»: выбран язык code (главная сцена включает и перестраивает UI).
signal language_requested(code: String)

var settings: FlightSettings

var _status: Label
var _fly_btn: Button
var _setup_btn: Button
var _summary: Label
var _lang_prev: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if settings == null:
		settings = FlightSettings.defaults()
	_build()


## Выбор для «Лететь»: последний выбор или значения по умолчанию.
func set_settings(s: FlightSettings) -> void:
	settings = s.duplicate()
	if _summary != null:
		_summary.text = summary_text(settings)


## Текст о загрузке или ошибке ("" — спрятать).
func set_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


## Идёт загрузка полёта: «Лететь» и «Полёт…» недоступны.
func set_busy(on: bool) -> void:
	_fly_btn.disabled = on
	_setup_btn.disabled = on


## Выбор двумя строками: «Алтай — Онгудай · <старт>» и «+26 °C · ветер 3 м/с, в лоб старту · 13:00»;
## точка на карте — координатами.
static func summary_text(s: FlightSettings) -> String:
	var parts: PackedStringArray = []
	if s.has_pick():
		parts.append(TranslationServer.translate("menu_point") % [s.pick_lat, s.pick_lon])
	else:
		var loc: Dictionary = Config.get_config("locations/" + s.location_id)
		parts.append(TranslationServer.translate(String(loc.get("name", s.location_id))))
		var starts: Array = loc.get("start_sites", [])
		for st: Dictionary in starts:
			if String(st.get("id", "")) == s.site_id or (s.site_id == "" and st == starts[0]):
				parts.append(TranslationServer.translate(String(st.get("name", st.get("id")))))
				break
	return " · ".join(parts) + "\n" + forecast_text(s) + " · " + SunClock.format_hour(s.start_hour)


## «+26 °C · ветер 3 м/с, в лоб старту» (штиль — «ветер штиль»; облачность, если не ясно).
static func forecast_text(s: FlightSettings) -> String:
	var t := func(k: String) -> String: return TranslationServer.translate(k)
	var ms := roundi(s.wind_speed_kmh / 3.6)
	var wind: String = t.call("setup_wind_calm")
	if ms > 0:
		var dir: String = (
			t.call("setup_wind_into_launch").to_lower()
			if s.wind_into_launch
			else t.call(FlightSetupScreen.COMPASS[posmod(roundi(s.wind_from_deg / 45.0), 8)])
		)
		wind = t.call("menu_summary_wind") % [ms, dir]
	var text: String = t.call("menu_summary_forecast") % [roundi(s.temperature_c), wind]
	if s.sky != "clear":
		text += " · " + String(t.call("setup_sky_" + s.sky)).to_lower()
	return text


func _build() -> void:
	var ui: Dictionary = Config.get_config("ui")
	UiKit.full_screen_background(
		self, String(ui.get("menu_background", "")), Color(0.05, 0.06, 0.08)
	)
	var logo_path := String(ui.get("menu_logo", ""))
	if logo_path != "" and ResourceLoader.exists(logo_path):
		_add_logo(load(logo_path) as Texture2D, float(ui.get("menu_logo_width", 560.0)))
	else:
		UiKit.heading(self, tr("app_title"), 56.0)
	_add_quote(tr("menu_quote"))
	# Полупрозрачная подложка — только под колонкой кнопок, не во весь экран.
	var box := UiKit.snug_panel(self)
	_status = UiKit.label(box, "", "HintLabel")
	_status.visible = false
	_fly_btn = UiKit.menu_button(box, tr("menu_fly"), _on_fly)
	_summary = UiKit.label(box, summary_text(settings), "HintLabel")
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary.autowrap_mode = TextServer.AUTOWRAP_OFF
	_setup_btn = UiKit.menu_button(
		box, tr("menu_flight_setup"), func() -> void: setup_requested.emit()
	)
	UiKit.menu_button(box, tr("menu_net_game"), func() -> void: net_requested.emit())
	UiKit.menu_button(box, tr("menu_controls"), func() -> void: controls_requested.emit())
	UiKit.menu_button(box, tr("menu_settings"), func() -> void: settings_requested.emit())
	UiKit.menu_button(box, tr("menu_about"), func() -> void: about_requested.emit())
	UiKit.menu_button(box, tr("menu_quit"), func() -> void: quit_requested.emit())
	_add_language_selector(box)


## Фокус на переключатель языка (после перестройки UI — чтобы клавиатура осталась на нём).
func focus_language() -> void:
	if _lang_prev != null:
		_lang_prev.grab_focus()


## Строка «◀ Русский ▶» под кнопками: самоназвание текущего языка, стрелки листают список
## (game.json → languages). Нажатие на название — следующий язык.
func _add_language_selector(box: Control) -> void:
	var cur := Language.current()
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(280, 40)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	_lang_prev = _lang_button(row, "◀", Language.neighbour(cur, -1))
	var name_btn := _lang_button(
		row, String(Language.available().get(cur, cur)), Language.neighbour(cur, 1)
	)
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lang_button(row, "▶", Language.neighbour(cur, 1))


func _lang_button(row: Control, text: String, code: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.tooltip_text = String(Language.available().get(code, code))
	b.pressed.connect(func() -> void: language_requested.emit(code))
	row.add_child(b)
	return b


## Лого вместо заголовка: по центру сверху, ширина — ui.json → menu_logo_width (px при 1080p).
func _add_logo(tex: Texture2D, width: float) -> void:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_preset(Control.PRESET_CENTER_TOP)
	var h := width * tex.get_height() / maxf(tex.get_width(), 1.0)
	r.offset_left = -width * 0.5
	r.offset_right = width * 0.5
	r.offset_top = 40.0
	r.offset_bottom = 40.0 + h
	add_child(r)


## Цитата внизу экрана, по центру.
func _add_quote(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	l.offset_top = -90.0
	l.offset_bottom = -40.0
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("shadow_outline_size", 6)
	add_child(l)


func _on_fly() -> void:
	fly_requested.emit(settings)
