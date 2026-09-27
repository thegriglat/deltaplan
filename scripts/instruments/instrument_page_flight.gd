class_name InstrumentPageFlight
extends RefCounted
## Страница 1 «ПОЛЁТ»: шкала вариометра слева, поля справа — вариометр, среднее, качество,
## высота MSL и AGL, время, воздушная и путевая скорость, курс и путевой угол.

## Доли высоты рядов полей (вёрстка, не параметры модели).
const ROWS: Array[float] = [0.21, 0.14, 0.17, 0.14, 0.14, 0.14]


static func draw_page(d: InstrumentDisplay, area: Rect2) -> void:
	var sc := d.section("vario_scale")
	var bar_w := float(sc.get("width_px", 80))
	draw_vario_bar(d, Rect2(area.position, Vector2(bar_w, area.size.y)), sc)
	var x0 := area.position.x + bar_w + d.gap * 1.5
	var w := area.end.x - x0
	var half := (w - d.gap) * 0.5
	var hs := _row_heights(area.size.y, d.gap)
	var v := d.vario
	var y := area.position.y
	d.field(Rect2(x0, y, w, hs[0]), d.tr("ВАРИО"), d.tr("м/с"), d.fmt_vario(v.vario_ms))
	y += hs[0] + d.gap
	d.field(Rect2(x0, y, half, hs[1]), d.tr("СРЕДНЕЕ"), d.tr("м/с"), d.fmt_vario(v.average_ms))
	d.field(Rect2(x0 + half + d.gap, y, half, hs[1]), d.tr("КАЧ"), "", d.fmt_glide(v.glide_ratio))
	y += hs[1] + d.gap
	d.field(Rect2(x0, y, w, hs[2]), d.tr("ВЫСОТА"), d.tr("м"), d.fmt_int(v.altitude_msl_m))
	y += hs[2] + d.gap
	var agl := d.fmt_int(maxf(v.altitude_agl_m, 0.0))
	d.field(Rect2(x0, y, half, hs[3]), d.tr("НАД ЗЕМЛ"), d.tr("м"), agl)
	d.field(
		Rect2(x0 + half + d.gap, y, half, hs[3]), d.tr("ВРЕМЯ"), "", d.fmt_time(v.flight_time_s)
	)
	y += hs[3] + d.gap
	var air := d.fmt_int(d.kmh(v.airspeed_ms))
	d.field(Rect2(x0, y, half, hs[4]), d.tr("ВОЗД"), d.tr("км/ч"), air)
	var gnd := d.fmt_int(d.kmh(v.groundspeed_ms))
	d.field(Rect2(x0 + half + d.gap, y, half, hs[4]), d.tr("ПУТЕВ"), d.tr("км/ч"), gnd)
	y += hs[4] + d.gap
	var hdg := d.fmt_int(fposmod(roundf(v.heading_deg), 360.0))
	d.field(Rect2(x0, y, half, hs[5]), d.tr("КУРС"), "°", hdg)
	draw_track_box(d, Rect2(x0 + half + d.gap, y, half, hs[5]), v.track_deg)


static func _row_heights(total: float, gap: float) -> Array[float]:
	var sum := 0.0
	for r in ROWS:
		sum += r
	var avail := total - gap * float(ROWS.size() - 1)
	var out: Array[float] = []
	for r in ROWS:
		out.append(avail * r / sum)
	return out


## Вертикальная сегментная шкала вариометра ±range с нулём посередине,
## треугольник — среднее. Подъём — сплошные сегменты, снижение — полые.
static func draw_vario_bar(d: InstrumentDisplay, rect: Rect2, sc: Dictionary) -> void:
	var rng := float(sc.get("range_ms", 5.0))
	var step := float(sc.get("segment_step_ms", 0.25))
	var n := maxi(int(round(rng / step)), 1)
	d.draw_rect(rect, d.ink, false, d.border)
	var inner := rect.grow(-5.0)
	var mid_y := inner.position.y + inner.size.y * 0.5
	var seg_h := inner.size.y * 0.5 / float(n)
	var seg_w := inner.size.x * 0.5
	var val := clampf(d.vario.vario_ms, -rng, rng)
	var lit := int(floor(absf(val) / step + 0.5))
	for side in [1, -1]:
		for i in n:
			var y_top := mid_y - float(i + 1) * seg_h if side > 0 else mid_y + float(i) * seg_h
			var r := Rect2(inner.position.x, y_top + 1.5, seg_w, seg_h - 3.0)
			var on: bool = (side > 0 and val > 0.0 or side < 0 and val < 0.0) and i < lit
			if on and side > 0:
				d.draw_rect(r, d.ink)
			elif on:
				d.draw_rect(r.grow(-1.5), d.ink, false, 3.0)
			else:
				d.draw_rect(r, d.ghost)
	d.draw_line(Vector2(rect.position.x, mid_y), Vector2(rect.end.x, mid_y), d.ink, d.border * 1.5)
	var lp := d.label_px
	var every := maxi(int(round(1.0 / step)), 1)
	for k in range(every, n + 1, every):
		for side in [1, -1]:
			var yy: float = mid_y - float(side * k) * seg_h
			var tx := Vector2(inner.position.x + seg_w + 4.0, yy + float(lp) * 0.35)
			d.text(tx, str(int(round(k * step))), lp)
	if bool(sc.get("average_marker", true)):
		var ay := mid_y - clampf(d.vario.average_ms, -rng, rng) / step * seg_h
		var ax := rect.end.x - 2.0
		var s := 12.0
		var tri := PackedVector2Array(
			[Vector2(ax, ay - s), Vector2(ax, ay + s), Vector2(ax - s * 1.3, ay)]
		)
		d.draw_colored_polygon(tri, d.ink)


## Путевой угол: стрелка в круге и румб.
static func draw_track_box(d: InstrumentDisplay, rect: Rect2, track: float) -> void:
	d.draw_rect(rect, d.ink, false, d.border)
	d.text(rect.position + Vector2(8, d.label_px + 2), d.tr("ПУТЬ"), d.label_px)
	var r := minf(rect.size.x * 0.28, (rect.size.y - d.label_px) * 0.4)
	var c := Vector2(rect.end.x - r - 12.0, rect.position.y + d.label_px * 0.5 + rect.size.y * 0.5)
	d.draw_arc(c, r, 0.0, TAU, 40, d.ink, d.border, true)
	var a := deg_to_rad(track)
	var dir := Vector2(sin(a), -cos(a))
	d.arrow(c - dir * r * 0.7, c + dir * r * 0.9, 4.0, r * 0.45)
	var names := [
		d.tr("С"), d.tr("СВ"), d.tr("В"), d.tr("ЮВ"), d.tr("Ю"), d.tr("ЮЗ"), d.tr("З"), d.tr("СЗ")
	]
	var idx := int(round(fposmod(track, 360.0) / 45.0)) % 8
	var fs := int(rect.size.y * 0.4)
	d.text(Vector2(rect.position.x + 10.0, rect.end.y - 12.0), names[idx], fs)
