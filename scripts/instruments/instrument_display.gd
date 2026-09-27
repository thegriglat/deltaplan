class_name InstrumentDisplay
extends Control
## Изображение экрана полётного компьютера (рисуется в SubViewport через _draw).
## Стиль — монохромный транфлективный LCD: серо-зелёный фон, тёмные сегменты,
## бледные «погашенные» сегменты 8 под цифрами. Данные берёт из Vario.
## Страницы: 0 — вариометр и полётные данные, 1 — карта со следом и поворотными пунктами.

const PAGE_MAIN := 0
const PAGE_MAP := 1

var vario: Vario
var page: int = PAGE_MAIN
## Поворотные пункты: [{name: String, position: Vector3, radius_m: float}].
## Термиков тут нет (FR-22).
var turnpoints: Array = []

var _cfg: Dictionary = {}
var _scr: Dictionary = {}
var _scale_cfg: Dictionary = {}
var _units: Dictionary = {}
var _map: Dictionary = {}
var _bg: Color
var _ink: Color
var _ghost: Color
var _digits: Font
var _text: Font
var _label_px: int = 17
var _margin: float = 14.0


func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	_scr = cfg.get("screen", {})
	_scale_cfg = cfg.get("vario_scale", {})
	_units = cfg.get("units", {})
	_map = cfg.get("map", {})
	_bg = Color(String(_scr.get("lcd_background", "#b9c2a4")))
	_ink = Color(String(_scr.get("lcd_ink", "#1c2118")))
	_ghost = Color(String(_scr.get("lcd_ghost", "#a7b092")))
	_label_px = int(_scr.get("label_size_px", 17))
	_margin = float(_scr.get("margin_px", 14))
	_digits = _load_font(String(_scr.get("digits_font", "")))
	_text = _load_font(String(_scr.get("text_font", "")))
	size = Vector2(float(_scr.get("width_px", 480)), float(_scr.get("height_px", 640)))


func _load_font(path: String) -> Font:
	if path != "" and ResourceLoader.exists(path):
		var f: Variant = load(path)
		if f is Font:
			return f
	return ThemeDB.fallback_font


func _draw() -> void:
	if _scr.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), _bg)
	var top := _draw_status_bar()
	if page == PAGE_MAP:
		_draw_map_page(top)
	else:
		_draw_main_page(top)
	_draw_shade()


# ---------- Общие элементы ----------


## Неравномерность подсветки: лёгкое затемнение к краям.
func _draw_shade() -> void:
	var a := float(_scr.get("lcd_shade_alpha", 0.1))
	if a <= 0.0:
		return
	var band := minf(size.x, size.y) * 0.18
	var dark := Color(0, 0, 0, a)
	var clear := Color(0, 0, 0, 0)
	var w := size.x
	var h := size.y
	draw_polygon(
		[Vector2(0, 0), Vector2(w, 0), Vector2(w, band), Vector2(0, band)],
		[dark, dark, clear, clear]
	)
	draw_polygon(
		[Vector2(0, h - band), Vector2(w, h - band), Vector2(w, h), Vector2(0, h)],
		[clear, clear, dark, dark]
	)
	draw_polygon(
		[Vector2(0, 0), Vector2(band, 0), Vector2(band, h), Vector2(0, h)],
		[dark, clear, clear, dark]
	)
	draw_polygon(
		[Vector2(w - band, 0), Vector2(w, 0), Vector2(w, h), Vector2(w - band, h)],
		[clear, dark, dark, clear]
	)


## Верхняя строка: имя страницы, индикатор страниц, время полёта. Возвращает y начала содержимого.
func _draw_status_bar() -> float:
	var h := float(_label_px) + 14.0
	var y := _margin * 0.5 + float(_label_px)
	var name := tr("ВАРИО") if page == PAGE_MAIN else tr("КАРТА")
	draw_string(_text, Vector2(_margin, y), name, HORIZONTAL_ALIGNMENT_LEFT, -1, _label_px, _ink)
	# Точки страниц.
	var pages := int(_scr.get("pages", 2))
	var r := float(_label_px) * 0.28
	var cx := size.x * 0.5 - float(pages - 1) * r * 1.8
	for i in pages:
		var c := Vector2(cx + float(i) * r * 3.6, y - float(_label_px) * 0.35)
		if i == page:
			draw_circle(c, r, _ink)
		else:
			draw_arc(c, r, 0.0, TAU, 16, _ink, 1.5, true)
	var t := vario.flight_time_s if vario else 0.0
	draw_string(
		_text,
		Vector2(size.x - _margin - 200.0, y),
		_fmt_time(t),
		HORIZONTAL_ALIGNMENT_RIGHT,
		200.0,
		_label_px,
		_ink
	)
	draw_line(Vector2(_margin * 0.5, h), Vector2(size.x - _margin * 0.5, h), _ink, 2.0)
	return h + 6.0


## Поле: рамка, подпись слева сверху, единицы справа сверху, значение семисегментными цифрами.
func _draw_field(rect: Rect2, label: String, units: String, value: String, digits_px: int) -> void:
	draw_rect(rect, _ink, false, 1.5)
	var lp := _label_px
	draw_string(
		_text,
		rect.position + Vector2(6, lp + 2),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		rect.size.x * 0.7,
		lp,
		_ink
	)
	if units != "":
		draw_string(
			_text,
			rect.position + Vector2(0, lp + 2),
			units,
			HORIZONTAL_ALIGNMENT_RIGHT,
			rect.size.x - 6,
			lp,
			_ink
		)
	var ghost := _ghost_of(value)
	var base_y := rect.position.y + rect.size.y - (rect.size.y - lp - 4 - digits_px) * 0.5 - 4.0
	var right_w := rect.size.x - 10.0
	var pos := Vector2(rect.position.x + 4.0, base_y)
	draw_string(_digits, pos, ghost, HORIZONTAL_ALIGNMENT_RIGHT, right_w, digits_px, _ghost)
	draw_string(_digits, pos, value, HORIZONTAL_ALIGNMENT_RIGHT, right_w, digits_px, _ink)


## «Погашенные» сегменты: каждая цифра/минус/пробел → 8, точки и двоеточия остаются.
func _ghost_of(s: String) -> String:
	var out := ""
	for ch in s:
		out += ch if ch == "." or ch == ":" else "8"
	return out


## Дополнить слева «пустыми» знакоместами DSEG ('!') до n знаков (точки не считаются).
func _pad(s: String, n: int) -> String:
	var count := 0
	for ch in s:
		if ch != "." and ch != ":":
			count += 1
	while count < n:
		s = "!" + s
		count += 1
	return s


func _fmt_time(t: float) -> String:
	var total := int(t)
	return "%d:%02d:%02d" % [total / 3600, (total / 60) % 60, total % 60]


func _fmt_vario(v: float, slots: int) -> String:
	var lim := float(_units.get("vario_display_limit_ms", 19.9))
	var dec := int(_units.get("vario_decimals", 1))
	v = clampf(v, -lim, lim)
	var s := ("%." + str(dec) + "f") % absf(v)
	if s.to_float() == 0.0:
		return _pad(s, slots)
	return _pad(("-" if v < 0.0 else "") + s, slots)


func _fmt_int(v: float, slots: int) -> String:
	var s := "%d" % roundi(v)
	return _pad(s, slots)


func _speed(v_ms: float) -> float:
	return Units.to_kmh(v_ms)


# ---------- Страница 1: вариометр ----------


func _draw_main_page(top: float) -> void:
	var m := _margin
	var bar_w := float(_scale_cfg.get("width_px", 58))
	var bottom := size.y - m
	_draw_vario_bar(Rect2(m, top, bar_w, bottom - top))
	var x0 := m + bar_w + 12.0
	var w := size.x - m - x0
	var half := (w - 8.0) * 0.5
	var gap := 8.0
	var v := vario
	var y := top
	# Высоты рядов — доли свободной высоты.
	var avail := bottom - top - gap * 5.0
	var rows := [0.215, 0.15, 0.185, 0.15, 0.15, 0.15]
	var hs: Array[float] = []
	for r in rows:
		hs.append(avail * r)
	var big := int(hs[0] * 0.58)
	var mid := int(hs[2] * 0.52)
	var small := int(hs[1] * 0.42)
	# 1. Вариометр.
	_draw_field(Rect2(x0, y, w, hs[0]), tr("ВАРИО"), tr("м/с"), _fmt_vario(v.vario_ms, 3), big)
	y += hs[0] + gap
	# 2. Среднее | качество.
	_draw_field(
		Rect2(x0, y, half, hs[1]), tr("СРЕДНЕЕ"), tr("м/с"), _fmt_vario(v.average_ms, 3), small
	)
	var ld := "--" if v.glide_ratio == INF or v.glide_ratio > 99.0 else ("%.0f" % v.glide_ratio)
	_draw_field(Rect2(x0 + half + gap, y, half, hs[1]), tr("КАЧ"), "", _pad(ld, 2), small)
	y += hs[1] + gap
	# 3. Высота MSL.
	_draw_field(Rect2(x0, y, w, hs[2]), tr("ВЫСОТА"), tr("м"), _fmt_int(v.altitude_msl_m, 5), mid)
	y += hs[2] + gap
	# 4. Над землёй | расстояние от взлёта.
	_draw_field(
		Rect2(x0, y, half, hs[3]),
		tr("НАД ЗЕМЛ"),
		tr("м"),
		_fmt_int(maxf(v.altitude_agl_m, 0.0), 4),
		small
	)
	_draw_field(
		Rect2(x0 + half + gap, y, half, hs[3]),
		tr("РАССТ"),
		tr("км"),
		_pad("%.1f" % (v.distance_from_takeoff_m / 1000.0), 4),
		small
	)
	y += hs[3] + gap
	# 5. Воздушная | путевая.
	_draw_field(
		Rect2(x0, y, half, hs[4]), tr("ВОЗД"), tr("км/ч"), _fmt_int(_speed(v.airspeed_ms), 3), small
	)
	_draw_field(
		Rect2(x0 + half + gap, y, half, hs[4]),
		tr("ПУТЕВ"),
		tr("км/ч"),
		_fmt_int(_speed(v.groundspeed_ms), 3),
		small
	)
	y += hs[4] + gap
	# 6. Курс | путевой угол (стрелка компаса).
	var hdg := fposmod(roundf(v.heading_deg), 360.0)
	_draw_field(Rect2(x0, y, half, hs[5]), tr("КУРС"), "°", _fmt_int(hdg, 3), small)
	_draw_compass(Rect2(x0 + half + gap, y, half, hs[5]), v.track_deg)


## Вертикальный сегментный столбик вариометра ±range с нулём посередине.
func _draw_vario_bar(rect: Rect2) -> void:
	var rng := float(_scale_cfg.get("range_ms", 5.0))
	var step := float(_scale_cfg.get("segment_step_ms", 0.25))
	var n := maxi(int(round(rng / step)), 1)  # сегментов в каждую сторону
	draw_rect(rect, _ink, false, 1.5)
	var inner := rect.grow(-4.0)
	var mid_y := inner.position.y + inner.size.y * 0.5
	var seg_h := inner.size.y * 0.5 / float(n)
	var seg_w := inner.size.x * 0.55
	var val := clampf(vario.vario_ms, -rng, rng)
	var lit := int(floor(absf(val) / step + 0.5))
	for side in [1, -1]:
		for i in n:
			var y_top: float
			if side > 0:
				y_top = mid_y - float(i + 1) * seg_h
			else:
				y_top = mid_y + float(i) * seg_h
			var r := Rect2(inner.position.x, y_top + 1.0, seg_w, seg_h - 2.0)
			var on: bool = (side > 0 and val > 0.0 or side < 0 and val < 0.0) and i < lit
			# Подъём — сплошные сегменты, снижение — полые (как у многих приборов).
			if on and side > 0:
				draw_rect(r, _ink)
			elif on:
				draw_rect(r.grow(-1.0), _ink, false, 3.0)
			else:
				draw_rect(r, _ghost)
	# Нулевая риска и оцифровка каждые 1 м/с.
	draw_line(Vector2(rect.position.x, mid_y), Vector2(rect.end.x, mid_y), _ink, 2.5)
	var lp := int(_label_px * 0.85)
	var every := maxi(int(round(1.0 / step)), 1)
	for k in range(every, n + 1, every):
		for side in [1, -1]:
			var yy: float = mid_y - float(side * k) * seg_h
			var tx := Vector2(inner.position.x + seg_w + 2.0, yy + lp * 0.35)
			draw_string(
				_text,
				tx + Vector2(3, 0),
				str(int(round(k * step))),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				lp,
				_ink
			)
	# Маркер среднего — треугольник справа.
	if bool(_scale_cfg.get("average_marker", true)):
		var ay := mid_y - clampf(vario.average_ms, -rng, rng) / step * seg_h
		var ax := rect.end.x - 1.0
		var s := 9.0
		draw_colored_polygon(
			PackedVector2Array(
				[Vector2(ax, ay - s), Vector2(ax, ay + s), Vector2(ax - s * 1.3, ay)]
			),
			_ink
		)


## Компас: путевой угол стрелкой и буквой ближайшего направления.
func _draw_compass(rect: Rect2, track: float) -> void:
	draw_rect(rect, _ink, false, 1.5)
	draw_string(
		_text,
		rect.position + Vector2(6, _label_px + 2),
		tr("ПУТЬ"),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_label_px,
		_ink
	)
	var r := minf(rect.size.x * 0.3, rect.size.y * 0.36)
	var c := Vector2(rect.end.x - r - 10.0, rect.position.y + rect.size.y * 0.55)
	draw_arc(c, r, 0.0, TAU, 32, _ink, 1.5, true)
	var a := deg_to_rad(track)
	var dir := Vector2(sin(a), -cos(a))
	var perp := Vector2(-dir.y, dir.x)
	draw_colored_polygon(
		PackedVector2Array(
			[
				c + dir * r * 0.9,
				c - dir * r * 0.5 + perp * r * 0.35,
				c - dir * r * 0.25,
				c - dir * r * 0.5 - perp * r * 0.35
			]
		),
		_ink
	)
	var names := [tr("С"), tr("СВ"), tr("В"), tr("ЮВ"), tr("Ю"), tr("ЮЗ"), tr("З"), tr("СЗ")]
	var idx := int(round(fposmod(track, 360.0) / 45.0)) % 8
	var fs := int(rect.size.y * 0.36)
	draw_string(
		_text,
		Vector2(rect.position.x + 8.0, rect.end.y - 10.0),
		names[idx],
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		fs,
		_ink
	)


# ---------- Страница 2: карта ----------


func _draw_map_page(top: float) -> void:
	var m := _margin
	var strip_h := (size.y - top) * 0.2
	var map_rect := Rect2(m, top, size.x - 2.0 * m, size.y - top - strip_h - m - 6.0)
	draw_rect(map_rect, _ink, false, 1.5)
	var v := vario
	var center := Vector2(v.position.x, v.position.z)
	var track_up := String(_map.get("orientation", "track_up")) == "track_up"
	var rot := -deg_to_rad(v.track_deg) if track_up else 0.0
	var range_m := float(_map.get("range_m", 3000.0))
	if bool(_map.get("auto_zoom", true)):
		var far := 0.0
		for p in v.track:
			far = maxf(far, p.distance_to(center))
		range_m = clampf(far * 1.15, range_m, float(_map.get("auto_zoom_max_m", 50000.0)))
	var px_per_m := map_rect.size.x * 0.5 / range_m
	var c := map_rect.get_center()
	# Мир (x, z) → экран: −Z — север — вверх; при track_up поворачиваем.
	var to_screen := func(p: Vector2) -> Vector2:
		var d := (p - center).rotated(rot)
		return c + d * px_per_m
	# Поворотные пункты — цилиндры.
	for tp in turnpoints:
		var pos: Vector3 = tp.get("position", Vector3.ZERO)
		var sp: Vector2 = to_screen.call(Vector2(pos.x, pos.z))
		var rr := float(tp.get("radius_m", 400.0)) * px_per_m
		if map_rect.grow(rr).has_point(sp):
			var circle := PackedVector2Array()
			var segs := 64
			for k in segs + 1:
				var ang := TAU * float(k) / float(segs)
				circle.append(sp + Vector2(cos(ang), sin(ang)) * maxf(rr, 3.0))
			_draw_clipped(circle, map_rect, 1.5)
			if map_rect.grow(-4.0).has_point(sp):
				draw_circle(sp, 3.0, _ink)
				if bool(_map.get("turnpoint_label", true)):
					draw_string(
						_text,
						sp + Vector2(6, -6),
						String(tp.get("name", "")),
						HORIZONTAL_ALIGNMENT_LEFT,
						-1,
						_label_px,
						_ink
					)
	# След.
	if v.track.size() >= 1:
		var pts := PackedVector2Array()
		for p in v.track:
			pts.append(to_screen.call(p))
		pts.append(c)
		_draw_clipped(pts, map_rect, float(_map.get("track_width_px", 2.0)))
	# Точка взлёта.
	if v.in_flight:
		var tk: Vector2 = to_screen.call(Vector2(v.takeoff_position.x, v.takeoff_position.z))
		if map_rect.has_point(tk):
			draw_rect(Rect2(tk - Vector2(5, 5), Vector2(10, 10)), _ink, false, 2.0)
	# Значок дельтаплана (треугольник крыла) в центре, повернут по курсу.
	var gs := float(_map.get("glider_size_px", 18.0))
	var ga := deg_to_rad(v.heading_deg) + rot
	var fwd := Vector2(sin(ga), -cos(ga))
	var right := Vector2(-fwd.y, fwd.x)
	draw_colored_polygon(
		PackedVector2Array(
			[
				c + fwd * gs * 0.6,
				c - fwd * gs * 0.4 + right * gs,
				c - fwd * gs * 0.15,
				c - fwd * gs * 0.4 - right * gs
			]
		),
		_ink
	)
	# Стрелка севера.
	var n_pos := map_rect.position + Vector2(24, 30)
	var n_dir := Vector2(0, -1).rotated(rot)
	draw_line(n_pos - n_dir * 12.0, n_pos + n_dir * 12.0, _ink, 2.0, true)
	draw_colored_polygon(
		PackedVector2Array(
			[
				n_pos + n_dir * 16.0,
				n_pos + n_dir * 6.0 + n_dir.orthogonal() * 5.0,
				n_pos + n_dir * 6.0 - n_dir.orthogonal() * 5.0
			]
		),
		_ink
	)
	draw_string(
		_text, n_pos + Vector2(14, 6), tr("С"), HORIZONTAL_ALIGNMENT_LEFT, -1, _label_px, _ink
	)
	# Масштабная линейка.
	var bar_m := _nice_length(range_m * 0.5)
	var bar_px := bar_m * px_per_m
	var by := map_rect.end.y - 12.0
	var bx := map_rect.end.x - 12.0 - bar_px
	draw_line(Vector2(bx, by), Vector2(bx + bar_px, by), _ink, 2.0)
	draw_line(Vector2(bx, by - 6), Vector2(bx, by), _ink, 2.0)
	draw_line(Vector2(bx + bar_px, by - 6), Vector2(bx + bar_px, by), _ink, 2.0)
	var label := ("%d м" % int(bar_m)) if bar_m < 1000.0 else ("%s км" % _trim_num(bar_m / 1000.0))
	draw_string(_text, Vector2(bx, by - 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, _label_px, _ink)
	# Нижняя полоса: вариометр, высота, качество, расстояние.
	var sy := map_rect.end.y + 6.0
	var gap := 8.0
	var fw := (size.x - 2.0 * m - gap) * 0.5
	var fh := (strip_h - gap) * 0.5
	var dp := int(fh * 0.5)
	_draw_field(Rect2(m, sy, fw, fh), tr("ВАРИО"), tr("м/с"), _fmt_vario(v.vario_ms, 3), dp)
	_draw_field(
		Rect2(m + fw + gap, sy, fw, fh), tr("ВЫСОТА"), tr("м"), _fmt_int(v.altitude_msl_m, 5), dp
	)
	var ld := "--" if v.glide_ratio == INF or v.glide_ratio > 99.0 else ("%.0f" % v.glide_ratio)
	_draw_field(Rect2(m, sy + fh + gap, fw, fh), tr("КАЧ"), "", _pad(ld, 2), dp)
	_draw_field(
		Rect2(m + fw + gap, sy + fh + gap, fw, fh),
		tr("РАССТ"),
		tr("км"),
		_pad("%.1f" % (v.distance_from_takeoff_m / 1000.0), 4),
		dp
	)


## Нарисовать ломаную, обрезанную прямоугольником (Лианг — Барски по каждому отрезку).
func _draw_clipped(pts: PackedVector2Array, r: Rect2, width: float) -> void:
	var inner := r.grow(-1.0)
	var run := PackedVector2Array()
	for k in range(1, pts.size()):
		var seg := _clip_segment(pts[k - 1], pts[k], inner)
		if seg.is_empty():
			if run.size() >= 2:
				draw_polyline(run, _ink, width, true)
			run = PackedVector2Array()
			continue
		if run.is_empty() or not run[run.size() - 1].is_equal_approx(seg[0]):
			if run.size() >= 2:
				draw_polyline(run, _ink, width, true)
			run = PackedVector2Array([seg[0]])
		run.append(seg[1])
	if run.size() >= 2:
		draw_polyline(run, _ink, width, true)


## Отрезок a–b внутри прямоугольника: [a', b'] или пусто.
func _clip_segment(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [a.x - r.position.x, r.end.x - a.x, a.y - r.position.y, r.end.y - a.y]
	for k in 4:
		if absf(p[k]) < 1e-9:
			if q[k] < 0.0:
				return PackedVector2Array()
		else:
			var t: float = q[k] / p[k]
			if p[k] < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
	if t0 > t1:
		return PackedVector2Array()
	return PackedVector2Array([a + d * t0, a + d * t1])


## «Круглая» длина масштабной линейки: 1, 2, 5 × 10^n, не больше max_m.
func _nice_length(max_m: float) -> float:
	var p := pow(10.0, floor(log(max_m) / log(10.0)))
	for k in [5.0, 2.0, 1.0]:
		if k * p <= max_m:
			return k * p
	return p


func _trim_num(x: float) -> String:
	return str(int(x)) if absf(x - roundf(x)) < 1e-6 else "%.1f" % x
