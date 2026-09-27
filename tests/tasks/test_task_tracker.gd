extends TestCase
## Прохождение задания: цилиндры с допуском, старт до открытия, ESS, гоул, посадка.

const H := preload("res://tests/tasks/task_helpers.gd")


## Взлёт (0,0), старт на выход r 2000 (окно 100 с), пункт (0,−10000) r 1000, гоул (0,−20000) r 400.
func _task(gates: Array = [100.0], type: String = "race") -> Task:
	return (
		H
		. make_task(
			[
				["takeoff", 0, 0, 400],
				["sss", 0, 0, 2000, "exit"],
				["turnpoint", 0, -10000, 1000],
				["goal", 0, -20000, 400],
			],
			gates,
			type
		)
	)


func _tracker(t: Task) -> TaskTracker:
	var tr := TaskTracker.new()
	tr.setup(t)
	return tr


func test_start_before_open_not_counted() -> void:
	var tr := _tracker(_task([100.0]))
	var starts := []
	tr.start_taken.connect(func(s: float) -> void: starts.append(s))
	var h := 1000.0
	# вылет из стартового цилиндра на 30-й секунде — окно ещё закрыто
	var t_end := H.fly(tr, Vector3(0, h, 0), Vector3(0, h, -2500), 0.0, 60.0)
	check(starts.is_empty(), "ранний старт не засчитан")
	check(tr.phase == TaskTracker.Phase.PRE_START, "всё ещё до старта")
	check(bool(tr.get_state().early_start), "отмечен ранний старт")
	# пункт не засчитывается без старта
	t_end = H.fly(tr, Vector3(0, h, -2500), Vector3(0, h, -9500), t_end, 60.0)
	check(tr.reached.size() == 0, "без старта пункты не берутся")
	# вернулся в цилиндр и вышел после открытия — старт по окну 100 с
	t_end = H.fly(tr, Vector3(0, h, -9500), Vector3(0, h, -1000), t_end, 60.0)
	t_end = H.fly(tr, Vector3(0, h, -1000), Vector3(0, h, -3000), t_end, 20.0)
	check(starts.size() == 1, "старт засчитан после открытия")
	approx(tr.start_time_s, 100.0, 0.001, "гонка: время старта = окно")


func test_elapsed_start_uses_own_time() -> void:
	var tr := _tracker(_task([100.0], "elapsed"))
	H.fly(tr, Vector3(0, 1000, 0), Vector3(0, 1000, -3000), 200.0, 30.0)
	check(not is_nan(tr.start_time_s), "старт взят")
	# пересечение r·(1−0.005) = 1990 м при z = −1990 → t = 200 + 30·1990/3000 ≈ 219.9
	approx(tr.start_time_s, 220.0, 1.01, "своё время пересечения")


func test_cylinder_tolerance() -> void:
	var t := _task([0.0])
	var tr := _tracker(t)
	H.fly(tr, Vector3(0, 1000, 0), Vector3(0, 1000, -2500), 0.0, 10.0)
	# пункт (0,−10000) r 1000: край на z = −9000; допуск 0.5 % → засчитывается с −8995
	H.fly(tr, Vector3(0, 1000, -2500), Vector3(0, 1000, -8996), 10.0, 60.0)
	check(tr.reached.has(2), "в пределах допуска (4 м до края) — взят")
	var tr2 := _tracker(t)
	H.fly(tr2, Vector3(0, 1000, 0), Vector3(0, 1000, -2500), 0.0, 10.0)
	H.fly(tr2, Vector3(0, 1000, -2500), Vector3(0, 1000, -8990), 10.0, 60.0)
	check(not tr2.reached.has(2), "за допуском (10 м до края) — не взят")


## Малый цилиндр: полоса допуска не меньше min_tolerance_m (5 м), а не 0.5 % (2 м).
func test_min_tolerance_band() -> void:
	var t := H.make_task(
		[["takeoff", 0, 0, 400], ["turnpoint", 0, -5000, 400], ["goal", 0, -9000, 400]]
	)
	var tr := _tracker(t)
	H.fly(tr, Vector3(0, 900, 0), Vector3(0, 900, -4596), 0.0, 100.0)
	check(tr.reached.has(1), "4 м до края r 400 — взят (полоса 5 м)")
	var tr2 := _tracker(t)
	H.fly(tr2, Vector3(0, 900, 0), Vector3(0, 900, -4594), 0.0, 100.0)
	check(not tr2.reached.has(1), "6 м до края — не взят")


## Вылет из стартового цилиндра на выход с допуском: засчитывается на r·(1 − допуск).
func test_exit_tolerance() -> void:
	var tr := _tracker(_task([0.0]))
	H.fly(tr, Vector3(0, 1000, 0), Vector3(0, 1000, -1985), 0.0, 10.0)
	check(is_nan(tr.start_time_s), "1985 м < 1990 — ещё внутри")
	H.fly(tr, Vector3(0, 1000, -1985), Vector3(0, 1000, -1991), 10.0, 1.0)
	check(not is_nan(tr.start_time_s), "1991 м ≥ 1990 — старт")


func test_full_task_to_goal() -> void:
	var tr := _tracker(_task([0.0]))
	var got := {"tp": [], "ess": 0, "goal": {}}
	tr.turnpoint_reached.connect(func(i: int, _n: String, _s: float) -> void: got.tp.append(i))
	tr.ess_reached.connect(func(_s: float) -> void: got.ess += 1)
	tr.goal_reached.connect(func(r: Dictionary) -> void: got.goal = r)
	approx(tr.task_distance_m, 19600.0, 0.5, "дистанция задания")
	var t_end := H.fly(tr, Vector3(0, 2000, 0), Vector3(0, 2000, -10000), 0.0, 1000.0)
	approx(tr.remaining_distance_m, 9600.0, 1.0, "осталось от центра пункта")
	t_end = H.fly(tr, Vector3(0, 2000, -10000), Vector3(0, 800, -19700), t_end, 970.0)
	check(got.tp == [2, 3], "пункт и гоул: %s" % [got.tp])
	check(got.ess == 1, "ESS = гоул")
	check(tr.phase == TaskTracker.Phase.GOAL, "гоул")
	var r: Dictionary = got.goal
	check(bool(r.made_goal), "made_goal")
	approx(r.distance_m, 19600.0, 0.5, "дистанция = дистанция задания")
	# гоул r 400 + max(2, 5 м) = 405 → z = −19595 на отрезке −10000…−19700 за 970 с
	approx(r.speed_section_time_s, 1000.0 + 970.0 * 9595.0 / 9700.0, 1.5, "время")


func test_landing_fails_with_distance() -> void:
	var tr := _tracker(_task([0.0]))
	var failed := []
	tr.task_failed.connect(func(r: Dictionary) -> void: failed.append(r))
	var t_end := H.fly(tr, Vector3(0, 1500, 0), Vector3(0, 300, -12000), 0.0, 1200.0)
	tr.update(H.telem(Vector3(0, 300, -12000), t_end + 1.0, "landed"))
	check(failed.size() == 1, "task_failed при посадке")
	var r: Dictionary = failed[0]
	check(String(r.status) == "landed", "причина — посадка")
	# лучшая оставшаяся: от (0,−12000) до края гоула 7600 → пройдено 19600 − 7600
	approx(r.distance_m, 12000.0, 1.0, "пройденная дистанция")
	check(not bool(r.made_goal), "не в гоуле")


func test_required_glide() -> void:
	var t := _task([0.0])
	t.points[3].position.y = 300.0
	var tr := _tracker(t)
	H.fly(tr, Vector3(0, 1450, 0), Vector3(0, 1450, -10000), 0.0, 100.0)
	# осталось 9600 м, высота над гоулом 1450 − 300 − 150 (запас) = 1000 → 9.6
	approx(tr.required_glide, 9.6, 0.01, "требуемое качество")
	approx(tr.distance_to_next_m, 9600.0, 1.0, "до края гоула")


func test_goal_line_direction() -> void:
	var t := H.make_task(
		[["takeoff", 0, 0, 400], ["turnpoint", 0, -5000, 400], ["goal", 0, -10000, 200]], [], "race"
	)
	t.points[2].is_line = true
	var tr := _tracker(t)
	H.fly(tr, Vector3(0, 900, 0), Vector3(0, 900, -9900), 0.0, 500.0)
	check(tr.phase != TaskTracker.Phase.GOAL, "до линии — не гоул")
	H.fly(tr, Vector3(0, 900, -9900), Vector3(50, 900, -10100), 500.0, 20.0)
	check(tr.phase == TaskTracker.Phase.GOAL, "пересёк линию по направлению плеча")


func test_restart_updates_start() -> void:
	var tr := _tracker(_task([100.0, 400.0]))
	var t_end := H.fly(tr, Vector3(0, 1000, 0), Vector3(0, 1000, -2500), 150.0, 20.0)
	approx(tr.start_time_s, 100.0, 0.001, "первое окно")
	t_end = H.fly(tr, Vector3(0, 1000, -2500), Vector3(0, 1000, -500), 420.0, 30.0)
	H.fly(tr, Vector3(0, 1000, -500), Vector3(0, 1000, -2500), t_end, 20.0)
	approx(tr.start_time_s, 400.0, 0.001, "перестарт во втором окне")


func test_instrument_points() -> void:
	var t := _task()
	var pts := t.instrument_points()
	check(pts.size() == 3, "без взлёта")
	check(pts[0].has("position") and pts[0].has("radius_m") and pts[0].has("name"), "формат")
	var tr := _tracker(t)
	check(tr.instrument_active_index() == 0, "активный — старт")
