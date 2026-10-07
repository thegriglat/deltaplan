extends TestCase
## Ласточки и пух над источниками молодых термиков (VR-24, QL-9): только над термиками поля,
## низко, у оси; слабые, старые и далёкие термики без признаков.


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo() -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/strong"), {"thermal_mode": "static", "wind_speed_kmh": 0.0}
	)
	var c: Dictionary = Config.get_config("atmosphere").duplicate(true)
	c.thermal_signs.swallow_chance = 1.0
	c.thermal_signs.fluff_chance = 1.0
	a.configure(c, w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	return a


func test_signs_only_over_thermal_axis_and_low() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, 2.5, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var s := ThermalSigns.new()
	s.setup(a)
	s.refresh(Vector3(0, 300, 0))
	check(s._entries.size() == 2, "у термика ласточки и пух: %d" % s._entries.size())
	var hmax := float(a.cfg.thermal_signs.swallow_height_agl_m[1])
	var bad := 0
	var n_sw := 0
	var n_fl := 0
	for k in 200:
		for d in s.positions(a.time_s + k * 0.7):
			var th: AtmoThermal = d.th
			var p: Vector3 = d.pos
			var ax := th.axis_at(p.y)
			var off := Vector2(ax.x - p.x, ax.y - p.z).length()
			if off > th.radius or p.y - th.src.y < 0.0 or p.y - th.src.y > hmax + 1.0:
				bad += 1
			if d.kind == "swallow":
				n_sw += 1
			else:
				n_fl += 1
	check(n_sw > 0 and n_fl > 0, "есть и ласточки, и пух: %d / %d" % [n_sw, n_fl])
	check(bad == 0, "признаки вне оси/высоты: %d" % bad)
	s.free()
	a.free()


func test_no_signs_for_weak_or_far_thermal() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, float(a.cfg.thermal_signs.min_strength_ms) * 0.5, 150.0)
	a.add_static_thermal(9000.0, 0.0, 3.0, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var s := ThermalSigns.new()
	s.setup(a)
	s.refresh(Vector3(0, 300, 0))
	check(s._entries.is_empty(), "слабый и дальний термики — без признаков: %d" % s._entries.size())
	s.free()
	a.free()


func test_old_thermal_has_no_signs() -> void:
	var a := _atmo()
	var s := ThermalSigns.new()
	s.setup(a)
	var th := AtmoThermal.new()
	th.strength = 3.0
	th.t_birth = 0.0
	th.t_grow = 300.0
	var extra := float(a.cfg.thermal_signs.young_extra_s)
	check(s.is_young(th, 100.0), "в росте — молодой")
	check(s.is_young(th, 300.0 + extra - 1.0), "сразу после роста — ещё молодой")
	check(not s.is_young(th, 300.0 + extra + 10.0), "зрелый — без признаков")
	check(not s.is_young(th, -50.0), "ещё не родился — без признаков")
	s.free()
	a.free()


func test_fluff_rises_and_swallows_darting() -> void:
	var a := _atmo()
	a.add_static_thermal(0.0, 0.0, 2.5, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var s := ThermalSigns.new()
	s.setup(a)
	s.refresh(Vector3(0, 300, 0))
	var th: AtmoThermal = s._entries[0].th
	# Частица пуха: за небольшой шаг времени идёт вверх (пока не обернулась на новый подъём).
	var up := 0
	var tot := 0
	for i in 16:
		var p0: Dictionary = s._fluff(th, i, 3.0)
		var p1: Dictionary = s._fluff(th, i, 3.5)
		if p1.pos.y > p0.pos.y - 100.0 and p1.pos.y < p0.pos.y + 100.0:
			tot += 1
			if p1.pos.y > p0.pos.y:
				up += 1
	check(tot > 0 and up == tot, "пух поднимается: %d из %d" % [up, tot])
	# Ласточка быстрая: средняя скорость в разумном для стрижа диапазоне.
	var v := 0.0
	for k in 100:
		v += (s._swallow(th, 0, k * 0.5).vel as Vector3).length()
	v /= 100.0
	check(v > 5.0 and v < 40.0, "скорость ласточки, м/с: %.1f" % v)
	s.free()
	a.free()


func test_fluff_rises_with_thermal_air() -> void:
	var a := _atmo()
	var id := a.add_static_thermal(0.0, 0.0, 3.0, 150.0)
	a.set_focus(Vector3(0, 300, 0))
	a.step(1.0)
	var s := ThermalSigns.new()
	s.setup(a)
	var th: AtmoThermal = a.field.thermals[id]
	var settle := float(a.cfg.thermal_signs.fluff_settle_ms)
	var pmax := float(a.cfg.thermal_signs.fluff_period_s[1])
	var wmax := th.strength - settle
	var n := 0
	var bad := 0
	for k in 300:
		var d := s._fluff(th, k % 16, 100.0 + k * 1.3)
		if d.is_empty():
			continue
		n += 1
		if d.pos.y - th.src.y > wmax * pmax + 1.0:
			bad += 1
	check(n > 0, "пух виден")
	check(bad == 0, "пух поднялся быстрее воздуха (w − оседание): %d" % bad)
	# Слабее оседания — не поднимается.
	th.strength = settle * 0.5
	var up := 0
	for k in 50:
		if not s._fluff(th, k % 16, 100.0 + k * 1.3).is_empty():
			up += 1
	check(up == 0, "при w ≤ оседания пух лежит: %d" % up)
	s.free()
	a.free()
