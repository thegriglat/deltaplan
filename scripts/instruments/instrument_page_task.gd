class_name InstrumentPageTask
extends RefCounted
## Страница 4 «ЗАДАНИЕ»: список пунктов задания (активный отмечен) или «нет задания»;
## настройки звука вариометра (только показ — менять через FlightInstrument.request_setting).


static func draw_page(d: InstrumentDisplay, area: Rect2) -> void:
	var tp := d.text_px
	var line := float(tp) * 1.45
	var x := area.position.x + 6.0
	var y := area.position.y + float(tp)
	d.text(Vector2(x, y), d.tr("ЗАДАНИЕ"), tp)
	y += 10.0
	d.draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), d.ink, d.border)
	y += line
	var t := d.task
	var v := d.vario
	if t.points.is_empty():
		d.text(Vector2(x, y), d.tr("нет задания"), int(float(tp) * 1.2))
		y += line
		d.text(Vector2(x, y), d.tr("свободный полёт"), tp, d.ink)
		y += line
	else:
		var max_n := int(d.section("task").get("max_list_points", 10))
		for i in mini(t.points.size(), max_n):
			var p: Dictionary = t.points[i]
			var mark := "▶" if i == t.active else " "
			var name := "%s %d. %s" % [mark, i + 1, String(p.get("name", ""))]
			var r_km := float(p.get("radius_m", t.default_radius_m)) / 1000.0
			var dist := t.distance_to_point(v.position, i)
			var dist_s := "%s %s" % [d.fmt_km(dist), d.tr("км")]
			d.text(Vector2(x, y), name, tp, d.ink, 0, area.size.x * 0.55)
			d.text(Vector2(area.position.x, y), "r %.1f" % r_km, tp, d.ink, 2, area.size.x * 0.66)
			d.text(Vector2(area.position.x, y), dist_s, tp, d.ink, 2, area.size.x - 6.0)
			y += line
		if t.points.size() > max_n:
			d.text(Vector2(x, y), "… +%d" % (t.points.size() - max_n), tp)
			y += line
	y += line * 0.5
	d.text(Vector2(x, y), d.tr("ЗВУК ВАРИОМЕТРА"), tp)
	y += 10.0
	d.draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), d.ink, d.border)
	y += line
	var s := d.sound
	var rows := [
		[d.tr("Звук"), d.tr("вкл") if bool(s.get("enabled", true)) else d.tr("выкл")],
		[d.tr("Громкость"), "%+.0f %s" % [float(s.get("volume_db", 0.0)), d.tr("дБ")]],
		[d.tr("Порог писка"), "%+.1f %s" % [float(s.get("climb_on_ms", 0.1)), d.tr("м/с")]],
		[d.tr("Порог гудения"), "%+.1f %s" % [float(s.get("sink_on_ms", -2.5)), d.tr("м/с")]],
		[d.tr("Звучание"), String(s.get("preset_title", s.get("preset", "")))],
	]
	for row in rows:
		d.text(Vector2(x, y), String(row[0]), tp)
		d.text(Vector2(area.position.x, y), String(row[1]), tp, d.ink, 2, area.size.x - 6.0)
		y += line
	y += line * 0.3
	d.text(Vector2(x, y), d.tr("изменение — в настройках (пауза)"), d.label_px)
