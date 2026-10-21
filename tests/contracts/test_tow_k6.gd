extends TestCase
## Контракт TW-К6 (docs/contracts/tow.md): start_sites[].tow, TowSite.check, поляна-полоса.
## Буксирное место wilotree_park.json (TW-8b) разбирается без сборки рельефа.

const N := 81  # сетка 25 м: ±1000 м, внутри отступа 200 м — ±800 м
const STEP := 25.0


## Плоскость h = 100 + ax·x + az·z на сетке 81×81 шагом 25 м (как tests/terrain/test_terrain.gd).
func _plane(ax: float, az: float) -> Terrain:
	var data := PackedFloat32Array()
	data.resize(N * N)
	for j in N:
		for i in N:
			data[j * N + i] = 100.0 + ax * (-1000.0 + i * STEP) + az * (-1000.0 + j * STEP)
	var t := Terrain.new()
	t.location_id = ""
	t.layers = [HeightLayer.from_heights("plane", N, N, STEP, -1000.0, -1000.0, data)]
	return t


func test_check_flat_ok() -> void:
	var t := _plane(0.0, 0.0)
	var r := TowSite.check(t, 0.0, 400.0, 0.0, 300.0, 40.0)
	check(bool(r.ok) and r.reason == "", "ровная полоса — ok (%s)" % r.reason)
	check(is_equal_approx(float(r.flat_length_m), 300.0), "flat_length_m = длина: %.1f" % r.flat_length_m)
	check(float(r.slope_deg) < 0.01 and float(r.dh_m) < 0.01, "уклон и перепад нулевые")
	t.free()


func test_check_slope_not_ok() -> void:
	var t := _plane(0.0, tan(deg_to_rad(10.0)))  # склон 10° вдоль оси z
	var r := TowSite.check(t, 0.0, 400.0, 0.0, 300.0, 40.0)
	check(not bool(r.ok), "склон 10° — не ok")
	check(String(r.reason) == "tow_site_slope", "reason = tow_site_slope: %s" % r.reason)
	check(absf(float(r.slope_deg) - 10.0) < 0.2, "slope_deg ≈ 10°: %.2f" % r.slope_deg)
	check(float(r.flat_length_m) < 300.0, "ровный участок короче полосы")
	# поперёк склона по оси — ось ровная, но поперечный уклон рубит
	var r2 := TowSite.check(t, -100.0, 0.0, 90.0, 300.0, 40.0)
	check(not bool(r2.ok) and r2.reason == "tow_site_slope", "поперечный уклон 10° — не ok: %s" % r2.reason)
	t.free()


func test_check_dh_and_edge() -> void:
	var g := tan(deg_to_rad(1.5))  # уклон 1,5° < 2° на шаге, но 300 м → 7,9 м > 2 % = 6 м
	var t := _plane(0.0, g)
	var r := TowSite.check(t, 0.0, 400.0, 0.0, 300.0, 40.0)
	check(not bool(r.ok) and r.reason == "tow_site_dh", "перепад > 2 %% длины: %s" % r.reason)
	var e := TowSite.check(_plane(0.0, 0.0), 0.0, 700.0, 180.0, 300.0, 40.0)
	check(not bool(e.ok) and e.reason == "tow_site_edge", "конец за отступом от края: %s" % e.reason)
	var bad := TowSite.check(t, 0.0, 0.0, 0.0, -5.0, 40.0)
	check(not bool(bad.ok) and bad.reason == "tow_site_bad", "длина < 0 — tow_site_bad")
	t.free()


func test_check_end_pos_distance() -> void:
	var t := _plane(0.0, 0.0)
	for hd in [0.0, 37.0, 90.0, 215.0, 300.0]:
		var r := TowSite.check(t, 50.0, -30.0, hd, 300.0, 40.0)
		var d := Vector2(r.end_pos.x - r.start_pos.x, r.end_pos.z - r.start_pos.z)
		check(absf(d.length() - 300.0) <= 1.0, "курс %.0f°: |end − start| = %.2f м" % [hd, d.length()])
		var want := Vector2(sin(deg_to_rad(hd)), -cos(deg_to_rad(hd)))
		check(d.normalized().dot(want) > 0.9999, "курс %.0f°: направление по курсу" % hd)
		check(is_equal_approx(float(r.start_pos.y), 100.0), "start_pos на земле")
	t.free()


func test_check_surface() -> void:
	var t := _plane(0.0, 0.0)
	for cls in [SurfaceLayer.WATER, SurfaceLayer.FOREST, SurfaceLayer.BUILT]:
		var data := PackedByteArray()
		data.resize(N * N)
		data.fill(SurfaceLayer.GRASS)
		var sl := SurfaceLayer.from_classes("s", N, N, STEP, -1000.0, -1000.0, data)
		for j in range(46, 49):  # полоса z = 150…250 м: узлы строк j = 46…48 (z = 150, 175, 200)
			for i in range(N):
				sl.classes[j * N + i] = cls
		t.surfaces = [sl]
		var r := TowSite.check(t, 0.0, 400.0, 0.0, 300.0, 40.0)
		check(bool(r.ok) == (cls == SurfaceLayer.BUILT), "класс %d: ok=%s (%s)" % [cls, r.ok, r.reason])
		if cls != SurfaceLayer.BUILT:
			check(r.reason == "tow_site_surface", "reason = tow_site_surface")
	t.free()


func test_runway_clearing() -> void:
	var t := _plane(0.0, 0.0)
	var data := PackedByteArray()
	data.resize(N * N)
	data.fill(SurfaceLayer.FOREST)
	t.surfaces = [SurfaceLayer.from_classes("s", N, N, STEP, -1000.0, -1000.0, data)]
	var start := Vector3(0.0, 100.0, 400.0)
	t.add_runway_clearing(start, 0.0, 300.0, 100.0)  # на север: z от 400 к 100
	for f in [0.0, 0.5, 1.0]:
		for lat in [-50.0, 0.0, 50.0]:
			var z: float = 400.0 - 300.0 * f
			check(t.surface_at(lat, z) != SurfaceLayer.FOREST, "полоса: z=%.0f x=%.0f не лес" % [z, lat])
	check(t.surface_at(150.0, 250.0) == SurfaceLayer.FOREST, "сбоку (x=150) лес остался")
	check(t.surface_at(0.0, 0.0) == SurfaceLayer.FOREST, "за концом (z=0) лес остался")
	check(t.get_start_clearings().size() >= 3, "круги поляны в get_start_clearings")
	t.free()


func test_start_sites_tow_passthrough() -> void:
	var t := _plane(0.0, 0.0)
	t.location = {
		"start_sites":
		[
			{"id": "a", "name": "A", "lat": 0.0, "lon": 0.0, "heading_deg": 10.0,
			"tow": {"kinds": ["winch_static", "aerotow"], "runway_length_m": 300.0, "runway_width_m": 40.0}},
			{"id": "b", "name": "B", "lat": 0.0, "lon": 0.0, "heading_deg": 20.0},
		]
	}
	t._build_sites()
	var sites := t.get_start_sites()
	check(sites.size() == 2, "две площадки")
	check(sites[0].get("tow") is Dictionary, "у a есть tow (Dictionary)")
	check(Array(sites[0].tow.kinds).has("winch_static"), "tow.kinds содержит winch_static")
	check(is_equal_approx(float(sites[0].tow.runway_length_m), 300.0), "runway_length_m как есть")
	check(not sites[1].has("tow"), "без tow — ключа нет")
	t.free()


## Буксирное место (TW-8b): конфиг разбирается, у обеих площадок tow.kinds содержит winch_static и aerotow,
## оси противоположны (356,8° и 176,8°), длина — заявленная 610 м, запись есть в «Популярных местах».
func test_wilotree_park_config() -> void:
	var loc: Dictionary = Config.get_config("locations/wilotree_park")
	check(not loc.is_empty(), "locations/wilotree_park.json разобран")
	check(Locations.is_builtin("wilotree_park"), "место встроенное")
	var sites: Array = loc.get("start_sites", [])
	check(sites.size() == 2, "две площадки: %d" % sites.size())
	var hs: Array[float] = []
	for s in sites:
		check(s.get("tow") is Dictionary, "у %s есть tow" % s.get("id", "?"))
		var tow: Dictionary = s.get("tow", {})
		check(Array(tow.get("kinds", [])).has("winch_static"), "kinds содержит winch_static")
		check(Array(tow.get("kinds", [])).has("aerotow"), "kinds содержит aerotow")
		check(is_equal_approx(float(tow.get("runway_length_m", 0.0)), 610.0), "runway_length_m = 610")
		check(is_equal_approx(float(tow.get("runway_width_m", 0.0)), 35.0), "runway_width_m = 35")
		hs.append(float(s.heading_deg))
	if hs.size() == 2:
		check(absf(fposmod(hs[0] - hs[1], 360.0) - 180.0) < 0.01, "оси противоположны: %s" % [hs])
	var found := 0
	var cat: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/places/hg_takeoffs.json"))
	for p in cat.get("takeoffs", []):
		if String(p.get("id", "")).begins_with("builtin/wilotree_park/"):
			found += 1
			check(String(p.get("location", "")) == "wilotree_park", "location в записи каталога")
	check(found == 2, "в hg_takeoffs.json две записи wilotree_park: %d" % found)
