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
	box.add_child(grid)
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
