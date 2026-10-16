extends TestCase
## GoalTracker (GL-К3): все восемь целей, построение возврата и треугольника, ведущий маршрут.

const H := preload("res://tests/goals/goal_helpers.gd")


func _status(g: GoalTracker, i: int) -> String:
	return String(g.items()[i].status)


func _g(kind: String, value: float, level: String = "medium", task: String = "") -> Dictionary:
	return GoalSpec.make(kind, level, value, task)


# --- простые цели ---


func test_height_hold() -> void:
	var g := H.make([_g("height", 300.0)])
	var done := []
	g.goal_done.connect(func(i: int) -> void: done.append(i))
	# заброс на 5 с не считается
	H.fly(g, H.START, H.START + Vector3(0, 320, 0), 0.0, 2.0)
	H.fly(g, H.START + Vector3(0, 320, 0), H.START + Vector3(0, 100, 0), 2.0, 3.0)
	check(_status(g, 0) == "pending", "кратковременный заброс не засчитан")
	# набор и удержание 12 с
	H.fly(g, H.START + Vector3(0, 100, 0), H.START + Vector3(0, 310, 0), 5.0, 5.0)
	check(_status(g, 0) == "pending", "ещё не удержан")
	H.fly(g, H.START + Vector3(0, 310, 0), H.START + Vector3(0, 320, 0), 10.0, 12.0)
	check(_status(g, 0) == "done", "удержан 10 с")
	check(done == [0], "сигнал goal_done один раз: %s" % [done])
	check(float(g.items()[0].best) >= 300.0, "best ≥ цели")


func test_height_best_held_value() -> void:
	var g := H.make([_g("height", 1000.0)])
	H.fly(g, H.START, H.START + Vector3(0, 200, 0), 0.0, 5.0)
	H.fly(g, H.START + Vector3(0, 200, 0), H.START + Vector3(0, 200, 0), 5.0, 10.0)
	approx(float(g.items()[0].best), 200.0, 1.0, "лучший удержанный набор")
	approx(float(g.items()[0].current), 200.0, 0.01, "текущий набор")


func test_duration() -> void:
	var g := H.make([_g("duration", 120.0)])
	g.update(H.telem(H.START, 0.0, "running"))
	check(float(g.items()[0].current) == 0.0, "на разбеге время не идёт")
	H.fly(g, H.START, H.START + H.at(0, 500), 10.0, 100.0)
	check(_status(g, 0) == "pending", "110 с < 120 с")
	H.fly(g, H.START + H.at(0, 500), H.START + H.at(0, 800), 110.0, 30.0)
	check(_status(g, 0) == "done", "время в воздухе ≥ цели")


func test_distance_uses_best() -> void:
	var g := H.make([_g("distance", 3000.0)])
	H.fly(g, H.START, H.at(90, 2500), 0.0, 100.0)
	H.fly(g, H.at(90, 2500), H.at(90, 1000), 100.0, 50.0)
	check(_status(g, 0) == "pending", "ещё не 3 км")
	approx(float(g.items()[0].current), 1000.0, 1.0, "сейчас")
	approx(float(g.items()[0].best), 2500.0, 1.0, "наибольшее")
	H.fly(g, H.at(90, 1000), H.at(0, 3100), 150.0, 100.0)
	check(_status(g, 0) == "done", "дальность достигнута")


func test_after_landing_pending_fails() -> void:
	var g := H.make([_g("height", 500.0), _g("duration", 600.0), _g("distance", 9000.0)])
	var failed := []
	g.goal_failed.connect(func(i: int) -> void: failed.append(i))
	H.fly(g, H.START, H.at(0, 800), 0.0, 60.0)
	g.update(H.telem(H.at(0, 800), 61.0, "landed"))
	g.on_landed({"grade": "soft"})
	for i in 3:
		check(_status(g, i) == "failed", "цель %d провалена" % i)
	check(failed == [0, 1, 2], "сигналы goal_failed: %s" % [failed])
	var r := g.result()
	check(r.done == 0 and r.total == 3, "итог 0 из 3")
	# после посадки телеметрия ничего не меняет
	g.update(H.telem(H.at(0, 20000), 70.0))
	check(_status(g, 2) == "failed", "после посадки не оживает")


# --- посадка ---


func test_landing_in_circle() -> void:
	var g := H.make([_g("landing", 50.0)], {"landing_target": Vector3(1000, 1000, 0)})
	H.fly(g, H.START, Vector3(1020, 1000, 10), 0.0, 20.0)
	g.update(H.telem(Vector3(1020, 1000, 10), 21.0, "landed"))
	g.on_landed({"grade": "hard"})
	check(_status(g, 0) == "done", "в круге, жёсткая — засчитана")
	approx(float(g.items()[0].current), Vector2(20, 10).length(), 0.01, "расстояние до центра")


func test_landing_miss_and_crash() -> void:
	var tg := {"landing_target": Vector3(1000, 1000, 0)}
	var g := H.make([_g("landing", 50.0)], tg)
	H.fly(g, H.START, Vector3(500, 1000, 0), 0.0, 20.0)
	g.on_landed({"grade": "soft"})
	check(_status(g, 0) == "failed", "мимо круга")
	var g2 := H.make([_g("landing", 50.0)], tg)
	H.fly(g2, H.START, Vector3(1000, 1000, 0), 0.0, 20.0)
	g2.on_landed({"grade": "crash"})
	check(_status(g2, 0) == "failed", "авария в круге не засчитывается")


func test_landing_unavailable_without_target() -> void:
	var g := H.make([_g("landing", 50.0), _g("duration", 10.0)])
	var it: Dictionary = g.items()[0]
	check(it.status == "unavailable" and it.reason != "", "нет круга — unavailable с причиной")
	H.fly(g, H.START, H.at(0, 100), 0.0, 20.0)
	check(_status(g, 1) == "done", "остальные не страдают")
	g.on_landed({"grade": "soft"})
	check(_status(g, 0) == "unavailable", "после посадки остаётся unavailable")
	var r := g.result()
	check(r.total == 1 and r.done == 1, "unavailable не в итоге: %s/%s" % [r.done, r.total])


# --- возврат ---


func test_return_geometry_into_wind() -> void:
	var g := H.make([_g("return", 6000.0)], {"wind_ms": 5.0, "wind_from_deg": 90.0})
	var pts := g.world_points()
	check(pts.size() == 2, "пункт и гоул: %d" % pts.size())
	var tp: Dictionary = pts[0]
	approx(tp.position.x, 6000.0, 0.5, "пункт на востоке (ветер с востока)")
	approx(tp.position.z, 0.0, 0.5, "z")
	approx(tp.position.y, H.GROUND, 0.01, "высота земли из height_fn")
	approx(tp.radius_m, 400.0, 0.01, "радиус пункта")
	var home: Dictionary = pts[1]
	approx(Vector2(home.position.x, home.position.z).length(), 0.0, 0.5, "гоул у взлёта")
	check(bool(tp.active) and not bool(home.active), "активен первый пункт")


func test_return_weak_wind_uses_start_heading() -> void:
	var g := H.make(
		[_g("return", 4000.0)], {"wind_ms": 0.5, "wind_from_deg": 90.0, "start_heading_deg": 180.0}
	)
	var tp: Dictionary = g.world_points()[0]
	approx(tp.position.x, 0.0, 0.5, "x")
	approx(tp.position.z, 4000.0, 0.5, "пункт на юге по курсу старта")


func test_return_flight() -> void:
	var g := H.make([_g("return", 5000.0)], {"wind_ms": 4.0, "wind_from_deg": 0.0})
	var t := H.fly(g, H.START, H.at(0, 5000), 0.0, 400.0)
	check(_status(g, 0) == "pending", "до возврата не засчитана")
	check(float(g.items()[0].current) == 1.0, "пункт взят")
	check(int(g.instrument_state().next_index) == 2, "активен гоул")
	H.fly(g, H.at(0, 5000), H.at(0, 100), t, 400.0)
	check(_status(g, 0) == "done", "вернулся в цилиндр у взлёта")


func test_return_unavailable_when_not_fitting() -> void:
	var g := H.make(
		[_g("return", 9000.0), _g("duration", 10.0)], {"bounds": Rect2(-3000, -3000, 6000, 6000)}
	)
	check(_status(g, 0) == "unavailable", "не помещается ни при каком повороте")
	check(g.lead_tracker() == null, "ведущего нет")
	check(g.instrument_points().is_empty() and g.instrument_state().is_empty(), "прибор пуст")
	check(g.instrument_active_index() == -1 or g.instrument_active_index() == 0, "индекс без маршрута")
	check(g.world_points().is_empty(), "цилиндров нет")


func test_return_rotates_to_fit() -> void:
	# узкая полоса вдоль широты: на восток поместится, на север нет
	var bounds := Rect2(-8000, -1500, 16000, 3000)
	var g := H.make(
		[_g("return", 5000.0)], {"wind_ms": 5.0, "wind_from_deg": 0.0, "bounds": bounds}
	)
	check(_status(g, 0) == "pending", "найден поворот")
	var tp: Dictionary = g.world_points()[0]
	check(absf(tp.position.z) <= 500.0, "пункт у оси полосы, z=%.0f" % tp.position.z)
	approx(Vector2(tp.position.x, tp.position.z).length(), 5000.0, 0.5, "расстояние сохранено")


# --- треугольник ---


func test_triangle_equilateral() -> void:
	var g := H.make([_g("triangle", 9000.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0})
	var pts := g.world_points()
	check(pts.size() == 3, "два пункта и гоул")
	var a := Vector2(pts[0].position.x, pts[0].position.z)
	var b := Vector2(pts[1].position.x, pts[1].position.z)
	approx(a.length(), 3000.0, 0.5, "сторона 1")
	approx(b.length(), 3000.0, 0.5, "сторона 3")
	approx(a.distance_to(b), 3000.0, 0.5, "сторона 2")
	approx(a.y, -3000.0, 0.5, "первое плечо против ветра (на север)")
	var tr := g.lead_tracker()
	check(tr.task_distance_m > 6000.0 and tr.task_distance_m < 9000.0, "оптимизированная дистанция меньше периметра")


func test_triangle_flight_done() -> void:
	var g := H.make([_g("triangle", 9000.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0})
	var pts := g.world_points()
	var a: Vector3 = pts[0].position + Vector3(0, 400, 0)
	var b: Vector3 = pts[1].position + Vector3(0, 400, 0)
	var t := H.fly(g, H.START, a, 0.0, 300.0)
	t = H.fly(g, a, b, t, 300.0)
	check(_status(g, 0) == "pending", "ещё не вернулся")
	check(float(g.items()[0].current) == 2.0, "два пункта")
	H.fly(g, b, H.START, t, 300.0)
	check(_status(g, 0) == "done", "треугольник облетел")
	check(g.result().route.made_goal, "в итоге маршрут: гоул")


func test_triangle_unavailable_small_zone() -> void:
	var g := H.make([_g("triangle", 30000.0)], {"bounds": Rect2(-5000, -5000, 10000, 10000)})
	check(_status(g, 0) == "unavailable", "треугольник 30 км в зону 10 км не лезет")


# --- ведущий маршрут и route ---


func test_lead_order_and_switch() -> void:
	var g := H.make(
		[_g("return", 3000.0), _g("triangle", 6000.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0}
	)
	var lead := g.lead_tracker()
	check(lead != null and lead.task.id == "goal_triangle", "первым ведёт triangle")
	# облёт возврата (север 3 км и обратно) — triangle ещё не закрыт
	var up := H.at(0, 3000, 1400.0)
	var t := H.fly(g, H.START, up, 0.0, 300.0)
	t = H.fly(g, up, H.START, t, 300.0)
	check(_status(g, 0) == "done", "возврат засчитан")
	check(g.lead_tracker().task.id == "goal_triangle", "треугольник всё ещё ведёт")


func test_lead_switches_to_next_after_goal() -> void:
	var g := H.make(
		[_g("return", 3000.0), _g("triangle", 6000.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0}
	)
	var pts := g.world_points()  # ведёт triangle
	var a: Vector3 = pts[0].position + Vector3(0, 300, 0)
	var b: Vector3 = pts[1].position + Vector3(0, 300, 0)
	var t := H.fly(g, H.START, a, 0.0, 200.0)
	t = H.fly(g, a, b, t, 200.0)
	H.fly(g, b, H.START, t, 200.0)
	check(_status(g, 1) == "done", "треугольник облетел")
	check(g.lead_tracker().task.id == "goal_return", "ведущим стал возврат")


func test_route_from_config() -> void:
	var ids := []
	for e in Task.list_available():
		ids.append(String(e.id))
	if ids.is_empty():
		return
	var g := H.make([_g("route", 0.0, "medium", ids[0])])
	var it: Dictionary = g.items()[0]
	check(it.status in ["pending", "unavailable"], "статус определён")
	if it.status == "pending":
		check(String(it.task_name) != "", "имя задания в элементе")
		check(g.lead_tracker() != null, "ведущий маршрут есть")


func test_route_bad_task_unavailable() -> void:
	var g := H.make([_g("route", 0.0, "medium", "no_such_task_xyz"), _g("duration", 5.0)])
	check(_status(g, 0) == "unavailable", "несуществующее задание")
	check(String(g.items()[0].reason) != "", "причина указана")
	H.fly(g, H.START, H.at(0, 50), 0.0, 10.0)
	check(_status(g, 1) == "done", "остальные работают")


func test_route_from_file() -> void:
	var path := "user://gl2_test_task.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		JSON.stringify(
			{
				"id": "gl2",
				"name": "Файловый",
				"turnpoints":
				[
					{"type": "takeoff", "x_m": 0, "z_m": 0, "radius_m": 200},
					{"type": "turnpoint", "x_m": 0, "z_m": -2000, "radius_m": 300},
					{"type": "goal", "x_m": 2000, "z_m": -2000, "radius_m": 300}
				]
			}
		)
	)
	f.close()
	var g := H.make([_g("route", 0.0, "medium", path)])
	DirAccess.remove_absolute(path)
	check(_status(g, 0) == "pending", "загружено: %s" % g.items()[0].reason)
	check(g.items()[0].task_name == "Файловый", "имя задания")
	var t := H.fly(g, H.START, H.at(0, 2000, 1300.0), 0.0, 200.0)
	H.fly(g, H.at(0, 2000, 1300.0), Vector3(2000, 1300, -2000), t, 200.0)
	check(_status(g, 0) == "done", "маршрут пройден")
	check(g.instrument_points().size() == 2, "точки прибора без взлёта")


# --- speed ---


func test_speed_in_time() -> void:
	var g := H.make(
		[_g("return", 2000.0), _g("speed", 600.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0}
	)
	var t := H.fly(g, H.START, H.at(0, 2000), 0.0, 200.0)
	check(_status(g, 1) == "pending", "идёт")
	check(float(g.items()[1].current) > 100.0, "время с начала маршрута")
	H.fly(g, H.at(0, 2000), H.at(0, 50), t, 200.0)
	check(_status(g, 0) == "done" and _status(g, 1) == "done", "вовремя: обе done")


func test_speed_too_slow_fails_immediately() -> void:
	var g := H.make(
		[_g("return", 2000.0), _g("speed", 300.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0}
	)
	var failed := []
	g.goal_failed.connect(func(i: int) -> void: failed.append(i))
	H.fly(g, H.START, H.at(0, 1500), 0.0, 400.0)
	check(_status(g, 1) == "failed", "время вышло до гоула")
	check(failed == [1], "один сигнал")
	check(_status(g, 0) == "pending", "возврат продолжается")


func test_speed_unavailable_without_route() -> void:
	var g := H.make([_g("speed", 300.0)])
	check(_status(g, 0) == "unavailable", "без маршрута нечего мерить")


func test_speed_judges_leading_route_finish() -> void:
	# гоул уложился в срок, хотя к моменту проверки ведущим становится следующий маршрут
	var g := H.make(
		[_g("return", 2000.0), _g("triangle", 6000.0), _g("speed", 900.0)],
		{"wind_ms": 3.0, "wind_from_deg": 0.0}
	)
	var pts := g.world_points()
	var a: Vector3 = pts[0].position
	var b: Vector3 = pts[1].position
	var t := H.fly(g, H.START, a, 0.0, 150.0)
	t = H.fly(g, a, b, t, 150.0)
	H.fly(g, b, H.START, t, 150.0)
	check(_status(g, 1) == "done", "треугольник")
	check(_status(g, 2) == "done", "speed: %s" % g.items()[2])


func test_speed_counts_to_ess() -> void:
	var path := "user://gl2_ess_task.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		JSON.stringify(
			{
				"id": "gl2e",
				"name": "С ESS",
				"turnpoints":
				[
					{"type": "takeoff", "x_m": 0, "z_m": 0, "radius_m": 200},
					{"type": "ess", "x_m": 0, "z_m": -2000, "radius_m": 300},
					{"type": "goal", "x_m": 0, "z_m": -4000, "radius_m": 300}
				]
			}
		)
	)
	f.close()
	var g := H.make([_g("route", 0.0, "medium", path), _g("speed", 250.0)])
	DirAccess.remove_absolute(path)
	check(_status(g, 0) == "pending", "загружено")
	# до ESS 200 с (в срок), до гоула ещё 400 с (за срок)
	var t := H.fly(g, H.START, H.at(0, 2000, 1300.0), 0.0, 200.0)
	check(_status(g, 1) == "pending", "на ESS без гоула ещё pending")
	H.fly(g, H.at(0, 2000, 1300.0), H.at(0, 4000, 1300.0), t, 400.0)
	check(_status(g, 1) == "done", "гоул взят, время до ESS в пределе")
	var g2 := H.make([_g("return", 2000.0), _g("speed", 600.0)], {"wind_ms": 3.0, "wind_from_deg": 0.0})
	H.fly(g2, H.START, H.at(0, 2000), 0.0, 100.0)
	g2.update(H.telem(H.at(0, 2000), 101.0, "landed"))
	g2.on_landed({"grade": "soft"})
	check(_status(g2, 1) == "failed", "посадка без гоула — failed")


# --- сброс и состояние ---


func test_reset_new_attempt() -> void:
	var g := H.make([_g("duration", 30.0), _g("return", 2000.0)], {"wind_from_deg": 0.0, "wind_ms": 3.0})
	H.fly(g, H.START, H.at(0, 100), 0.0, 40.0)
	g.on_landed({"grade": "soft"})
	check(_status(g, 0) == "done" and _status(g, 1) == "failed", "после посадки")
	g.reset()
	check(_status(g, 0) == "pending" and _status(g, 1) == "pending", "reset: pending")
	check(float(g.items()[0].current) == 0.0, "счётчики обнулены")
	check(g.world_points().size() == 2, "точки те же")
	H.fly(g, H.START, H.at(0, 100), 100.0, 40.0)
	check(_status(g, 0) == "done", "вторая попытка засчитывается")


func test_result_structure() -> void:
	var g := H.make([_g("duration", 10.0), _g("height", 99999.0)])
	H.fly(g, H.START, H.at(0, 100), 0.0, 20.0)
	var r := g.result()
	check(r.goals.size() == 2 and r.done == 1 and r.total == 2, "done/total")
	check(r.route.is_empty(), "маршрута нет — route пуст")
	check(g.lead_tracker() == null, "ведущего нет")


func test_empty_goals() -> void:
	var g := H.make([])
	g.update(H.telem(H.START, 0.0))
	check(g.items().is_empty() and g.result().total == 0, "без целей — пусто")


func test_unknown_kind_unavailable() -> void:
	var g := H.make([{"kind": "wow", "level": "easy", "value": 1.0, "task": ""}])
	check(_status(g, 0) == "unavailable", "неизвестный вид")


func test_config_keys() -> void:
	var c: Dictionary = Config.get_config("goals/tracker")
	check(float(c.height.hold_s) == 10.0, "hold_s")
	for k: String in ["min_wind_ms", "turnpoint_radius_m", "home_radius_m", "rotate_step_deg", "bounds_margin_m"]:
		check(c.route.has(k), "ключ route.%s" % k)
