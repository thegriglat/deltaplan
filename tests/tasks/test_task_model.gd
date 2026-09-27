extends TestCase
## Модель задания: демо-задания (Алтай, Онгудай), импорт .xctsk, разбор времени.

const H := preload("res://tests/tasks/task_helpers.gd")
## Половина стороны детальной зоны рельефа Алтая, м (configs/locations/altai.json → 40 км).
const DETAIL_HALF_M := 20000.0
## Центр локации «Онгудай», пока нет configs/locations/ongudai.json (агент terrain2).
const ONGUDAI_FALLBACK := Vector2(50.75, 86.14)
const ONGUDAI_CFG := "res://configs/locations/ongudai.json"


func test_altai_demo_inside_detail_area() -> void:
	var t := Task.load_config("altai_demo", H.latlon_fn())
	check(t.errors.is_empty(), "без ошибок: %s" % [t.errors])
	check(t.points.size() == 6, "6 пунктов")
	check(t.takeoff_index == 0 and t.sss_index == 1, "взлёт и старт")
	check(t.ess_index == 4 and t.goal_index == 5, "ESS и гоул")
	for p in t.points:
		var inside := absf(p.position.x) + p.radius_m < DETAIL_HALF_M
		inside = inside and absf(p.position.z) + p.radius_m < DETAIL_HALF_M
		check(inside, "%s в детальной зоне (%.0f, %.0f)" % [p.name, p.position.x, p.position.z])
	var d := t.task_distance_m()
	check(d > 10000.0 and d < 25000.0, "дистанция задания разумная: %.0f м" % d)
	check(t.start_gates_s.size() == 3, "три стартовых окна")


func test_ongudai_demo_inside_detail_area() -> void:
	var c := ONGUDAI_FALLBACK
	var half := DETAIL_HALF_M
	if FileAccess.file_exists(ONGUDAI_CFG):
		var loc: Dictionary = Config.get_config("locations/ongudai")
		c = Vector2(float(loc.center_lat), float(loc.center_lon))
		for layer: Dictionary in loc.get("dem", {}).get("layers", []):
			if String(layer.id) == "detail":
				half = float(layer.size_km) * 500.0
	var fn := func(lat: float, lon: float) -> Vector2:
		return TerrainGeo.latlon_to_local(lat, lon, c.x, c.y)
	var t := Task.load_config("ongudai_demo", fn)
	check(t.errors.is_empty(), "без ошибок: %s" % [t.errors])
	check(t.goal_index == t.points.size() - 1 and t.sss_index == 1, "старт и гоул")
	for p in t.points:
		var inside := absf(p.position.x) + p.radius_m < half
		inside = inside and absf(p.position.z) + p.radius_m < half
		check(inside, "%s в детальной зоне (%.0f, %.0f)" % [p.name, p.position.x, p.position.z])
	var d := t.task_distance_m()
	check(d > 15000.0 and d < 40000.0, "дистанция задания разумная: %.0f м" % d)
	approx(t.takeoff_heading_deg, 180.0, 0.01, "курс взлёта")


func test_altai_demo_start_matches_site() -> void:
	var t := Task.load_config("altai_demo", H.latlon_fn())
	var loc: Dictionary = Config.get_config("locations/altai")
	var site: Dictionary = {}
	for s: Dictionary in loc.start_sites:
		if String(s.id) == t.start_site:
			site = s
	check(not site.is_empty(), "стартовая площадка существует")
	var p := H.latlon_fn().call(float(site.lat), float(site.lon)) as Vector2
	approx(p.distance_to(t.points[0].center_2d()), 0.0, 1.0, "взлёт = старт площадки")


func test_xctsk_import() -> void:
	var t := Task.load_file("res://tests/tasks/data/altai_sample.xctsk", H.latlon_fn())
	check(t != null, "файл прочитан")
	if t == null:
		return
	check(t.errors.is_empty(), "без ошибок: %s" % [t.errors])
	check(t.points.size() == 5, "5 пунктов")
	check(t.takeoff_index == 0 and t.sss_index == 1, "TAKEOFF и SSS")
	check(t.ess_index == 3 and t.goal_index == 4, "ESS и гоул (последний)")
	check(t.points[1].exit, "старт на выход")
	approx(t.points[1].radius_m, 3000.0, 0.01, "радиус старта")
	check(t.points[4].is_line, "гоул — линия")
	approx(t.points[4].line_length_m, 400.0, 0.01, "длина линии = 2 × радиус")
	check(t.type == Task.TYPE_RACE, "гонка")
	approx(t.points[2].position.y, 296.0, 0.01, "высота из altSmoothed")
	# окна 08:00 и 08:20 UTC; полёт начинается за start_lead_s (1200 с) до первого
	var lead := float(Config.value("tasks/settings", "xctsk.start_lead_s"))
	check(t.start_gates_s.size() == 2, "два окна")
	approx(t.start_gates_s[0], lead, 0.01, "первое окно")
	approx(t.start_gates_s[1], lead + 1200.0, 0.01, "второе окно")
	approx(t.clock_origin_s, 8.0 * 3600.0 - lead, 0.01, "часы начала полёта")
	approx(t.deadline_s, 4.0 * 3600.0 + lead, 0.01, "крайний срок 12:00")
	var souzga := H.latlon_fn().call(51.88655, 85.8494) as Vector2
	approx(t.points[2].center_2d().distance_to(souzga), 0.0, 0.5, "координаты пункта")


func test_xctsk_time_parse() -> void:
	approx(XctskImporter.parse_time('"12:30:15Z"'), 45015.0, 0.001, "с кавычками")
	approx(XctskImporter.parse_time("07:05:00Z"), 25500.0, 0.001, "без кавычек")
	check(is_nan(XctskImporter.parse_time("")), "пусто → NAN")


func test_xctsk_elapsed_enter() -> void:
	var text := (
		JSON
		. stringify(
			{
				"taskType": "CLASSIC",
				"version": 1,
				"turnpoints":
				[
					{
						"type": "SSS",
						"radius": 5000,
						"waypoint": {"name": "S", "lat": 51.9, "lon": 85.9}
					},
					{"radius": 400, "waypoint": {"name": "G", "lat": 51.8, "lon": 85.8}},
				],
				"sss": {"type": "ELAPSED-TIME", "direction": "ENTER", "timeGates": ["10:00:00Z"]},
				"goal": {"type": "CYLINDER"},
			}
		)
	)
	var d := XctskImporter.parse(text, Config.get_config("tasks/settings"))
	var t := Task.from_dict(d, H.latlon_fn())
	check(t.type == Task.TYPE_ELAPSED, "elapsed")
	check(not t.points[0].exit, "старт на вход")
	check(t.goal_index == 1 and not t.points[1].is_line, "гоул-цилиндр")


func test_bad_task_reports_errors() -> void:
	var t := Task.from_dict(
		{"type": "nonsense", "turnpoints": [{"name": "A", "lat": 51.9, "lon": 85.9}]}
	)
	check(not t.errors.is_empty(), "ошибки: неизвестный тип, нет перевода lat/lon, нет гоула")


func test_list_available() -> void:
	var ids := []
	for e in Task.list_available("user://nonexistent_tasks_dir"):
		ids.append(e.id)
	check("altai_demo" in ids and "ongudai_demo" in ids, "демо в списке")
	check(not ("settings" in ids) and not ("training_spot_landing" in ids), "без служебных")
