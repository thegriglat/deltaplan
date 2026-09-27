class_name StartMenu
extends Control
## Главное меню (FR-27): фон — фото на весь экран, по центру вертикально — название
## и кнопки действий. Выбор крыла/погоды/старта — отдельный экран «Полёт…» (FlightSetupScreen).
## Ничего не запускает само — сигналы наверх (главной сцене).

signal fly_requested(settings: FlightSettings)
signal setup_requested
signal settings_requested
signal about_requested
signal controls_requested
signal quit_requested

var settings: FlightSettings

var _status: Label
var _fly_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if settings == null:
		settings = FlightSettings.defaults()
	_build()


## Выбор для «Лететь»: последний выбор или значения по умолчанию.
func set_settings(s: FlightSettings) -> void:
	settings = s.duplicate()


## Текст о загрузке или ошибке ("" — спрятать).
func set_status(text: String) -> void:
	_status.text = text
	_status.visible = text != ""


## Идёт загрузка полёта: «Лететь» недоступна.
func set_busy(on: bool) -> void:
	_fly_btn.disabled = on


func _build() -> void:
	var ui: Dictionary = Config.get_config("ui")
	UiKit.full_screen_background(self, String(ui.get("menu_background", "")), Color(0.05, 0.06, 0.08))
	var logo_path := String(ui.get("menu_logo", ""))
	if logo_path != "" and ResourceLoader.exists(logo_path):
		_add_logo(load(logo_path) as Texture2D, float(ui.get("menu_logo_width", 560.0)))
	else:
		UiKit.heading(self, tr("Дельтаплан"), 56.0)
	_add_quote(
		tr("«В этом безмолвном океане неба рождается истинное понимание свободы.»")
	)
	# Полупрозрачная подложка — только под колонкой кнопок, не во весь экран.
	var box := UiKit.snug_panel(self)
	_status = UiKit.label(box, "", "HintLabel")
	_status.visible = false
	_fly_btn = UiKit.menu_button(box, tr("Лететь"), _on_fly)
	UiKit.menu_button(box, tr("Полёт…"), func() -> void: setup_requested.emit())
	UiKit.menu_button(box, tr("Управление"), func() -> void: controls_requested.emit())
	UiKit.menu_button(box, tr("Настройки"), func() -> void: settings_requested.emit())
	UiKit.menu_button(box, tr("Об игре"), func() -> void: about_requested.emit())
	UiKit.menu_button(box, tr("Выход"), func() -> void: quit_requested.emit())


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
