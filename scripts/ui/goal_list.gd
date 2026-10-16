class_name GoalList
extends CanvasLayer
## Список целей полёта (GL-4): компактные строки с галочками в углу экрана. Данные — GoalTracker.items()
## (GL-К3), текст обновляется ≤ configs/goals/hud.json → refresh_hz. Видимость задаёт game.gd
## (set_active): в полёте, есть цели, ввод включён. Без очков и подсказок.

const ICONS := {"pending": "○", "done": "✓", "failed": "✗", "unavailable": "—"}
const ROUTE_KINDS := ["route", "triangle", "return"]

var tracker: GoalTracker
var _cfg: Dictionary = {}
var _active := false
var _since_s := 0.0
var _label: Label
var _lines: PackedStringArray = []


func _ready() -> void:
	layer = 9
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)
	get_viewport().size_changed.connect(_layout)
	reload()


## Перечитать configs/goals/hud.json.
func reload() -> void:
	_cfg = Config.get_config("goals/hud")
	if _label != null:
		_label.add_theme_color_override("font_color", Color(String(_cfg.get("color", "#e8eef2"))))
		_label.add_theme_font_size_override(
			"font_size", maxi(8, roundi(_win().y * float(_cfg.get("font_size_frac", 0.022))))
		)
		_label.modulate.a = float(_cfg.get("opacity", 0.85))
	_apply_visibility()
	refresh()
	_layout()


func set_tracker(t: GoalTracker) -> void:
	tracker = t
	_apply_visibility()
	refresh()


func set_active(on: bool) -> void:
	_active = on
	_apply_visibility()
	refresh()


func is_enabled() -> bool:
	return bool(_cfg.get("enabled", true))


func is_shown() -> bool:
	return _label != null and _label.visible


## Строки сейчас (по целям, в их порядке).
func lines() -> PackedStringArray:
	return _lines


func _process(dt: float) -> void:
	_since_s += dt
	if _since_s >= 1.0 / maxf(float(_cfg.get("refresh_hz", 4.0)), 0.5):
		refresh()


## Пересчитать текст (сразу, вне ритма refresh_hz).
func refresh() -> void:
	_since_s = 0.0
	_lines = rows(tracker.items()) if tracker != null else PackedStringArray()
	if _label != null and _label.visible:
		_label.text = "\n".join(_lines)
		_label.reset_size()
		_layout()


func _apply_visibility() -> void:
	if _label != null:
		_label.visible = _active and is_enabled() and tracker != null and not _lines_empty()


func _lines_empty() -> bool:
	return tracker == null or tracker.items().is_empty()


func _win() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1920, 1080)


func _layout() -> void:
	if _label == null:
		return
	var win := _win()
	var m := float(_cfg.get("margin_px", 18))
	var sz := _label.get_combined_minimum_size()
	_label.size = sz
	if String(_cfg.get("corner", "top_left")) == "top_right":
		_label.position = Vector2(win.x - m - sz.x, m)
	else:
		_label.position = Vector2(m, m)


# --- текст (статика, без нод) ---


static func rows(items: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for it: Variant in items:
		out.append(row_text(it as Dictionary))
	return out


## «○ Набор высоты 100 м · 32 м»: значок, название, цель; пока цель в работе — текущее значение.
static func row_text(item: Dictionary) -> String:
	var kind := String(item.get("kind", ""))
	var status := String(item.get("status", "pending"))
	var s := "%s %s %s" % [ICONS.get(status, "○"), goal_name(item), fmt_value(kind, float(item.get("value", 0.0)))]
	if status == "pending":
		var cur := progress_text(item)
		if cur != "":
			s += " · " + cur
	elif status == "done" or status == "failed":
		var res := progress_text(item)
		if res != "" and kind in ["distance", "height", "landing"]:
			s += " · " + res
	return s


static func goal_name(item: Dictionary) -> String:
	var kind := String(item.get("kind", ""))
	var tn := String(item.get("task_name", ""))
	if kind == "route" and tn != "":
		return tn
	return _t("goals_kind_" + kind)


## Текущее значение для строки; пусто — показывать нечего.
static func progress_text(item: Dictionary) -> String:
	var kind := String(item.get("kind", ""))
	var cur := float(item.get("current", 0.0))
	var best := float(item.get("best", 0.0))
	match kind:
		"height":
			var v := maxf(cur, best)
			return fmt_value(kind, v) if v > 0.5 else ""
		"duration":
			return fmt_value(kind, cur) if cur > 0.5 else ""
		"distance":
			return fmt_value(kind, maxf(cur, best)) if maxf(cur, best) > 1.0 else ""
		"speed":
			return fmt_value(kind, cur) if cur > 0.5 else ""
		"landing":
			return fmt_value(kind, cur) if String(item.get("status", "")) != "pending" else ""
		"route", "triangle", "return":
			var st := String(item.get("status", ""))
			if st == "done" or (cur < 1.0 and st == "pending"):
				return ""  # взят гоул или маршрут не начат
			return _t("goal_list_left") % fmt_value("distance", best)
	return ""


## Число с единицей: метры, километры (дистанции), мин:с (время).
static func fmt_value(kind: String, v: float) -> String:
	match kind:
		"distance", "return", "triangle", "route":
			return "%.1f %s" % [v / 1000.0, _t("unit_km")]
		"duration", "speed":
			return ResultScreen.format_time(v)
	return "%d %s" % [roundi(v), _t("unit_m")]


static func _t(s: String) -> String:
	return TranslationServer.translate(s)
