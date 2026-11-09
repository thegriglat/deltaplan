class_name ControlsScreen
extends Control
## «Управление»: какие клавиши что делают — простыми словами (configs/ui.json → controls_help),
## сами клавиши — из configs/controls.json (если пилот их поменял, экран это покажет).

signal closed


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var box := UiKit.centered_panel(self, 760)
	UiKit.label(box, tr("menu_controls"), "TitleLabel")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 6)
	# Строк много (в т. ч. свободная камера) — список прокручивается, «Назад» всегда на виду.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = clampf(get_viewport_rect().size.y * 0.68, 300.0, 900.0)
	box.add_child(scroll)
	scroll.add_child(grid)
	for row in rows():
		if row.has("section"):
			var h := UiKit.label(grid, String(row.section), "HeaderLabel")
			h.autowrap_mode = TextServer.AUTOWRAP_OFF
			grid.add_child(Control.new())
			continue
		var k := UiKit.label(grid, String(row.keys))
		k.autowrap_mode = TextServer.AUTOWRAP_OFF
		k.custom_minimum_size.x = 150
		var t := UiKit.label(grid, String(row.text))
		t.custom_minimum_size.x = 520
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("common_back"), func() -> void: closed.emit())


## Строки экрана: {section} или {keys, text} — уже переведённые, клавиши по-русски.
static func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var keys: Dictionary = Config.get_config("controls").get("keys", {})
	for r: Dictionary in Config.get_config("ui").get("controls_help", []):
		if r.has("section"):
			out.append({"section": TranslationServer.translate(String(r.section))})
			continue
		var k: String = (
			TranslationServer.translate("settings_mouse") if bool(r.get("mouse", false)) else ""
		)
		if r.has("action"):
			k = key_names(keys.get(String(r.action), []))
		out.append({"keys": k, "text": TranslationServer.translate(String(r.text))})
	return out


## Подсказка на старте (Q-08), левая часть: клавиши разбега и шага — из controls.json.
static func start_hint_keys_text() -> String:
	var k: Dictionary = Config.get_config("controls").get("keys", {})
	# нос и крен крыла — мышью (У1 v5: клавиш трапеции нет)
	return (
		TranslationServer.translate("start_hint_keys")
		% [key_names(k.get("run", [])), key_names(k.get("walk_forward", []))]
	)


## Строка ветра у старта (WF-К2 v2). wind = Vector2(скорость на 10 м, м/с; откуда дует, °); скорость NAN — поле
## ещё считается. Ветер меню — прогноз (forecast_ms), у старта — результат расчёта поля.
static func start_hint_wind_text(wind: Vector2, forecast_ms: float) -> String:
	if is_nan(wind.x):
		return TranslationServer.translate("start_hint_wind_pending")
	if is_nan(wind.y):
		return TranslationServer.translate("start_hint_wind_calm") % [wind.x, forecast_ms]
	var keys: PackedStringArray = [
		"compass_n", "compass_ne", "compass_e", "compass_se", "compass_s", "compass_sw", "compass_w", "compass_nw"
	]
	var dir := TranslationServer.translate(keys[roundi(wind.y / 45.0) % 8])
	return TranslationServer.translate("start_hint_wind") % [wind.x, dir, forecast_ms]


## Правая часть: мышь.
static func start_hint_mouse_text() -> String:
	var k: Dictionary = Config.get_config("controls").get("keys", {})
	return TranslationServer.translate("start_hint_mouse") % key_names(k.get("mouse_capture", []))


## ["W", "Up"] → "W / ↑".
static func key_names(list: Array) -> String:
	var nice := {
		"Up": "↑",
		"Down": "↓",
		"Left": "←",
		"Right": "→",
		"Escape": "Esc",
		"Shift": "Shift",
		"Equal": "=",
	}
	var parts: PackedStringArray = []
	for k: String in list:
		parts.append(String(nice.get(k, k)))
	return " / ".join(parts)
