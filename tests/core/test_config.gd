extends TestCase

func test_sim_config_loads() -> void:
	var sim: Dictionary = Config.get_config("sim")
	check(sim.has("physics_hz"), "sim.physics_hz есть")
	check(Engine.physics_ticks_per_second == int(sim.physics_hz), "частота физики применена")


func test_deep_merge() -> void:
	var m := Config._deep_merge({"a": {"b": 1, "c": 2}, "d": 3}, {"a": {"c": 5}})
	check(m.a.b == 1 and m.a.c == 5 and m.d == 3, "глубокое слияние")


func test_dotted_value() -> void:
	approx(float(Config.value("sim", "physics_hz")), 120.0, 0.0, "value по ключу")
