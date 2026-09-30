extends TestCase
## Контракты модуля start-fixes (docs/start_fixes_contracts.md): форма стыков К1–К4.
## Ломается, если формат поменяли без правки контракта.


func _has_method_args(script: Script, method: String, n_args: int) -> bool:
	for m in script.get_script_method_list():
		if String(m.name) == method:
			return (m.args as Array).size() == n_args
	return false


func test_k1_surface_classes() -> void:
	check(SurfaceLayer.FOREST == 1 and SurfaceLayer.GRASS == 2, "К1: FOREST=1, GRASS=2")
	check(SurfaceLayer.SHRUB == 4 and SurfaceLayer.CLASS_COUNT == 9, "К1: SHRUB=4, 9 классов")
	check(
		_has_method_args(SurfaceLayer, "replace_in_circle", 5),
		"К1: SurfaceLayer.replace_in_circle(cx, cz, r, from, to)"
	)
	var terrain := load("res://scripts/terrain/terrain.gd") as Script
	check(_has_method_args(terrain, "surface_at", 2), "К1: Terrain.surface_at(x, z)")
	check(_has_method_args(terrain, "forest_at", 2), "К1: Terrain.forest_at(x, z)")
	# v2 (SF-1): пустырь вокруг произвольного старта после загрузки
	check(
		_has_method_args(terrain, "add_start_clearing", 3),
		"К1 v2: Terrain.add_start_clearing(x, z, radius_m)"
	)
	check(_has_method_args(terrain, "get_start_clearings", 0), "К1 v2: get_start_clearings()")
	var t := Terrain.new()
	check("surface_revision" in t and t.surface_revision is int, "К1 v2: surface_revision: int")
	t.free()
	check(
		_has_method_args(TerrainRenderer, "refresh_surface", 2),
		"К1 v2: TerrainRenderer.refresh_surface(li, surface)"
	)
	var ss: Dictionary = Config.get_config("game").start_search
	check(
		ss.has("clearing_radius_m") and ss.has("clearing_radius_m_doc"), "К1 v2: радиус в конфиге"
	)
	approx(Terrain.start_clearing_radius_m(), float(ss.clearing_radius_m), 1e-6, "К1 v2: радиус")


func test_k2_grass_config() -> void:
	var g: Dictionary = Config.get_config("vegetation").grass
	check(g.has("shrub_density"), "К2: grass.shrub_density")
	check(g.has("blade_height_m"), "К2: grass.blade_height_m")


func test_k3_ground_run_shape() -> void:
	check(_has_method_args(GroundRun, "step", 5), "К3: GroundRun.step(m, dt, input, air, ground)")
	var gr := GroundRun.new()
	check(gr.phase == "standing", "К3: фаза стоя — standing")
	var m := FlightModel.new()
	check("bank" in m and "roll_rate" in m and "heading" in m, "К3: bank/roll_rate/heading")
	var gb: Dictionary = Config.get_config("flight").ground_bank
	check(gb.has("fail_bank_deg"), "К3: ground_bank.fail_bank_deg")


func test_k4_basis_convention() -> void:
	var m := FlightModel.new()
	m.setup(Config.get_config("wings/sport"), Config.get_config("pilot"), {})
	m.reset_on_ground(Vector3(0, 100, 0), 90.0)
	m.bank = deg_to_rad(10.0)
	m.theta = deg_to_rad(5.0)
	FlightTelemetry.fill(m, Callable(), Callable())
	var want := Basis.from_euler(Vector3(m.theta, -m.heading, -m.bank))
	check(m.telemetry.basis.is_equal_approx(want), "К4: basis = from_euler(theta, −heading, −bank)")
	check(m.telemetry.position == m.position, "К4: начало координат планера — ступни (position)")
