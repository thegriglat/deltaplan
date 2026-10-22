extends TestCase
## SnowPlumeModel (SNW-К1/К3): рассрочка, бюджет ветра, пересканирование, ветер вдоль гребня, спуск потока.
## Рельеф — гребень вдоль Z (x = 0, склоны ≈39°). Числа порога — тестовые.

const CAM := Vector3(-1500.0, 3600.0, 0.0)

var _calls := 0
var _max_frame_calls := 0


func _cfg() -> Dictionary:
	return {
		"radius_m": 3000.0, "max_emitters": 6, "update_s": 0.5, "max_wind_samples": 80,
		"scan_step_m": 50.0, "scan_points_per_frame": 500, "rescan_m": 1000.0, "rescan_dir_deg": 10.0,
		"fetch_m": 200.0, "lee_slope_deg": 15.0, "spacing_m": 150.0, "surf_upwind_m": 30.0, "snow_min": 0.5,
		"start_agl_m": 2.0, "min_agl_m": 3.0, "path_points": 6, "path_dt_s": 8.0, "span_ms": 8.0,
		"threshold": {"a": 9.0, "b": 0.0, "c": 0.0, "wet_t_c": 0.0, "wet_u10_ms": 12.0},
	}


func _ridge(x: float, _z: float) -> float:
	_calls += 1
	return 3000.0 + maxf(0.0, 500.0 - absf(x) * 0.8)


func _flat(_x: float, _z: float) -> float:
	_calls += 1
	return 3000.0


func _model(hf: Callable, wind: Callable, cfg: Dictionary = {}) -> SnowPlumeModel:
	return SnowPlumeModel.new(_cfg() if cfg.is_empty() else cfg, hf,
			func(_x: float, _z: float) -> float: return 1.0, wind, func(_t: float) -> float: return -10.0)


func _const_wind(v: Vector3) -> Callable:
	return func(_p: Vector3) -> Vector3: return v


func _run(m: SnowPlumeModel, cam: Vector3, frames: int) -> Array:
	var out: Array = []
	for i in frames:
		out = m.update(cam, 1.0 / 60.0)
	return out


func test_scan_budget_per_frame() -> void:
	var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)))
	var worst := 0
	for i in 400:
		m.update(CAM, 1.0 / 60.0)
		worst = maxi(worst, m.scan_calls_last())
	check(worst > 0, "скан шёл")
	check(worst <= 500, "за кадр не больше scan_points_per_frame вызовов, было %d" % worst)
	check(m.scan_count() == 1, "один скан при неподвижной камере и ветре")
	check(not _run(m, CAM, 60).is_empty(), "после скана источники есть")


func test_wind_budget() -> void:
	var cfg := _cfg()
	cfg.max_wind_samples = 20
	cfg.max_emitters = 24
	var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)), cfg)
	var list := _run(m, CAM, 600)
	check(m.wind_calls_last() <= 20, "вызовов ветра %d <= 20" % m.wind_calls_last())
	check(not list.is_empty() and list.size() <= 3, "при бюджете 20 источников 1..3, было %d" % list.size())


func test_rescan_on_move_and_turn() -> void:
	var wind := {"v": Vector3(15, 0, 0)}
	var m := _model(_ridge, func(_p: Vector3) -> Vector3: return wind.v)
	_run(m, CAM, 600)
	check(m.scan_count() == 1, "первый скан")
	_run(m, CAM + Vector3(300, 0, 0), 120)
	check(m.scan_count() == 1, "сдвиг 300 м < rescan_m — без пересканирования")
	_run(m, CAM + Vector3(0, 0, 1500), 120)
	check(m.scan_count() == 2, "сдвиг 1500 м > rescan_m — новый скан")
	wind.v = Vector3(15, 0, 15 * tan(deg_to_rad(5.0)))
	_run(m, CAM + Vector3(0, 0, 1500), 120)
	check(m.scan_count() == 2, "поворот 5° < rescan_dir_deg — без пересканирования")
	wind.v = Vector3(15, 0, 15 * tan(deg_to_rad(20.0)))
	_run(m, CAM + Vector3(0, 0, 1500), 120)
	check(m.scan_count() == 3, "поворот 20° > rescan_dir_deg — новый скан")


func test_old_list_until_new_scan_done() -> void:
	var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)))
	var before := _run(m, CAM, 600)
	check(not before.is_empty(), "есть список")
	var moved := CAM + Vector3(0, 0, 1200)
	m.update(moved, 0.6)  # список обновился, скан начат, но не закончен
	var during := m.update(moved, 0.6)
	check(m.scan_count() == 2, "скан начат")
	check(not during.is_empty(), "пока скан не готов, отдаётся прежний набор")


func test_surf_points() -> void:
	var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)))
	var list := _run(m, CAM, 600)
	check(not list.is_empty(), "источники есть")
	for e: Dictionary in list:
		var surf: PackedVector3Array = e.surf
		check(surf.size() == 5, "surf: 3 вдоль гребня + 2 на наветренном склоне")
		var p: Vector3 = e.pos
		# ветер вдоль +X: поперёк — Z; наветренный склон — меньше X
		approx(surf[0].z - p.z, -75.0, 1e-3, "−width/2 поперёк")
		approx(surf[2].z - p.z, 75.0, 1e-3, "+width/2 поперёк")
		approx(surf[1].x, p.x, 1e-3, "центр на гребне")
		approx(surf[3].x - p.x, -15.0, 1e-3, "склон на upwind/2 против ветра")
		approx(surf[4].x - p.x, -30.0, 1e-3, "склон на upwind против ветра")
		for s in surf:
			approx(s.y, _ridge(s.x, s.z), 0.01, "surf на рельефе")


func test_scan_not_restarted_by_drift() -> void:
	## SNW-5: пустой список при scan_count 3–4 — скан в работе сбрасывался дрейфом ветра. Теперь не сбрасывается.
	var wind := {"v": Vector3(15, 0, 0)}
	var m := _model(_ridge, func(_p: Vector3) -> Vector3: return wind.v)
	var out: Array = []
	var a := 0.0
	for i in 600:
		a += 0.1  # ветер уходит на 0,1° за кадр: > 10° за время скана
		wind.v = Vector3(15.0 * cos(deg_to_rad(a)), 0.0, 15.0 * sin(deg_to_rad(a)))
		out = m.update(CAM, 1.0 / 60.0)
		if m.scan_count() == 1 and not out.is_empty():
			break
	check(m.scan_count() == 1 and not out.is_empty(), "первый скан дошёл до конца, scan_count=%d" % m.scan_count())


func test_wind_along_ridge() -> void:
	var m := _model(_ridge, _const_wind(Vector3(0, 0, 15)))
	check(_run(m, CAM, 600).is_empty(), "ветер вдоль гребня — гребня-преграды нет")


func test_flat_terrain_empty() -> void:
	var m := _model(_flat, _const_wind(Vector3(15, 0, 0)))
	check(_run(m, CAM, 600).is_empty(), "плоскость — пусто")


func test_downdraft_path_clamped() -> void:
	var wf := func(p: Vector3) -> Vector3:
		return Vector3(15.0, -3.0 if p.x > 0.0 else 0.0, 0.0)
	var m := _model(_ridge, wf)
	var list := _run(m, CAM, 600)
	check(not list.is_empty(), "источники есть")
	for e: Dictionary in list:
		var path: PackedVector3Array = e.path
		var dropped := false
		for i in path.size():
			var q := path[i]
			check(q.y >= _ridge(q.x, q.z) + 3.0 - 0.01, "не ниже рельефа + min_agl_m")
			if i > 0 and q.y < path[0].y - 1.0:
				dropped = true
		check(dropped, "линия тока опускается за гребнем")


func test_ids_unique_and_spacing() -> void:
	var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)))
	var list := _run(m, CAM, 600)
	var seen := {}
	for e: Dictionary in list:
		check(not seen.has(e.id), "id уникальны")
		seen[e.id] = true
	for i in list.size():
		for j in range(i + 1, list.size()):
			var a: Vector3 = list[i].pos
			var b: Vector3 = list[j].pos
			check(Vector2(a.x - b.x, a.z - b.z).length() >= 150.0 - 1e-3, "точки не ближе spacing_m")


func test_cost_report() -> void:
	## Замер (в отчёт): update на кадр, radius 6000, камера летит 30 м/с поперёк рельефа (пересканы раз в ~33 с).
	for budget in [4000, 1000]:
		var cfg := _cfg()
		cfg.radius_m = 6000.0
		cfg.max_emitters = 24
		cfg.max_wind_samples = 160
		cfg.scan_points_per_frame = budget
		var m := _model(_ridge, _const_wind(Vector3(15, 0, 0)), cfg)
		var cam := Vector3(-1500.0, 3600.0, 0.0)
		var sum := 0
		var worst := 0
		var n := 6000
		for i in n:
			cam.z += 0.5
			var t0 := Time.get_ticks_usec()
			m.update(cam, 1.0 / 60.0)
			var dt := Time.get_ticks_usec() - t0
			sum += dt
			worst = maxi(worst, dt)
		print("SNW cost: scan_points_per_frame=%d: update среднее %.1f мкс, максимум %d мкс, сканов %d" % [budget, float(sum) / n, worst, m.scan_count()])
		check(m.scan_count() > 1, "пересканы шли")
