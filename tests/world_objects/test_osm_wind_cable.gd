extends TestCase
## OL-3: ветряки (OsmWindTurbines) и кабинки канатки (OsmCableCars) на синтетических данных.
## Ветер подставляется через L4 (osm_wind с подставным air_fn): разворот навстречу ветру с ограниченной
## скоростью, кривая вращения cut-in/rated/cut-out, угол копится без рывков, один опрос на кластер.

func _cfg() -> Dictionary:
	return Config.get_config("world_objects")


func _flat(_x: float, _z: float) -> float:
	return 100.0


func _wind_data(n: int, spacing: float = 100.0) -> OsmData:
	var d := OsmData.new()
	for i in n:
		d.verticals.append({"t": "wind", "comm": false, "x": 50.0 + i * spacing, "z": 80.0, "h": 80.0})
	return d


func _turbines(n: int, obs: ObstacleIndex = null, spacing: float = 100.0) -> OsmWindTurbines:
	var o := obs if obs != null else ObstacleIndex.new()
	return OsmWindTurbines.build(_wind_data(n, spacing), _cfg(), _flat, o) as OsmWindTurbines


func test_rpm_curve() -> void:
	var w: Dictionary = _cfg().osm_pilot.wind_turbines
	var f := func(v: float) -> float:
		return OsmWindTurbines.rpm_for(v, float(w.cut_in_ms), float(w.rated_ms), float(w.cut_out_ms), float(w.rated_rpm))
	approx(f.call(float(w.cut_in_ms) - 0.1), 0.0, 1e-9, "ниже cut-in стоит")
	approx(f.call(float(w.rated_ms)), float(w.rated_rpm), 1e-9, "номинал при rated")
	approx(f.call(0.5 * (float(w.cut_in_ms) + float(w.rated_ms))), 0.5 * float(w.rated_rpm), 1e-6, "линейно между")
	approx(f.call(float(w.cut_out_ms) - 0.1), float(w.rated_rpm), 1e-9, "номинал до cut-out")
	approx(f.call(float(w.cut_out_ms) + 0.1), 0.0, 1e-9, "выше cut-out стоит")


func test_no_wind_call_stands() -> void:
	var t := _turbines(3)
	check(t != null, "ветряки построены")
	check(t.is_in_group(&"osm_wind"), "L4: узел в группе osm_wind")
	var a0 := t.angle_of(0)
	for i in 300:
		t.step(0.1)
	approx(t.yaw_of(0), 0.0, 1e-9, "без вызова — нос по +X")
	approx(t.omega_of(0), 0.0, 1e-9, "без вызова не крутится")
	approx(t.angle_of(0), a0, 1e-6, "угол не меняется")
	approx(t.hub_position(0).y, 180.0, 1e-3, "ступица на высоте h над землёй")
	t.free()


func test_yaw_rate_and_target() -> void:
	var t := _turbines(1)
	var rate := deg_to_rad(float(_cfg().osm_pilot.wind_turbines.yaw_deg_s))
	# ветер дует на +Z → нос навстречу, т. е. к −Z: угол +90° (Basis(UP, yaw): +X → (cos, 0, −sin))
	t.osm_wind(func(_p: Vector3) -> Vector3: return Vector3(0, 0, 6), Vector3(0, 100, 0))
	var prev := t.yaw_of(0)
	var max_step := 0.0
	for i in 100:
		t.step(0.1)
		max_step = maxf(max_step, absf(t.yaw_of(0) - prev))
		prev = t.yaw_of(0)
	check(max_step <= rate * 0.1 + 1e-6, "скорость рыскания ≤ yaw_deg_s: %.5f" % max_step)
	approx(t.yaw_of(0), minf(rate * 10.0, PI * 0.5), 1e-4, "за 10 с — rate·t")
	for i in 4000:
		t.step(0.1)
	approx(t.yaw_of(0), PI * 0.5, 1e-4, "в итоге нос навстречу ветру")
	var nose := Basis(Vector3.UP, t.yaw_of(0)) * Vector3.RIGHT
	check(nose.dot(Vector3(0, 0, -1)) > 0.999, "нос смотрит на −Z, откуда дует ветер")
	t.free()


func test_rotor_smooth() -> void:
	var t := _turbines(1)
	var w: Dictionary = _cfg().osm_pilot.wind_turbines
	var rated := float(w.rated_rpm) * TAU / 60.0
	var acc := float(w.rotor_accel_rpm_s) * TAU / 60.0
	var wind := [Vector3(10, 0, 0)]
	var air := func(_p: Vector3) -> Vector3: return wind[0]
	t.osm_wind(air, Vector3.ZERO)
	var dt := 0.05
	var prev_a := t.angle_of(0)
	var prev_o := t.omega_of(0)
	var worst_da := 0.0
	var worst_do := 0.0
	for i in 9000:
		if i == 3000:
			wind[0] = Vector3(-14, 0, 5)
			t.osm_wind(air, Vector3.ZERO)
		if i == 6000:
			wind[0] = Vector3(40, 0, 0)  # выше cut-out
			t.osm_wind(air, Vector3.ZERO)
		t.step(dt)
		worst_da = maxf(worst_da, absf(wrapf(t.angle_of(0) - prev_a, -PI, PI)))
		worst_do = maxf(worst_do, absf(t.omega_of(0) - prev_o))
		prev_a = t.angle_of(0)
		prev_o = t.omega_of(0)
		if i == 2999:
			approx(t.omega_of(0), rated * (10.0 - float(w.cut_in_ms)) / (float(w.rated_ms) - float(w.cut_in_ms)), 1e-3, "10 м/с — по кривой")
		if i == 5999:
			approx(t.omega_of(0), rated, 1e-3, "14.9 м/с — номинал")
	check(worst_da <= rated * dt + 1e-5, "угол без рывков: шаг %.5f ≤ %.5f" % [worst_da, rated * dt])
	check(worst_do <= acc * dt + 1e-6, "ускорение ограничено: %.6f" % worst_do)
	approx(t.omega_of(0), 0.0, 1e-6, "выше cut-out остановился")
	t.free()


func test_one_sample_per_cluster() -> void:
	var t := _turbines(5, null, 50.0)  # 250 м в одной ячейке cluster_m
	var calls := [0]
	var heights: Array[float] = []
	t.osm_wind(func(p: Vector3) -> Vector3:
		calls[0] += 1
		heights.append(p.y)
		return Vector3(5, 0, 0), Vector3(0, 100, 0))
	check(calls[0] == 1, "один опрос на кластер, а не %d" % calls[0])
	approx(heights[0], 180.0, 1e-3, "воздух спрашивается на высоте ступицы")
	t.free()
	# дальше visibility_m — не опрашиваются
	var t2 := _turbines(2)
	var n2 := [0]
	t2.osm_wind(func(_p: Vector3) -> Vector3:
		n2[0] += 1
		return Vector3.ZERO, Vector3(1.0e6, 0, 0))
	check(n2[0] == 0, "кластеры вне visibility_m не опрашиваются")
	t2.free()


func test_obstacle_and_phase() -> void:
	var obs := ObstacleIndex.new()
	var t := _turbines(1, obs)
	check(not obs.hit(Vector3(50, 150, 60), Vector3(50, 150, 100)).is_empty(), "башня — препятствие")
	var t2 := _turbines(1)
	approx(t.angle_of(0), t2.angle_of(0), 1e-9, "фаза детерминирована от координат")
	t.free()
	t2.free()


func _gondola_data() -> OsmData:
	var d := OsmData.new()
	d.aerialways = [{"t": "gondola", "p": PackedVector2Array([Vector2(0, 0), Vector2(600, 0), Vector2(1200, 100)])}]
	return d


func test_cabins_follow_rope() -> void:
	var cfg := _cfg()
	var obs := ObstacleIndex.new()
	var node := OsmCableCars.build(_gondola_data(), cfg, _flat, obs) as OsmCableCars
	check(node != null, "кабинки построены")
	if node == null:
		return
	check(node.line_count() == 1 and node.cabin_count() >= 8, "кабинок %d" % node.cabin_count())
	check(obs.size() > 0, "второй трос — препятствие")
	var speed := float(cfg.osm_pilot.aerialways.cabins.classes.gondola.speed_ms)
	var l = node._lines[0].line
	var worst := 0.0
	var prev: Vector3 = (node.cabin_state(l, 0, 0.0))[0]
	var dt := 0.25
	for k in range(1, 800):
		var st := node.cabin_state(l, 0, k * dt)
		var p: Vector3 = st[0]
		worst = maxf(worst, p.distance_to(prev))
		prev = p
	check(worst <= speed * dt * 1.2, "ход плавный, без прыжков: %.3f ≤ %.3f" % [worst, speed * dt * 1.2])
	check(worst >= speed * dt * 0.5, "скорость по классу: шаг %.3f" % worst)
	# высота на тросе: опоры 9 м над землёй 100 м, провис ≥ 0
	var st0 := node.cabin_state(l, 0, 10.0)
	check((st0[0] as Vector3).y <= 109.0 + 0.01 and (st0[0] as Vector3).y > 100.0, "зацеп на тросе ниже верха опор")
	node.free()


func test_cable_car_pendulum() -> void:
	var d := OsmData.new()
	d.aerialways = [{"t": "cable_car", "p": PackedVector2Array([Vector2(0, 0), Vector2(800, 0)])}]
	var node := OsmCableCars.build(d, _cfg(), _flat, ObstacleIndex.new()) as OsmCableCars
	check(node != null and node.cabin_count() == 2, "две кабины-маятник")
	if node == null:
		return
	var l = node._lines[0].line
	var worst := 0.0
	var prev: Vector3 = (node.cabin_state(l, 0, 0.0))[0]
	var still := 0
	for k in range(1, 4000):
		var p: Vector3 = (node.cabin_state(l, 0, k * 0.1))[0]
		worst = maxf(worst, p.distance_to(prev))
		if p.distance_to(prev) < 1e-6:
			still += 1
		prev = p
	check(worst < 2.0, "без рывков: %.3f" % worst)
	check(still > 100, "стоянка у станции есть: %d шагов" % still)
	# кабины идут навстречу: сумма расстояний от концов линии постоянна
	var a: Vector3 = (node.cabin_state(l, 0, 30.0))[0]
	var b: Vector3 = (node.cabin_state(l, 1, 30.0))[0]
	check(absf((a.x + b.x) - l.pts[l.pts.size() - 1].x) < 1.0, "кабины зеркальны по линии")
	node.free()
