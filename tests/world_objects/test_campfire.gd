extends TestCase
## Костёр с дымом в лагере (Campfire): место и снос дыма ветром.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=campfire


func _cfg() -> Dictionary:
	return WorldObjects.load_config()


func test_place_near_camp_clear_of_tents() -> void:
	var c := _cfg()
	var env := {"height_fn": func(_x: float, _z: float) -> float: return 100.0}
	var start := Vector3(0, 100, 0)
	var camp := TentCamp.plan(start, 0.0, 5, c.tents, env)
	check(camp.size() == 5, "лагерь на ровном поле")
	var p := Campfire.plan(camp, start, 0.0, c.campfire, c.tents, env)
	check(p.is_finite(), "место костра найдено")
	var centre := Vector2.ZERO
	for t in camp:
		var tp := Vector2(t.position.x, t.position.z)
		centre += tp
		check(
			(
				Vector2(p.x, p.z).distance_to(tp)
				>= float(t.radius) + float(c.campfire.clear_of_tents_m)
			),
			"костёр не в палатке"
		)
	centre /= camp.size()
	check(Vector2(p.x, p.z).distance_to(centre) <= float(c.campfire.search_radius_m), "у лагеря")


func test_smoke_follows_wind() -> void:
	var fire := Campfire.new()
	fire.setup(_cfg().campfire)
	var calm := fire.drift_estimate(8.0, Vector3.ZERO)
	check(calm.y > 8.0 and Vector2(calm.x, calm.z).length() < 0.5, "в штиль — вверх: %s" % calm)
	var w3 := fire.drift_estimate(8.0, Vector3(3, 0, 0))
	var w7 := fire.drift_estimate(8.0, Vector3(0, 0, -7))
	check(w3.x > 10.0 and absf(w3.z) < 0.5, "ветер на +x — дым на +x: %s" % w3)
	check(w7.z < -30.0 and absf(w7.x) < 0.5, "ветер на −z — дым на −z: %s" % w7)
	check(w7.y / -w7.z < w3.y / w3.x, "сильный ветер прижимает дым")
	fire.update_wind(Vector3(3, 0, 0), Vector3(5, 0, 0))
	var wl: Vector3 = fire.smoke_material.get_shader_parameter(&"wind_low")
	check(wl.is_equal_approx(Vector3(3, 0, 0)), "ветер уходит в шейдер дыма")
	check(fire.smoke.visibility_aabb.end.x > 40.0, "рамка видимости тянется по ветру")
	fire.free()
