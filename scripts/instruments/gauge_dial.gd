class_name GaugeDial
extends Control
## Круглый прибор дельталёта (TP-К4): циферблат со шкалой, зонами и (по флажку) стрелкой.
## Один класс для тахометра и указателя топлива; стрелка 3D-приборов — отдельные узлы TrikeGauges3D.
## Углы — поворот вокруг Z против часовой от «вверх» (как rotation.z узла в 3D).

var v_min := 0.0
var v_max := 1.0
var a_min := 135.0
var a_max := -135.0
var value := 0.0
var show_needle := true
var title := ""
var major_step := 1.0
var minor_step := 0.5
var label_div := 1.0  ## подпись деления = значение / label_div
var end_labels: PackedStringArray = []  ## вместо чисел: подписи концов шкалы («E»/«F»)
var green: Vector2 = Vector2.ZERO  ## зелёная дуга [от, до] в единицах шкалы; нулевая длина — нет
var red: Vector2 = Vector2.ZERO  ## красная дуга [от, до]
var face: Dictionary = {}


## Угол стрелки, градусы: линейно между (v_min → a_min) и (v_max → a_max), вне шкалы — упор.
static func needle_angle_deg(val: float, vmin: float, vmax: float, amin: float, amax: float) -> float:
	if vmax <= vmin:
		return amin
	var t := clampf((val - vmin) / (vmax - vmin), 0.0, 1.0)
	return lerpf(amin, amax, t)


## Шкалы приборов: instruments.json → trike_gauges; числа тахометра и бака — configs/trike_pilot.json (TP-К1),
## если он уже есть, иначе запас из instruments.json.
## Возвращает {rpm: {...}, fuel: {...}, tank_l: float, face: {...}, panel_3d: {...}, hud: {...}}.
static func scales() -> Dictionary:
	var cfg: Dictionary = Config.get_config("instruments").get("trike_gauges", {})
	var rpm: Dictionary = (cfg.get("tachometer", {}) as Dictionary).duplicate()
	var fuel: Dictionary = (cfg.get("fuel", {}) as Dictionary).duplicate()
	var tank := float(fuel.get("tank_l_fallback", 53.0))
	var has_ops := false
	for dir in Config.search_dirs():
		if FileAccess.file_exists(dir.path_join("trike_pilot.json")):
			has_ops = true
	if has_ops:
		var ops: Dictionary = Config.get_config("trike_pilot")
		var tach: Dictionary = ops.get("tachometer", {})
		for k in ["max_rpm", "green_rpm", "red_rpm"]:
			if tach.has(k):
				rpm[k] = tach[k]
		tank = float((ops.get("fuel", {}) as Dictionary).get("tank_l", tank))
	return {
		"rpm": rpm, "fuel": fuel, "tank_l": tank, "face": cfg.get("face", {}),
		"panel_3d": cfg.get("panel_3d", {}), "hud": cfg.get("hud", {}),
	}


## Настроить как тахометр / указатель топлива по scales().
func setup_rpm(sc: Dictionary) -> void:
	var r: Dictionary = sc["rpm"]
	v_min = 0.0
	v_max = float(r.get("max_rpm", 8000))
	a_min = float(r.get("angle_min_deg", 135.0))
	a_max = float(r.get("angle_max_deg", -135.0))
	major_step = float(r.get("major_step_rpm", 1000))
	minor_step = float(r.get("minor_step_rpm", 500))
	label_div = 1000.0
	end_labels = []
	var g: Array = r.get("green_rpm", [2000, 6500])
	green = Vector2(float(g[0]), float(g[1]))
	red = Vector2(float(r.get("red_rpm", 6800)), v_max)
	title = tr("trike_rpm")
	face = sc["face"]


func setup_fuel(sc: Dictionary) -> void:
	var f: Dictionary = sc["fuel"]
	v_min = 0.0
	v_max = float(sc["tank_l"])
	a_min = float(f.get("angle_min_deg", 60.0))
	a_max = float(f.get("angle_max_deg", -60.0))
	major_step = v_max * 0.25
	minor_step = v_max * 0.125
	label_div = 1.0
	end_labels = PackedStringArray([tr("trike_fuel_empty"), tr("trike_fuel_full")])
	green = Vector2.ZERO
	red = Vector2(0.0, v_max * float(f.get("reserve_frac", 0.1)))
	title = tr("trike_fuel")
	face = sc["face"]


func set_value(v: float) -> void:
	value = v
	if show_needle:
		queue_redraw()


static func _dir(a_deg: float) -> Vector2:
	var a := deg_to_rad(a_deg)
	return Vector2(-sin(a), -cos(a))


func _col(key: String, def: String) -> Color:
	return Color(String(face.get(key, def)))


func _arc(c: Vector2, r: float, v0: float, v1: float, col: Color, w: float) -> void:
	var a0 := needle_angle_deg(v0, v_min, v_max, a_min, a_max)
	var a1 := needle_angle_deg(v1, v_min, v_max, a_min, a_max)
	var n := maxi(2, int(absf(a1 - a0) / 4.0))
	var pts := PackedVector2Array()
	for i in n + 1:
		pts.append(c + _dir(lerpf(a0, a1, float(i) / n)) * r)
	draw_polyline(pts, col, w, true)


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s <= 1.0:
		return
	var c := size * 0.5
	var r := s * 0.5
	var ink := _col("ink_color", "#eceff1")
	draw_circle(c, r, _col("face_color", "#15171a"))
	draw_arc(c, r - 1.0, 0.0, TAU, 48, ink, maxf(1.0, s * 0.015), true)
	var aw := maxf(2.0, s * 0.03)
	if green.y > green.x:
		_arc(c, r * 0.80, green.x, green.y, _col("green_color", "#3fb950"), aw)
	if red.y > red.x:
		_arc(c, r * 0.80, red.x, red.y, _col("red_color", "#e5484d"), aw)
	var font := ThemeDB.fallback_font
	var fs := maxi(8, int(s * 0.10))
	var lw := maxf(1.0, s * 0.012)
	if minor_step > 0.0:
		var v := v_min
		while v <= v_max + 0.001:
			draw_line(c + _dir(needle_angle_deg(v, v_min, v_max, a_min, a_max)) * r * 0.88,
				c + _dir(needle_angle_deg(v, v_min, v_max, a_min, a_max)) * r * 0.95, ink, lw)
			v += minor_step
	if major_step > 0.0:
		var v := v_min
		var k := 0
		while v <= v_max + 0.001:
			var d := _dir(needle_angle_deg(v, v_min, v_max, a_min, a_max))
			draw_line(c + d * r * 0.82, c + d * r * 0.95, ink, lw * 2.0)
			var txt := ""
			if end_labels.size() == 2:
				txt = end_labels[0] if is_equal_approx(v, v_min) else (end_labels[1] if v >= v_max - 0.001 else "")
			else:
				txt = "%d" % roundi(v / label_div)
			if not txt.is_empty():
				var ts := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
				draw_string(font, c + d * r * 0.64 - Vector2(ts.x * 0.5, -ts.y * 0.3), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
			v += major_step
			k += 1
	if not title.is_empty():
		var tfs := maxi(7, int(s * 0.075))
		var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs)
		draw_string(font, c + Vector2(-tw.x * 0.5, r * 0.55), title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, ink)
	if show_needle:
		var a := needle_angle_deg(value, v_min, v_max, a_min, a_max)
		var d := _dir(a)
		draw_line(c - d * r * 0.12, c + d * r * 0.78, _col("needle_color", "#ffb020"), maxf(2.0, s * 0.03), true)
		draw_circle(c, s * 0.04, ink)
