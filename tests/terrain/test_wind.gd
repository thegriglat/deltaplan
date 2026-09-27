extends TestCase
## Тесты ветра на земле (T05, VR-17): запуск —
## godot --headless --path . res://tests/run_tests.tscn -- --filter=wind


func _wind_with_grass_material() -> Dictionary:
	var w := TerrainWind.new()
	w.setup(Config.get_config("world").wind_visual)
	var m := ShaderMaterial.new()
	m.shader = preload("res://scripts/terrain/grass.gdshader")
	w.add_materials([m])
	w.ground_fn = func(_x: float, _z: float) -> float: return 0.0
	return {"w": w, "m": m}


## Смещение рисунка порывов копится на CPU (offset += wind · dt) — поворот ветра на 90° не должен
## задним числом сдвинуть узор: смещение за один кадр ограничено текущей скоростью ветра.
func test_offset_no_jump_on_wind_turn() -> void:
	var w: TerrainWind = _wind_with_grass_material().w
	var speed := 8.0
	w.mean_wind_fn = func(_p: Vector3) -> Vector3: return Vector3(speed, 0.0, 0.0)
	w.update_at(Vector3.ZERO)
	var dt := 1.0 / 60.0
	for i in 60:  # ~1 с полёта с ветром вдоль X
		w.advance(dt)
	var before: Vector2 = w.offset
	# атмосфера отдала новый (повёрнутый на 90°) ветер одним шагом обновления (0,2 с) —
	# как это происходит в игре между вызовами update_at.
	w.mean_wind_fn = func(_p: Vector3) -> Vector3: return Vector3(0.0, 0.0, -speed)
	w.update_at(Vector3.ZERO, 0.2)
	w.advance(dt)
	var step: float = (w.offset - before).length()
	var limit := 1.5 * speed * dt
	check(
		step <= limit + 1e-6,
		"смещение за кадр при повороте ветра на 90°: %.4f ≤ %.4f (нет скачка)" % [step, limit]
	)


## Без крутых поворотов смещение за кадр вообще должно быть ровно wind · dt (никакой зависимости
## от TIME/накопленного времени).
func test_offset_matches_wind_times_dt() -> void:
	var w: TerrainWind = _wind_with_grass_material().w
	w.mean_wind_fn = func(_p: Vector3) -> Vector3: return Vector3(5.0, 0.0, 2.0)
	w.update_at(Vector3.ZERO)
	var dt := 1.0 / 30.0
	for i in 120:
		var before: Vector2 = w.offset
		w.advance(dt)
		var got: Vector2 = w.offset - before
		var want: Vector2 = w.wind * dt
		check(got.is_equal_approx(want), "шаг смещения = wind · dt: %s ≈ %s" % [got, want])


## Порывистость |air_velocity_at − mean_wind_at| у земли усиливает амплитуду пятен (wind_gust_ms
## в шейдере растёт монотонно с ростом порывистости атмосферы).
func test_gustiness_increases_gust_amplitude() -> void:
	var d := _wind_with_grass_material()
	var w: TerrainWind = d.w
	var m: ShaderMaterial = d.m
	w.mean_wind_fn = func(_p: Vector3) -> Vector3: return Vector3(5.0, 0.0, 0.0)
	w.air_fn = func(_p: Vector3) -> Vector3: return Vector3(5.0, 0.0, 0.0)  # штиль порывов
	w.update_at(Vector3.ZERO, 10.0)  # большой dt — экспонента почти догоняет цель
	var calm := float(m.get_shader_parameter("wind_gust_ms"))
	w.air_fn = func(_p: Vector3) -> Vector3: return Vector3(5.0, 0.0, 4.0)  # сильный порыв поперёк
	w.update_at(Vector3.ZERO, 10.0)
	var gusty := float(m.get_shader_parameter("wind_gust_ms"))
	check(gusty > calm, "порывистость выросла → сильнее амплитуда: %.3f -> %.3f" % [calm, gusty])


## Без air_fn поведение (и переданные шейдеру uniform) — как до карточки T05: ветер/термики те же,
## порывистость нулевая.
func test_no_air_fn_matches_previous_behavior() -> void:
	var d := _wind_with_grass_material()
	var w: TerrainWind = d.w
	var m: ShaderMaterial = d.m
	w.ground_fn = func(_x: float, _z: float) -> float: return 500.0
	w.mean_wind_fn = func(p: Vector3) -> Vector3:
		return Vector3(3.0, 0.0, -4.0) * (p.y - 500.0) / 10.0
	w.thermals_fn = func(_p: Vector3, _r: float) -> Array[Dictionary]: return []
	w.update_at(Vector3(0, 800, 0))
	check(w.wind.is_equal_approx(Vector2(3.0, -4.0)), "ветер как раньше: %s" % w.wind)
	check(Vector2(m.get_shader_parameter("wind_vec")).is_equal_approx(w.wind), "ветер в шейдере")
	check(
		is_equal_approx(float(m.get_shader_parameter("wind_gust_ms")), 0.0),
		"без air_fn порывистость 0"
	)
