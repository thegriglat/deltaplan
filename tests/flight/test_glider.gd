extends TestCase
## Нода Glider: сцена грузится, шагает модель, сигналы доходят.


func test_glider_scene_steps_and_lands() -> void:
	var scene: PackedScene = load("res://scenes/glider/glider.tscn")
	var g: Glider = scene.instantiate()
	g.auto_start = Glider.AutoStart.NONE
	var root: Node = Engine.get_main_loop().current_scene
	root.add_child(g)
	g.setup("training", 500.0)
	approx(
		g.pilot_mass_kg,
		float(Config.value("wings/training", "pilot_mass_max_kg")),
		0.0,
		"масса ограничена диапазоном крыла"
	)
	g.set_ground_fn(func(_x: float, _z: float) -> float: return 10.0)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)
	g.reset_in_air(Vector3(0, 13, 0), 90.0)
	var tel := []
	var landed := []
	g.telemetry_updated.connect(func(t: Telemetry) -> void: tel.append(t.altitude_agl))
	g.landed.connect(func(r: Dictionary) -> void: landed.append(r))
	var ci := ControlInput.new()
	g.set_input(ci)
	for i in 1200:
		g._physics_process(1.0 / 120.0)
		if not landed.is_empty():
			break
	check(tel.size() > 10, "telemetry_updated шлётся каждый шаг")
	check(landed.size() == 1, "landed пришёл")
	check(g.phase() == "landed", "фаза landed: " + g.phase())
	approx(g.get_telemetry().heading_deg, 90.0, 1.0, "курс на восток")
	check(g.get_telemetry().position.x > 5.0, "летел на восток (+X)")
	g.free()
