extends TestCase
## Пасхалка «лайнер»: траектория — функция времени, живучесть следа от cirrus_cover, overcast.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_airliner


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.airliner


func _ctx(t: float, cover := 0.1, sky := "clear") -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = "K"
	c.weather = {"cirrus_cover": cover, "_derived": {"sky": sky}}
	return c


func _egg(t0: float) -> EggAirliner:
	var e := EggAirliner.new()
	e.t0 = t0
	e.lifetime_s = float(_cfg().lifetime_s)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	e.begin(_ctx(t0), _cfg(), rng, t0)
	return e


func test_trajectory_is_function_of_time() -> void:
	var a := _egg(100.0)
	var b := _egg(100.0)
	for s in [10.0, 50.0, 123.0, 300.0]:
		a.update(_ctx(100.0 + s))
	b.update(_ctx(100.0 + 300.0))
	var same := a.position.is_equal_approx(b.position)
	check(same, "прыжок = прогон: %s vs %s" % [a.position, b.position])
	check(a.position.y >= 9000.0 and a.position.y <= 11000.0, "эшелон 9–11 км")
	check(not a.update(_ctx(100.0 + 400.0)), "после lifetime_s — конец")
	a.free()
	b.free()


func test_trail_life_grows_with_cirrus() -> void:
	var c := _cfg()
	var dry := EggAirliner.trail_life(0.1, c)
	var mid := EggAirliner.trail_life(0.35, c)
	var wet := EggAirliner.trail_life(0.8, c)
	check(dry < mid and mid < wet, "живучесть растёт: %s %s %s" % [dry, mid, wet])
	check(dry < 60.0 and wet > 300.0, "сухой — десятки секунд, влажный — минуты")


func test_overcast_and_night() -> void:
	var c := _cfg()
	check(not EggAirliner.can_appear(_ctx(0.0, 0.1, "overcast"), c), "overcast — нет")
	check(EggAirliner.can_appear(_ctx(0.0), c), "ясно днём — да")
	var n := _ctx(0.0)
	n.to_sun = Vector3(0, -0.5, 0.8).normalized()
	check(not EggAirliner.can_appear(n, c), "ночью — нет")
