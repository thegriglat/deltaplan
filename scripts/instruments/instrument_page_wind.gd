class_name InstrumentPageWind
extends RefCounted
## Страница 3 «ВЕТЕР»: роза ветров (север вверху) со стрелкой ветра и значком курса,
## оценка ветра (откуда, скорость, метод), встречная составляющая, текущее и требуемое
## качество до цели, расстояние и высота прибытия. Без цели — прочерки.

const ROSE_FRAC := 0.40  # доля высоты под розу ветров


static func draw_page(d: InstrumentDisplay, area: Rect2) -> void:
	var rose_h := area.size.y * ROSE_FRAC
	var rose_rect := Rect2(area.position, Vector2(area.size.x, rose_h))
	_draw_rose(d, rose_rect)
	var w := d.wind
	var v := d.vario
	var t := d.task
	var valid := w.is_valid()
	var rows := 4
	var y := rose_rect.end.y + d.gap
	var rh := (area.end.y - y - d.gap * float(rows - 1) - float(d.text_px) - d.gap) / float(rows)
	var half := (area.size.x - d.gap) * 0.5
	var x0 := area.position.x
	var x1 := x0 + half + d.gap
	var from_s := d.fmt_int(w.direction_from_deg()) if valid else "--"
	var spd_s := d.fmt_int(d.kmh(w.speed_ms())) if valid else "--"
	d.field(Rect2(x0, y, half, rh), d.tr("tab_wind_from"), "°", from_s)
	d.field(Rect2(x1, y, half, rh), d.tr("tab_wind"), d.tr("unit_kmh"), spd_s)
	y += rh + d.gap
	var head := d.kmh(w.headwind_ms(v.track_deg))
	var head_s := ("%+d" % roundi(head)) if valid else "--"
	d.field(Rect2(x0, y, half, rh), d.tr("tab_headwind"), d.tr("unit_kmh"), head_s)
	d.field(Rect2(x1, y, half, rh), d.tr("tab_method"), "", _method_name(d, w), true)
	y += rh + d.gap
	var req := t.glide_needed(v.position, v.altitude_msl_m)
	var has := t.has_target() or t.is_race()
	var req_s := "--" if not has else ("∞" if req == INF else d.fmt_glide(req))
	d.field(Rect2(x0, y, half, rh), d.tr("tab_glide_now"), "", d.fmt_glide(v.glide_ratio))
	d.field(Rect2(x1, y, half, rh), d.tr("tab_glide_required"), "", req_s, req_s == "∞")
	y += rh + d.gap
	var dist := t.distance_for_glide(v.position)
	var arr := t.arrival_for_glide(v.position, v.altitude_msl_m, v.glide_ratio)
	var arr_s := "--" if is_nan(arr) else "%+d" % roundi(arr)
	var dist_label := d.tr("tab_to_goal") if t.is_race() else d.tr("tab_to_target")
	d.field(Rect2(x0, y, half, rh), dist_label, d.tr("unit_km"), d.fmt_km(dist))
	d.field(Rect2(x1, y, half, rh), d.tr("tab_arrival"), d.tr("unit_m"), arr_s)
	y += rh + d.gap + float(d.text_px)
	var target := t.target_name() if t.has_target() else d.tr("tab_no_target")
	if t.is_race():
		target = String(t.race.get("next_name", target)) + " → " + d.tr("tab_goal_short")
	d.text(Vector2(x0 + 4.0, y), d.tr("tab_target") % target, d.text_px, d.ink, 0, area.size.x)


static func _method_name(d: InstrumentDisplay, w: WindEstimator) -> String:
	if not w.is_valid():
		return d.tr("tab_no_data")
	if w.method == WindEstimator.METHOD_CIRCLING:
		return d.tr("tab_circles") + " ×%d" % w.circles
	return d.tr("tab_straight")


static func _draw_rose(d: InstrumentDisplay, rect: Rect2) -> void:
	d.draw_rect(rect, d.ink, false, d.border)
	var c := rect.get_center()
	var r := minf(rect.size.x, rect.size.y) * 0.5 - float(d.label_px) - 14.0
	d.draw_arc(c, r, 0.0, TAU, 96, d.ink, d.border, true)
	for k in 12:
		var a := deg_to_rad(float(k) * 30.0)
		var dir := Vector2(sin(a), -cos(a))
		var inner := r * (0.86 if k % 3 == 0 else 0.92)
		d.draw_line(c + dir * inner, c + dir * r, d.ink, d.border)
	var names := [d.tr("dir_n"), d.tr("dir_e"), d.tr("dir_s"), d.tr("dir_w")]
	for k in 4:
		var a := deg_to_rad(float(k) * 90.0)
		var p := c + Vector2(sin(a), -cos(a)) * (r + float(d.label_px) * 0.8)
		d.text(p + Vector2(-40.0, float(d.label_px) * 0.35), names[k], d.label_px, d.ink, 1, 80.0)
	# Курс крыла — значок на окружности.
	var ha := deg_to_rad(d.vario.heading_deg)
	var hdir := Vector2(sin(ha), -cos(ha))
	d.glider_icon(c + hdir * r * 0.75, hdir, 16.0)
	# Стрелка ветра: из наветренной стороны через центр туда, куда дует; длина ~ скорость.
	var w := d.wind
	if not w.is_valid():
		d.text(c + Vector2(-120.0, 10.0), d.tr("tab_wind_no_data"), d.text_px, d.ink, 1, 240.0)
		return
	var dir_to := Vector2(w.wind.x, w.wind.y).normalized()
	var full_ms := Units.kmh(float(d.section("wind").get("rose_full_kmh", 40.0)))
	var len_k := clampf(w.speed_ms() / full_ms, 0.25, 1.0)
	d.arrow(c - dir_to * r * 0.6 * len_k, c + dir_to * r * 0.6 * len_k, 6.0, 26.0)
	var label := (
		"%d° / %d %s" % [roundi(w.direction_from_deg()), roundi(d.kmh(w.speed_ms())), d.tr("unit_kmh")]
	)
	d.text(Vector2(rect.position.x + 10.0, rect.end.y - 12.0), label, d.text_px)
