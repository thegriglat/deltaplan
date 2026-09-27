class_name InstrumentPageThermal
extends RefCounted
## Страница 5 «ЦЕНТРОВКА» — помощник центровки как у XCSoar: крыло в центре носом вверх,
## вокруг — диаграмма подъёма по сторонам круга относительно текущего курса
## (дальше от центра — сильнее), стрелка «сдвинь круг сюда», среднее за круг.
## На прямой — «нет кружения».

const PLOT_FRAC := 0.68  # доля высоты под диаграмму


static func draw_page(d: InstrumentDisplay, area: Rect2) -> void:
	var ta := d.thermal
	var c := d.section("thermal_assistant")
	var plot := Rect2(area.position, Vector2(area.size.x, area.size.y * PLOT_FRAC))
	d.draw_rect(plot, d.ink, false, d.border)
	var center := plot.get_center()
	var r := minf(plot.size.x, plot.size.y) * 0.5 - float(d.label_px) - 16.0
	# Кольца: среднее за круг (середина) и ± plot_range.
	for k in [0.5, 1.0]:
		d.draw_arc(center, r * k, 0.0, TAU, 96, d.ghost if k < 1.0 else d.ink, d.border, true)
	d.text(center + Vector2(-40.0, -r - 8.0), d.tr("вперёд"), d.label_px, d.ink, 1, 80.0)
	d.glider_icon(center, Vector2(0, -1), 26.0)
	var hdg := d.vario.heading_deg
	if not ta.circling:
		d.text(
			center + Vector2(-200.0, r * 0.5), d.tr("нет кружения"), d.text_px + 8, d.ink, 1, 400.0
		)
	else:
		_draw_lift_polygon(d, ta, center, r, hdg, float(c.get("plot_range_ms", 2.0)))
		var show_arrow := bool(c.get("show_shift_arrow", true))
		if show_arrow and ta.asymmetry_ms >= float(c.get("shift_min_ms", 0.2)):
			var a := deg_to_rad(ta.strong_relative_deg(hdg))
			var dir := Vector2(sin(a), -cos(a))
			d.arrow(center + dir * r * 0.25, center + dir * r * 0.95, 7.0, 30.0)
	# Поля под диаграммой.
	var y := plot.end.y + d.gap
	var rh := (area.end.y - y - d.gap) * 0.5
	var half := (area.size.x - d.gap) * 0.5
	var x1 := area.position.x + half + d.gap
	var avg_s := d.fmt_vario(ta.circle_average_ms) if ta.circling else "--"
	d.field(
		Rect2(area.position.x, y, half, rh),
		d.tr("ВАРИО"),
		d.tr("м/с"),
		d.fmt_vario(d.vario.vario_ms)
	)
	d.field(Rect2(x1, y, half, rh), d.tr("СРЕДНЕЕ КРУГ"), d.tr("м/с"), avg_s)
	y += rh + d.gap
	var turn := "--"
	if ta.circling:
		turn = d.tr("вправо") if ta.turn_dir > 0 else d.tr("влево")
	d.field(Rect2(area.position.x, y, half, rh), d.tr("ВИРАЖ"), "", turn, true)
	var side := _side_name(d, ta, hdg) if ta.circling else "--"
	d.field(Rect2(x1, y, half, rh), d.tr("СИЛЬНЕЕ"), "", side, true)


## Многоугольник подъёма: радиус = середина + (сектор − среднее) / plot_range · половина радиуса.
static func _draw_lift_polygon(
	d: InstrumentDisplay, ta: ThermalAssistant, center: Vector2, r: float, hdg: float, rng: float
) -> void:
	var n := ta.sectors.size()
	var pts := PackedVector2Array()
	for k in n:
		var v := ta.sectors[k]
		if is_nan(v):
			continue
		var rel := deg_to_rad((float(k) + 0.5) * 360.0 / float(n) - hdg)
		var rr := r * (0.5 + 0.5 * clampf((v - ta.circle_average_ms) / rng, -0.9, 1.0))
		pts.append(center + Vector2(sin(rel), -cos(rel)) * rr)
	if pts.size() >= 3:
		pts.append(pts[0])
		d.draw_polyline(pts, d.ink, 4.0, true)
		for p in pts:
			d.draw_circle(p, 3.0, d.ink)


static func _side_name(d: InstrumentDisplay, ta: ThermalAssistant, hdg: float) -> String:
	var c := d.section("thermal_assistant")
	if ta.asymmetry_ms < float(c.get("shift_min_ms", 0.2)):
		return d.tr("ровно")
	var rel := ta.strong_relative_deg(hdg)
	var names := [
		d.tr("впереди"),
		d.tr("впер-справа"),
		d.tr("справа"),
		d.tr("сзади-справа"),
		d.tr("сзади"),
		d.tr("сзади-слева"),
		d.tr("слева"),
		d.tr("впер-слева")
	]
	return names[int(round(fposmod(rel, 360.0) / 45.0)) % 8]
