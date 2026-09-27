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
## того, что нужно дельтаплану (см. thermal_strength_ms для weak-дня в docs/atmosphere.md).
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
