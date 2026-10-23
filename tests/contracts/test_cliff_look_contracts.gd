extends TestCase
## Контрактные тесты cliff-look (docs/contracts/cliff-look.md). CL-К1 v1 — формат стенда ракурсов
## tools/shots/cliff_look_views.json (владелец CL-1): ломается, если формат поменяли без правки контракта.

const VIEWS := "res://tools/shots/cliff_look_views.json"
const VIEW_NUM := ["lat", "lon", "dist_m", "cam_agl_m", "az_deg", "wait_s"]


func _views() -> Dictionary:
	var txt := FileAccess.get_file_as_string(VIEWS)
	var d: Variant = JSON.parse_string(txt)
	return d if d is Dictionary else {}


static func _num(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


static func _latin(s: String) -> bool:
	var re := RegEx.create_from_string("^[a-z][a-z0-9_]*$")
	return re.search(s) != null


func test_k1_header() -> void:
	var d := _views()
	check(not d.is_empty(), "cliff_look_views.json читается как объект JSON")
	check(_num(d.get("version")) and int(d.version) == 1, "version == 1")
	check(typeof(d.get("date")) == TYPE_STRING and RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2}$").search(d.date) != null,
			"date — ГГГГ-ММ-ДД")
	check(_num(d.get("hour")) and float(d.hour) >= 0.0 and float(d.hour) < 24.0, "hour — местный час 0..24")
	check(_num(d.get("sun_min_deg")) and float(d.sun_min_deg) >= 35.0, "sun_min_deg ≥ 35 (кадры не зависят от HH-15)")
	check(d.get("places") is Array, "places — массив")


func test_k1_places_and_views() -> void:
	var d := _views()
	var places: Array = d.get("places", [])
	check(places.size() >= 3, "мест ≥ 3, есть %d" % places.size())
	var tags := {}
	var shym := false
	for p: Variant in places:
		check(p is Dictionary, "место — объект")
		if not p is Dictionary:
			continue
		var tag := String(p.get("tag", ""))
		check(_latin(tag), "tag латиницей: «%s»" % tag)
		check(not tags.has(tag), "tag не повторяется: %s" % tag)
		tags[tag] = true
		shym = shym or tag.contains("shymbulak")
		check(typeof(p.get("name")) == TYPE_STRING and String(p.name) != "", "%s: name — строка" % tag)
		check(_num(p.get("lat")) and absf(float(p.lat)) <= 90.0, "%s: lat" % tag)
		check(_num(p.get("lon")) and absf(float(p.lon)) <= 180.0, "%s: lon" % tag)
		var views: Array = p.get("views", [])
		check(views.size() >= 2, "%s: ракурсов ≥ 2, есть %d" % [tag, views.size()])
		var names := {}
		for v: Variant in views:
			check(v is Dictionary, "%s: ракурс — объект" % tag)
			if not v is Dictionary:
				continue
			var vn := String(v.get("name", ""))
			check(_latin(vn), "%s: имя ракурса латиницей «%s»" % [tag, vn])
			check(not names.has(vn), "%s: имя ракурса не повторяется: %s" % [tag, vn])
			names[vn] = true
			for k: String in VIEW_NUM:
				check(_num(v.get(k)), "%s/%s: %s — число" % [tag, vn, k])
			if _num(v.get("dist_m")):
				check(float(v.dist_m) > 0.0, "%s/%s: dist_m > 0" % [tag, vn])
			if _num(v.get("wait_s")):
				check(float(v.wait_s) >= 0.0, "%s/%s: wait_s ≥ 0" % [tag, vn])
			if _num(v.get("az_deg")):
				check(float(v.az_deg) >= 0.0 and float(v.az_deg) < 360.0, "%s/%s: az_deg 0..360" % [tag, vn])
	check(shym, "есть место Шымбулак (tag shymbulak)")


func test_k1_sun_above_min() -> void:
	# Высота солнца в полдень по солнечному склонению даты (оценка: час — местный, рядом с полуднем;
	# точная — игра печатает «солнце … над горизонтом» в tools/shots/cliff_look_shot.gd).
	var d := _views()
	var p := String(d.get("date", "2000-07-15")).split("-")
	var doy := (int(p[1]) - 1) * 30.4 + int(p[2])
	var decl := 23.44 * sin(deg_to_rad(360.0 / 365.0 * (doy - 81.0)))
	var hour_angle := 15.0 * (float(d.get("hour", 12.0)) - 12.0)
	for pl: Dictionary in d.get("places", []):
		var lat := deg_to_rad(float(pl.lat))
		var dc := deg_to_rad(decl)
		var el := rad_to_deg(asin(sin(lat) * sin(dc) + cos(lat) * cos(dc) * cos(deg_to_rad(hour_angle))))
		check(el > float(d.get("sun_min_deg", 35.0)), "%s: солнце %.0f° > sun_min_deg" % [pl.tag, el])
