class_name InstrumentDisplay
extends Control
## Экран полётного компьютера-планшета (рисуется в SubViewport через _draw).
## Стиль — e-ink высокой контрастности (как Kobo с XCSoar): «бумага», чёрные рамки и цифры.
## Здесь — общие элементы и помощники рисования; страницы рисуют InstrumentPage*.
## Данные — Vario, WindEstimator, InstrumentTask и настройки звука; все выставляет FlightInstrument.

const PAGE_FLIGHT := 0
const PAGE_MAP := 1
const PAGE_WIND := 2
const PAGE_TASK := 3
const PAGE_THERMAL := 4
const PAGE_COUNT := 5
const PAGE_TITLES: PackedStringArray = [
	"tab_page_flight", "tab_page_map", "tab_page_wind", "tab_page_task", "tab_page_thermal"
]

var vario: Vario
var wind: WindEstimator
var task: InstrumentTask
var thermal: ThermalAssistant
## Настройки звука для показа на странице 4: {volume_db, climb_on_ms, sink_on_ms, enabled, preset}.
var sound: Dictionary = {}
var page: int = PAGE_FLIGHT

var bg: Color
var ink: Color
var ghost: Color
var digits_font: Font
var text_font: Font
var label_px: int = 24
var text_px: int = 28
var margin: float = 16.0
var gap: float = 8.0
var border: float = 2.0
var ghost_digits: bool = false

var _cfg: Dictionary = {}
var _scr: Dictionary = {}
var _units: Dictionary = {}


func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	_scr = cfg.get("screen", {})
	_units = cfg.get("units", {})
	bg = Color(String(_scr.get("lcd_background", "#e9e7df")))
	ink = Color(String(_scr.get("lcd_ink", "#141414")))
	ghost = Color(String(_scr.get("lcd_ghost", "#cfccc2")))
	ghost_digits = bool(_scr.get("ghost_digits", false))
	label_px = int(_scr.get("label_size_px", 24))
	text_px = int(_scr.get("text_size_px", 28))
	margin = float(_scr.get("margin_px", 16))
	gap = float(_scr.get("gap_px", 8))
	border = float(_scr.get("border_px", 2.0))
	digits_font = _load_font(String(_scr.get("digits_font", "")))
	text_font = _load_font(String(_scr.get("text_font", "")))
	size = Vector2(float(_scr.get("width_px", 720)), float(_scr.get("height_px", 960)))


## Раздел конфига instruments.json (для страниц).
func section(section_name: String) -> Dictionary:
	return _cfg.get(section_name, {})


func _draw() -> void:
	if _scr.is_empty() or vario == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), bg)
	var top := _draw_status_bar()
	var area := Rect2(margin, top, size.x - 2.0 * margin, size.y - top - margin)
	match page:
		PAGE_MAP:
			InstrumentPageMap.draw_page(self, area)
		PAGE_WIND:
			InstrumentPageWind.draw_page(self, area)
		PAGE_TASK:
			InstrumentPageTask.draw_page(self, area)
		PAGE_THERMAL:
			InstrumentPageThermal.draw_page(self, area)
		_:
			InstrumentPageFlight.draw_page(self, area)
	_draw_shade()


# ---------- Общие элементы ----------


## Верхняя строка: название страницы, номера страниц (клавиши 1–4), время полёта.
func _draw_status_bar() -> float:
	var h := float(label_px) + 18.0
	var y := margin * 0.5 + float(label_px)
	text(Vector2(margin, y), tr(PAGE_TITLES[page]), label_px)
	var box := float(label_px) + 4.0
	var x0 := size.x * 0.5 - (box + 6.0) * float(PAGE_COUNT) * 0.5
	for i in PAGE_COUNT:
		var r := Rect2(x0 + float(i) * (box + 6.0), y - box + 5.0, box, box)
		var active := i == page
		if active:
			draw_rect(r, ink)
		else:
			draw_rect(r, ink, false, border)
		var col := bg if active else ink
		text(Vector2(r.position.x, r.end.y - 5.0), str(i + 1), label_px, col, 1, r.size.x)
	var t := vario.flight_time_s
	text(Vector2(size.x - margin - 240.0, y), fmt_time(t), label_px, ink, 2, 240.0)
	draw_line(Vector2(margin * 0.5, h), Vector2(size.x - margin * 0.5, h), ink, border)
	return h + gap


## Неравномерность освещения: лёгкое затемнение к краям.
func _draw_shade() -> void:
	var a := float(_scr.get("lcd_shade_alpha", 0.05))
	if a <= 0.0:
		return
	var band := minf(size.x, size.y) * 0.15
	var dark := Color(0, 0, 0, a)
	var clear := Color(0, 0, 0, 0)
	var w := size.x
	var h := size.y
	var top := PackedVector2Array(
		[Vector2(0, 0), Vector2(w, 0), Vector2(w, band), Vector2(0, band)]
	)
	draw_polygon(top, [dark, dark, clear, clear])
	var bot := PackedVector2Array(
		[Vector2(0, h - band), Vector2(w, h - band), Vector2(w, h), Vector2(0, h)]
	)
	draw_polygon(bot, [clear, clear, dark, dark])
	var lft := PackedVector2Array(
		[Vector2(0, 0), Vector2(band, 0), Vector2(band, h), Vector2(0, h)]
	)
	draw_polygon(lft, [dark, clear, clear, dark])
	var rgt := PackedVector2Array(
		[Vector2(w - band, 0), Vector2(w, 0), Vector2(w, h), Vector2(w - band, h)]
	)
	draw_polygon(rgt, [clear, dark, dark, clear])


# ---------- Помощники для страниц ----------


## Текст шрифтом подписей. align: 0 — влево, 1 — центр, 2 — вправо (в ширину width).
func text(
	pos: Vector2,
	s: String,
	px: int,
	col: Color = Color(0, 0, 0, 0),
	align: int = 0,
	width: float = -1.0
) -> void:
	var c := ink if col.a == 0.0 else col
	var ha: HorizontalAlignment = [
		HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT
	][align]
	draw_string(text_font, pos, s, ha, width, px, c)


## Поле как InfoBox у XCSoar: рамка, подпись слева сверху, единицы справа сверху,
## значение крупно справа. is_text — значение шрифтом подписей (слова, а не числа).
func field(rect: Rect2, label: String, units: String, value: String, is_text: bool = false) -> void:
	draw_rect(rect, ink, false, border)
	var lp := label_px
	text(rect.position + Vector2(8, lp + 2), label, lp, ink, 0, rect.size.x * 0.72)
	if units != "":
		text(rect.position + Vector2(0, lp + 2), units, lp, ink, 2, rect.size.x - 8.0)
	var font := text_font if is_text else digits_font
	var avail_h := rect.size.y - lp - 10.0
	var px := int(avail_h * (0.62 if is_text else 0.95))
	var w_avail := rect.size.x - 16.0
	# Вписать по ширине: уменьшаем шрифт, если строка не влезает.
	var sw := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	if sw > w_avail and sw > 0.0:
		px = int(float(px) * w_avail / sw)
	var ascent := font.get_ascent(px)
	var descent := font.get_descent(px)
	var base_y := rect.position.y + lp + 6.0 + (avail_h + ascent - descent) * 0.5
	var pos := Vector2(rect.position.x + 8.0, base_y)
	if ghost_digits and not is_text:
		draw_string(font, pos, _ghost_of(value), HORIZONTAL_ALIGNMENT_RIGHT, w_avail, px, ghost)
	draw_string(font, pos, value, HORIZONTAL_ALIGNMENT_RIGHT, w_avail, px, ink)


## Стрелка от from к to толщиной width.
func arrow(from: Vector2, to: Vector2, width: float, head: float) -> void:
	var d := (to - from).normalized()
	if d == Vector2.ZERO:
		return
	var n := d.orthogonal()
	draw_line(from, to - d * head * 0.8, ink, width, true)
	var tri := PackedVector2Array(
		[to, to - d * head + n * head * 0.5, to - d * head - n * head * 0.5]
	)
	draw_colored_polygon(tri, ink)


## Значок дельтаплана (треугольник крыла) с носом по направлению fwd.
func glider_icon(c: Vector2, fwd: Vector2, s: float) -> void:
	var right := Vector2(-fwd.y, fwd.x)
	var pts := PackedVector2Array(
		[
			c + fwd * s * 0.6,
			c - fwd * s * 0.4 + right * s,
			c - fwd * s * 0.15,
			c - fwd * s * 0.4 - right * s
		]
	)
	draw_colored_polygon(pts, ink)


## Нарисовать ломаную, обрезанную прямоугольником (Лианг — Барски по каждому отрезку).
func draw_clipped(pts: PackedVector2Array, r: Rect2, width: float) -> void:
	var inner := r.grow(-1.0)
	var run := PackedVector2Array()
	for k in range(1, pts.size()):
		var seg := clip_segment(pts[k - 1], pts[k], inner)
		if seg.is_empty():
			if run.size() >= 2:
				draw_polyline(run, ink, width, true)
			run = PackedVector2Array()
			continue
		if run.is_empty() or not run[run.size() - 1].is_equal_approx(seg[0]):
			if run.size() >= 2:
				draw_polyline(run, ink, width, true)
			run = PackedVector2Array([seg[0]])
		run.append(seg[1])
	if run.size() >= 2:
		draw_polyline(run, ink, width, true)


## Отрезок a–b внутри прямоугольника: [a', b'] или пусто.
static func clip_segment(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
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


# ---------- Форматирование ----------


func fmt_time(t: float) -> String:
	var total := int(t)
	return "%d:%02d:%02d" % [total / 3600, (total / 60) % 60, total % 60]


func fmt_vario(v: float) -> String:
	var lim := float(_units.get("vario_display_limit_ms", 19.9))
	var dec := int(_units.get("vario_decimals", 1))
	v = clampf(v, -lim, lim)
	var s := ("%." + str(dec) + "f") % absf(v)
	if s.to_float() == 0.0:
		return s
	return ("+" if v > 0.0 else "-") + s


func fmt_int(v: float) -> String:
	return "%d" % roundi(v)


func fmt_km(m: float) -> String:
	if m == INF or is_nan(m):
		return "--"
	return "%.1f" % (m / 1000.0)


## Качество: «--», если нет снижения или больше 99.
func fmt_glide(ld: float) -> String:
	return "--" if ld == INF or is_nan(ld) or ld > 99.0 else "%.0f" % ld


func kmh(v_ms: float) -> float:
	return Units.to_kmh(v_ms)


## «Погашенные» сегменты для стиля LCD: цифры/минус → 8, точки остаются.
func _ghost_of(s: String) -> String:
	var out := ""
	for ch in s:
		out += ch if ch == "." or ch == ":" else "8"
	return out


func _load_font(path: String) -> Font:
	if path != "" and ResourceLoader.exists(path):
		var f: Variant = load(path)
		if f is Font:
			return f
	return ThemeDB.fallback_font
