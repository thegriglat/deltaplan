class_name Vario90sFace
extends Control
## Экран вариометра в стиле 1990-х (обобщённый дизайн, без марок): сегментный LCD
## без подсветки — дуга аналоговой шкалы ±5 м/с из сегментов, в центре цифровой вариометр,
## внизу высота крупно, среднее и время. Погашенные сегменты видны слабой тенью.
## Параметры — configs/instruments.json → vario90s.

var vario: Vario

var _c: Dictionary = {}
var _bg: Color
var _ink: Color
var _ghost: Color
var _digits: Font
var _text: Font
var _lp: int = 20


func setup(c: Dictionary) -> void:
	_c = c
	_bg = Color(String(c.get("lcd_background", "#aeb89a")))
	_ink = Color(String(c.get("lcd_ink", "#1b2016")))
	_ghost = Color(String(c.get("lcd_ghost", "#9fa98c")))
	_lp = int(c.get("label_size_px", 20))
	_digits = _font(String(c.get("digits_font", "")))
	_text = _font(String(c.get("text_font", "")))
	size = Vector2(float(c.get("width_px", 480)), float(c.get("height_px", 360)))


func _draw() -> void:
	if vario == null or _c.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), _bg)
	var w := size.x
	var h := size.y
	var center := Vector2(w * 0.5, h * 0.52)
	var r := minf(w * 0.42, h * 0.46)
	_draw_arc_scale(center, r)
	# Цифровой вариометр в центре дуги.
	var vs := _fmt_vario(vario.vario_ms)
	var vpx := int(h * 0.2)
	_seg_text(Vector2(center.x - r * 0.62, center.y + vpx * 0.2), vs, "8.8", vpx, r * 1.1, true)
	_label(Vector2(center.x + r * 0.5, center.y + vpx * 0.2), "м/с")
	# Низ: высота крупно, среднее и время.
	var alt := "%d" % roundi(vario.altitude_msl_m)
	var apx := int(h * 0.17)
	var base_y := h - 16.0
	_seg_text(Vector2(w * 0.3, base_y), alt, "8888", apx, w * 0.42, true)
	_label(Vector2(w * 0.73, base_y), "м")
	var avg := _fmt_vario(vario.average_ms)
	var spx := int(h * 0.09)
	var side_y := h * 0.72
	_label(Vector2(14.0, side_y), "СР")
	_seg_text(Vector2(8.0, side_y + spx + 6.0), avg, "8.8", spx, w * 0.2, true)
	var t := int(vario.flight_time_s)
	var tm := "%d:%02d" % [t / 3600, (t / 60) % 60]
	_label(Vector2(w - 90.0, side_y), "ВРЕМЯ")
	_seg_text(Vector2(w - 130.0, side_y + spx + 6.0), tm, "8:88", spx, 120.0, true)
	_draw_shade()


## Дуга сегментов: 0 вверху, подъём — вправо (сплошные), снижение — влево (сплошные тоже,
## как у простых LCD), оцифровка через 1 м/с.
func _draw_arc_scale(center: Vector2, r: float) -> void:
	var rng := float(_c.get("range_ms", 5.0))
	var step := float(_c.get("segment_step_ms", 0.25))
	var span := deg_to_rad(float(_c.get("arc_span_deg", 240.0)))
	var n := maxi(int(round(rng / step)), 1)
	var seg_ang := span * 0.5 / float(n)
	var val := clampf(vario.vario_ms, -rng, rng)
	var lit := int(floor(absf(val) / step + 0.5))
	var r0 := r * 0.8
	for side in [1, -1]:
		for i in n:
			var a0 := float(side) * float(i) * seg_ang
			var a1 := float(side) * float(i + 1) * seg_ang
			var on: bool = i < lit and (side > 0 and val > 0.0 or side < 0 and val < 0.0)
			_segment(center, r0, r, a0, a1, _ink if on else _ghost)
	# Оцифровка и риски.
	var every := maxi(int(round(1.0 / step)), 1)
	for k in range(0, n + 1, every):
		for side in [1, -1]:
			if k == 0 and side < 0:
				continue
			var a := float(side) * float(k) * seg_ang
			var dir := Vector2(sin(a), -cos(a))
			draw_line(center + dir * (r + 2.0), center + dir * (r + 10.0), _ink, 2.0)
			var num := str(int(round(k * step)))
			var p := center + dir * (r + 24.0) + Vector2(-20.0, float(_lp) * 0.35)
			draw_string(_text, p, num, HORIZONTAL_ALIGNMENT_CENTER, 40.0, _lp, _ink)
	# Знаки «+» и «−» у концов шкалы.
	var end := span * 0.5
	var plus_p := center + Vector2(sin(end), -cos(end)) * (r * 0.6)
	var minus_p := center + Vector2(sin(-end), -cos(-end)) * (r * 0.6)
	draw_string(
		_text, plus_p + Vector2(-12, 8), "+", HORIZONTAL_ALIGNMENT_CENTER, 24.0, _lp + 8, _ink
	)
	draw_string(
		_text, minus_p + Vector2(-12, 8), "−", HORIZONTAL_ALIGNMENT_CENTER, 24.0, _lp + 8, _ink
	)


## Один сегмент дуги с зазорами (как у настоящего LCD).
func _segment(c: Vector2, r0: float, r1: float, a0: float, a1: float, col: Color) -> void:
	var gap := (a1 - a0) * 0.12
	var b0 := a0 + gap
	var b1 := a1 - gap
	var pts := PackedVector2Array()
	for a in [b0, b1]:
		pts.append(c + Vector2(sin(a), -cos(a)) * r1)
	for a in [b1, b0]:
		pts.append(c + Vector2(sin(a), -cos(a)) * r0)
	draw_colored_polygon(pts, col)


## Семисегментный текст с «погашенными 8» по шаблону (выравнивание вправо в ширину width).
func _seg_text(pos: Vector2, s: String, pattern: String, px: int, width: float, pad: bool) -> void:
	var shown := s
	var ghost := pattern
	if pad:
		# Доводим до ширины шаблона: пустые знакоместа DSEG — '!'.
		var digits := 0
		for ch in s:
			if ch != "." and ch != ":":
				digits += 1
		var need := 0
		for ch in pattern:
			if ch != "." and ch != ":":
				need += 1
		while digits < need:
			shown = "!" + shown
			digits += 1
		ghost = ""
		for ch in shown:
			ghost += ch if ch == "." or ch == ":" else "8"
	draw_string(_digits, pos, ghost, HORIZONTAL_ALIGNMENT_RIGHT, width, px, _ghost)
	draw_string(_digits, pos, shown, HORIZONTAL_ALIGNMENT_RIGHT, width, px, _ink)


func _label(pos: Vector2, s: String) -> void:
	draw_string(_text, pos, tr(s), HORIZONTAL_ALIGNMENT_LEFT, -1, _lp, _ink)


func _fmt_vario(v: float) -> String:
	v = clampf(v, -9.9, 9.9)
	var s := "%.1f" % absf(v)
	return ("-" + s) if v < 0.0 and s != "0.0" else s


func _draw_shade() -> void:
	var a := float(_c.get("lcd_shade_alpha", 0.12))
	if a <= 0.0:
		return
	var band := minf(size.x, size.y) * 0.2
	var dark := Color(0, 0, 0, a)
	var clear := Color(0, 0, 0, 0)
	var w := size.x
	var h := size.y
	draw_polygon(
		PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, band), Vector2(0, band)]),
		[dark, dark, clear, clear]
	)
	draw_polygon(
		PackedVector2Array(
			[Vector2(0, h - band), Vector2(w, h - band), Vector2(w, h), Vector2(0, h)]
		),
		[clear, clear, dark, dark]
	)


func _font(path: String) -> Font:
	if path != "" and ResourceLoader.exists(path):
		var f: Variant = load(path)
		if f is Font:
			return f
	return ThemeDB.fallback_font
