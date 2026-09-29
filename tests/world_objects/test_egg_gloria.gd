extends TestCase
## Глория: кольцо в антисолнечной точке на облаке под камерой; нет без облака и без солнца.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=egg_gloria


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.gloria


## Облако-плита ниже камеры: плотность 1 при y < top.
func _ctx(sun: Vector3, cam_y := 1500.0, top := 1000.0) -> EggContext:
	var c := EggContext.new()
	c.t = 10.0
	c.world_key = "G"
	c.to_sun = sun.normalized()
	c.pilot_pos = Vector3(0, cam_y, 0)
	c.cloud_density_at = func(p: Vector3) -> float: return 1.0 if p.y < top else 0.0
	return c


func _spawn(c: EggContext) -> EggGloria:
	var g := EggGloria.new()
	g.lifetime_s = 300.0
	var rng := RandomNumberGenerator.new()
	g.begin(c, _cfg(), rng, c.t)
	g.update(c)
	return g


func test_ring_at_antisolar_point() -> void:
	var c := _ctx(Vector3(0.6, 0.4, 0.3))
	check(EggGloria.can_appear(c, _cfg()), "солнце сзади-сверху, облако внизу: можно")
	c.t += 1.0
	var g := _spawn(c)
	c.t += 1.0
	g.update(c)
	var v := g.position - c.pilot_pos
	var ang := rad_to_deg(v.angle_to(-c.to_sun))
	check(ang < 0.5, "кольцо в антисолнечной точке, угол %.3f°" % ang)
	check(v.length() < 2500.0 and v.length() > 100.0, "дальность разумная: %.0f" % v.length())
	check(g.get_child_count() == 1, "один слой на экране")
	g.free()


func test_no_ring_when_conditions_fail() -> void:
	check(not EggGloria.can_appear(_ctx(Vector3(0.6, -0.3, 0.3)), _cfg()), "солнце под горизонтом")
	check(not EggGloria.can_appear(_ctx(Vector3(0.6, 0.4, 0.3), 900.0), _cfg()), "камера в облаке")
	var clear := _ctx(Vector3(0.6, 0.4, 0.3), 1500.0, -5000.0)
	check(not EggGloria.can_appear(clear, _cfg()), "нет облака")
	# облако слишком далеко: 4000 м по лучу
	check(
		not EggGloria.can_appear(_ctx(Vector3(0.6, 0.4, 0.3), 5000.0, 1000.0), _cfg()),
		"дальше предельной дальности"
	)
