class_name InstrumentPageMap
extends RefCounted
## Страница 2 «КАРТА»: свой след, точка взлёта, поворотные пункты-цилиндры (активный — жирно),
## значок дельтаплана, север, масштаб. Термики и потоки не показываются (FR-22).

const STRIP_FRAC := 0.17  # доля высоты под нижнюю полосу полей


static func draw_page(d: InstrumentDisplay, area: Rect2) -> void:
	var mp := d.section("map")
	var strip_h := area.size.y * STRIP_FRAC
	var map_rect := Rect2(area.position, Vector2(area.size.x, area.size.y - strip_h - d.gap))
	d.draw_rect(map_rect, d.ink, false, d.border)
	var v := d.vario
	var center := Vector2(v.position.x, v.position.z)
	var track_up := String(mp.get("orientation", "north_up")) == "track_up"
	var rot := -deg_to_rad(v.track_deg) if track_up else 0.0
	var range_m := float(mp.get("range_m", 3000.0))
	if bool(mp.get("auto_zoom", true)):
		var far := 0.0
		for p in v.track:
			far = maxf(far, p.distance_to(center))
		if d.task.has_target():
			var tp: Vector3 = d.task.target().get("position", Vector3.ZERO)
			far = maxf(far, Vector2(tp.x, tp.z).distance_to(center))
		range_m = clampf(far * 1.15, range_m, float(mp.get("auto_zoom_max_m", 50000.0)))
	var px_per_m := map_rect.size.x * 0.5 / range_m
	var c := map_rect.get_center()
	var to_screen := func(p: Vector2) -> Vector2: return c + (p - center).rotated(rot) * px_per_m
	_draw_turnpoints(d, map_rect, to_screen, px_per_m, mp)
	if v.track.size() >= 1:
		var pts := PackedVector2Array()
		for p in v.track:
			pts.append(to_screen.call(p))
		pts.append(c)
		d.draw_clipped(pts, map_rect, float(mp.get("track_width_px", 3.0)))
	if v.in_flight:
		var tk: Vector2 = to_screen.call(Vector2(v.takeoff_position.x, v.takeoff_position.z))
		if map_rect.has_point(tk):
			d.draw_rect(Rect2(tk - Vector2(7, 7), Vector2(14, 14)), d.ink, false, d.border)
	var ga := deg_to_rad(v.heading_deg) + rot
	d.glider_icon(c, Vector2(sin(ga), -cos(ga)), float(mp.get("glider_size_px", 24.0)))
	_draw_north(d, map_rect, rot)
	_draw_scale(d, map_rect, range_m, px_per_m)
	# Нижняя полоса полей.
	var sy := map_rect.end.y + d.gap
	var fw := (area.size.x - 2.0 * d.gap) / 3.0
	var r0 := Rect2(area.position.x, sy, fw, strip_h)
	d.field(r0, d.tr("tab_vario"), d.tr("unit_ms"), d.fmt_vario(v.vario_ms))
	var r1 := Rect2(area.position.x + fw + d.gap, sy, fw, strip_h)
	d.field(r1, d.tr("tab_altitude"), d.tr("unit_m"), d.fmt_int(v.altitude_msl_m))
	var r2 := Rect2(area.position.x + 2.0 * (fw + d.gap), sy, fw, strip_h)
	d.field(r2, d.tr("tab_from_launch"), d.tr("unit_km"), d.fmt_km(v.distance_from_takeoff_m))


static func _draw_turnpoints(
	d: InstrumentDisplay, map_rect: Rect2, to_screen: Callable, px_per_m: float, mp: Dictionary
) -> void:
	for i in d.task.points.size():
		var tp: Dictionary = d.task.points[i]
		var pos: Vector3 = tp.get("position", Vector3.ZERO)
		var sp: Vector2 = to_screen.call(Vector2(pos.x, pos.z))
		var rr := maxf(float(tp.get("radius_m", d.task.default_radius_m)) * px_per_m, 4.0)
		if not map_rect.grow(rr).has_point(sp):
			continue
		var circle := PackedVector2Array()
		var segs := 72
		for k in segs + 1:
			var ang := TAU * float(k) / float(segs)
			circle.append(sp + Vector2(cos(ang), sin(ang)) * rr)
		var active := i == d.task.active
		d.draw_clipped(circle, map_rect, d.border * (2.0 if active else 1.0))
		if map_rect.grow(-6.0).has_point(sp):
			d.draw_circle(sp, 4.0, d.ink)
			if bool(mp.get("turnpoint_label", true)):
				d.text(sp + Vector2(8, -8), String(tp.get("name", "")), d.label_px)


static func _draw_north(d: InstrumentDisplay, map_rect: Rect2, rot: float) -> void:
	var n_pos := map_rect.position + Vector2(34, 44)
	var n_dir := Vector2(0, -1).rotated(rot)
	d.arrow(n_pos - n_dir * 18.0, n_pos + n_dir * 22.0, 3.0, 14.0)
	d.text(n_pos + Vector2(18, 10), d.tr("dir_n"), d.label_px)


static func _draw_scale(
	d: InstrumentDisplay, map_rect: Rect2, range_m: float, px_per_m: float
) -> void:
	var bar_m := nice_length(range_m * 0.5)
	var bar_px := bar_m * px_per_m
	var by := map_rect.end.y - 16.0
	var bx := map_rect.end.x - 16.0 - bar_px
	d.draw_line(Vector2(bx, by), Vector2(bx + bar_px, by), d.ink, 3.0)
	d.draw_line(Vector2(bx, by - 8), Vector2(bx, by), d.ink, 3.0)
	d.draw_line(Vector2(bx + bar_px, by - 8), Vector2(bx + bar_px, by), d.ink, 3.0)
	var km := bar_m / 1000.0
	var km_s := str(int(km)) if absf(km - roundf(km)) < 1e-6 else "%.1f" % km
	var label := (
		("%d " % int(bar_m) + d.tr("unit_m")) if bar_m < 1000.0 else (km_s + " " + d.tr("unit_km"))
	)
	d.text(Vector2(bx, by - 12), label, d.label_px)


## «Круглая» длина масштабной линейки: 1, 2, 5 × 10^n, не больше max_m.
static func nice_length(max_m: float) -> float:
	var p := pow(10.0, floor(log(max_m) / log(10.0)))
	for k in [5.0, 2.0, 1.0]:
		if k * p <= max_m:
			return k * p
	return p
