extends TestCase
## Пасхалка E8 «люди на старте»: у палаток, машут при низком пролёте, нет лагеря — нет людей.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_people


## Место с заданным лагерем (остальное пусто).
class Place:
	extends EggPlace
	var tents: Array[Dictionary] = []

	func camp() -> Array[Dictionary]:
		return tents


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.people


func _ctx(with_camp := true) -> EggContext:
	var pl := Place.new()
	if with_camp:
		for k in 4:
			pl.tents.append(
				{
					"type": "tent",
					"position": Vector3(-9.0 + 6.0 * k, 0.0, 3.0 * (k % 2)),
					"basis": Basis.IDENTITY,
					"yaw": 0.0,
					"color": 0,
					"radius": 1.8,
				}
			)
	var c := EggContext.new()
	c.place = pl
	c.world_key = "P"
	c.sun_elev_deg = 40.0
	c.height_at = func(_x: float, _z: float) -> float: return 0.0
	c.pilot_pos = Vector3(0.0, 200.0, 0.0)
	return c


func _spawn(c: EggContext, seed_i: int) -> EggPeople:
	var e := EggPeople.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	e.begin(c, _cfg(), rng, 0.0)
	e.update(c)
	return e


func test_conditions() -> void:
	check(EggPeople.can_appear(_ctx(), _cfg()), "лагерь и день: можно")
	check(not EggPeople.can_appear(_ctx(false), _cfg()), "нет лагеря: нельзя")
	var c := _ctx()
	c.sun_elev_deg = -10.0
	check(not EggPeople.can_appear(c, _cfg()), "ночь: нельзя")
	c.place = null
	c.sun_elev_deg = 30.0
	check(not EggPeople.can_appear(c, _cfg()), "нет места: нельзя")


func test_stand_near_tents() -> void:
	for sd in 6:
		var c := _ctx()
		var e := _spawn(c, sd)
		var n := e.person_count()
		check(n >= 3 and n <= 8, "людей 3–8: %d" % n)
		for step in 40:
			c.t = step * 7.0
			e.update(c)
			for i in n:
				var p := e.person_pos(i)
				var best := INF
				for t in c.place.camp():
					var d := p.distance_to(Vector2(t.position.x, t.position.z))
					best = minf(best, d - float(t.radius))
				if best < 2.0 or best > 6.0:
					check(false, "человек %d: %.2f м от края палатки (нужно 2–6)" % [i, best])
					return
	check(true, "у палаток 2–6 м")


func test_wave_when_low() -> void:
	var c := _ctx()
	var e := _spawn(c, 3)
	c.pilot_pos = Vector3(20.0, 30.0, 0.0)
	c.t = 5.0
	e._last_tick = -1.0e9
	e.update(c)
	var low_ok := true
	for i in e.person_count():
		low_ok = low_ok and e.arm_angle(i) > 2.0
	check(low_ok, "игрок низко над лагерем: руки подняты")
	c.pilot_pos = Vector3(20.0, 400.0, 0.0)
	c.t = 30.0
	e.update(c)
	var high_ok := true
	for i in e.person_count():
		high_ok = high_ok and e.arm_angle(i) < 0.5
	check(high_ok, "игрок высоко: руки опущены")
