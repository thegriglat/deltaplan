extends TestCase
## Птицы (FR-22, VR-8, VR-22): честный признак подъёма, в т.ч. слабого, где дельтаплану уже
## тяжело; кружат и набирают высоту реальной скоростью подъёма (air_velocity_at); реагируют
## на пилота — ближе flee_radius_m шарахаются, редкая пара терпит его в том же термике.


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo() -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": 0.0}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	return a


## В термике слабее birds.min_strength_ms птиц нет; birds.min_strength_ms сам заметно ниже
## того, что нужно дельтаплану (см. thermal_strength_ms для weak-дня в docs/guide/atmosphere.md).
func test_birds_absent_below_min_strength() -> void:
	var a := _atmo()
	var min_ms := float(a.cfg.birds.min_strength_ms)
	check(min_ms < 2.0, "порог птиц ниже, чем нужно дельтаплану: %.2f" % min_ms)
	a.add_static_thermal(0.0, 0.0, min_ms * 0.5, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var bf := BirdFlock.new()
	bf.setup(a)
	bf._choose_flocks()
	check(bf._flocks.is_empty(), "птиц нет в термике слабее min_strength_ms")
	bf.free()
	a.free()


## Птицы кружат уже в слабом термике (ниже старого порога 2,5 м/с, но выше нового) и реально
## набирают высоту со скоростью подъёма на своей высоте (не по фиксированной синусоиде).
func test_birds_appear_in_weak_thermal_and_climb() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, 1.2, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var bf := BirdFlock.new()
	bf.setup(a)
	bf._choose_flocks()
	check(not bf._flocks.is_empty(), "птицы появились в слабом термике (1,2 м/с)")
	if bf._flocks.is_empty():
		bf.free()
		a.free()
		return
	var birds: Array = bf._flocks[0][1]
	check(
		birds.size() >= int(a.cfg.birds.birds_per_flock[0])
		and birds.size() <= int(a.cfg.birds.birds_per_flock[1]),
		"число птиц в стае в диапазоне конфига: %d" % birds.size()
	)
	var y0 := float(birds[0].y)
	for i in 200:
		a.step(0.5)
		bf._place_birds(0.5)
	# Термик слабый и без ветра — либо птица заметно набрала высоту, либо уже дошла до верха
	# и заскользила дальше (обе развязки доказывают, что высота идёт от air_velocity_at, а не
	# от фиксированного времени).
	var still_there := not birds.is_empty()
	check(still_there, "птица всё ещё существует (не пропала бесследно)")
	if still_there:
		var y1 := float(birds[0].y)
		var state := String(birds[0].state)
		check(
			y1 > y0 + 20.0 or state != "circle",
			"птица набрала высоту в термике: %.0f -> %.0f (state=%s)" % [y0, y1, state]
		)
	bf.free()
	a.free()


## Пилот (focus_node/get_focus) ближе flee_radius_m — птица отваливает и уходит.
func test_bird_flees_when_pilot_close() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, 2.0, 150.0)
	a.set_focus(Vector3(1000, 300, 1000))  # пилот далеко — птицы спокойно кружат
	a.step(1.0)
	var bf := BirdFlock.new()
	bf.setup(a)
	bf._choose_flocks()
	check(not bf._flocks.is_empty(), "стая появилась")
	if bf._flocks.is_empty():
		bf.free()
		a.free()
		return
	var birds: Array = bf._flocks[0][1]
	var idx := -1
	for i in birds.size():
		if not bool(birds[i].companion):
			idx = i
			break
	check(idx >= 0, "в стае есть птица, не привыкшая к пилоту")
	if idx < 0:
		bf.free()
		a.free()
		return
	bf._place_birds(0.05)  # пересчитать реальную позицию на круге
	var pos0: Vector3 = birds[idx].pos
	a.set_focus(pos0)  # пилот резко оказывается вплотную к птице
	bf._place_birds(0.05)
	check(String(birds[idx].state) == "flee", "птица шарахнулась от пилота ближе порога")
	var d0 := (Vector3(birds[idx].pos) - pos0).length()
	for i in 10:
		bf._place_birds(0.3)  # 3 с — меньше flee_duration_s, птица ещё не вернулась кружить
	var d1 := (Vector3(birds[idx].pos) - pos0).length()
	check(d1 > d0 + 5.0, "птица продолжает уходить от места испуга: %.1f -> %.1f" % [d0, d1])
	bf.free()
	a.free()


## Редкая «привычная» пара не реагирует на пилота и продолжает кружить рядом с ним.
func test_companion_pair_ignores_pilot_proximity() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, 2.0, 150.0)
	a.set_focus(Vector3(1000, 300, 1000))
	a.step(1.0)
	var bf := BirdFlock.new()
	bf.setup(a)
	bf._choose_flocks()
	check(not bf._flocks.is_empty(), "стая появилась")
	if bf._flocks.is_empty():
		bf.free()
		a.free()
		return
	var birds: Array = bf._flocks[0][1]
	birds[0].companion = true
	bf._place_birds(0.05)
	var pos0: Vector3 = birds[0].pos
	a.set_focus(pos0)
	bf._place_birds(0.05)
	check(
		String(birds[0].state) == "circle", "привычная птица не пугается пилота вплотную и кружит"
	)
	bf.free()
	a.free()


## QL-8: минимальный размер на экране задан в конфиге и дошёл до шейдера; вдали птица не меньше него.
func test_min_span_px_in_shader() -> void:
	var a := _atmo()
	var bf := BirdFlock.new()
	bf.setup(a)
	var mp := float(a.cfg.birds.min_span_px)
	check(mp >= 3.0, "мин. размах птицы на экране >= 3 px: %.1f" % mp)
	var mat := (bf._mmi.material_override as ShaderMaterial)
	check(is_equal_approx(float(mat.get_shader_parameter("min_span_px")), mp), "min_span_px передан в шейдер")
	check(bf._model_span > 0.5, "размах модели прочитан: %.2f" % bf._model_span)
	check(int(a.cfg.birds.max_flocks) >= 6, "стай не меньше 6")
	bf.free()
	a.free()


## QL-8: стаи берут термики впереди по курсу раньше термиков позади на том же расстоянии.
func test_flocks_prefer_thermals_ahead() -> void:
	var a := _atmo()
	a.add_static_thermal(1000.0, 0.0, 2.0, 150.0)  # впереди (+X)
	a.add_static_thermal(-900.0, 0.0, 2.0, 150.0)  # позади, чуть ближе
	a.step(1.0)
	var c := BirdFlock.near_thermals(
		a.field.thermals, a.time_s, Vector3(0, 300, 0), 2000.0, 1.0, {}, Vector2(1, 0), 1.0
	)
	check(c.size() >= 2, "оба термика прошли фильтр: %d" % c.size())
	if c.size() >= 2:
		var first: AtmoThermal = c[0][2]
		check(first.src.x > 0.0, "первым идёт термик впереди, x=%.0f" % first.src.x)
	a.free()


## QL-8: хищные птицы — по одной, только в глубоком термике, не ниже raptor_min_height_m над источником,
## не больше max_raptors, размах из конфига; в термике, где верх ниже порога, их нет.
func test_raptors_high_in_deep_thermals_only() -> void:
	var a := _atmo()
	var rh := float(a.cfg.birds.raptor_min_height_m)
	var top := rh + float(a.cfg.birds.top_margin_m) + 400.0
	var ids := []
	for i in 5:
		ids.append(a.add_static_thermal(300.0 * i, 0.0, 2.5, 150.0))  # глубокие
	var id_s := a.add_static_thermal(0.0, 1500.0, 2.5, 150.0)  # мелкий: верх ниже порога хищных
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	for id in ids:
		a.field.thermals[id].top = top
	a.field.thermals[id_s].top = rh - 100.0
	var bf := BirdFlock.new()
	bf.setup(a)
	bf._choose_flocks()
	var n_r := 0
	var n_f := 0
	var sp: Array = a.cfg.birds.raptor_span_m
	for entry in bf._flocks:
		if bool(entry[3]):
			n_r += 1
			var b: Dictionary = (entry[1] as Array)[0]
			check((entry[1] as Array).size() == 1, "хищная птица одна")
			check(float(b.y) - (entry[0] as AtmoThermal).src.y >= rh - 0.01, "хищная птица выше %.0f м над источником" % rh)
			check(float(b.span_m) >= float(sp[0]) and float(b.span_m) <= float(sp[1]), "размах %.2f" % float(b.span_m))
			check((entry[0] as AtmoThermal).top - (entry[0] as AtmoThermal).src.y >= rh, "только в глубоком термике")
		else:
			n_f += 1
	check(n_r == int(a.cfg.birds.max_raptors), "хищных птиц ровно max_raptors: %d" % n_r)
	check(n_f <= int(a.cfg.birds.max_flocks), "обычных стай не больше max_flocks: %d" % n_f)
	bf._place_birds(0.1)
	check(bf._mm.instance_count > 0, "птицы размещены")
	bf.free()
	a.free()
