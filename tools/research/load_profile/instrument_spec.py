# Разметка этапов загрузки: (файл, метка, начало, якорь, конец). См. instrument.py.
T = "scripts/terrain/terrain.gd"
G = "scripts/game/game.gd"
W = "scripts/game/world_link.gd"
O = "scripts/world_objects/world_objects.gd"
REGIONS = [
    # Terrain.load_point
    (T, "T.builder.build", "var res: Dictionary = await builder.build", "func load_point", None),
    (T, "T.read_location", "var r := _read_location(String(res.key))", "func load_point", None),
    (T, "T.mask_tasks_wait", "for task_id: int in r.masks", "func load_point", None),
    (T, "T.load_surfaces", "var new_surfaces := _load_surfaces(", "func load_point", None),
    (T, "T.setup_async", "await setup_async(", "func load_point", None),
    # Terrain._setup_steps
    (T, "T.classify_missing", "if async:", "func _setup_steps", None),
    (T, "T.refresh_sun", "refresh_sun()", "func _setup_steps", None),
    (T, "T.build_sites", "_build_sites()", "func _setup_steps", None),
    (T, "T.set_surfaces", "set_surfaces(new_surfaces", "func _setup_steps", None),
    (T, "T.compute_reliefs", "_compute_reliefs(", "func _setup_steps", None),
    (T, "T.renderer.build", "renderer.build(", "func _setup_steps", None),
    (T, "T.renderer.apply_textures", "renderer.apply_textures(", "func _setup_steps", None),
    (T, "T.make_trees", "if bool(trees_cfg.get(\"enabled\"", "func _setup_steps", None),
    (T, "T.make_grass", "_make_grass(Config", "func _setup_steps", None),
    (T, "T.setup_wind", "_setup_wind(world", "func _setup_steps", None),
    (T, "T.apply_scene_look", "_apply_scene_look(scene_look_params())", "func _setup_steps", None),
    # Terrain._make_trees
    (T, "T.trees.impostors.setup", "if impostors.setup(", "func _make_trees", None),
    (T, "T.trees.crosses.setup", "if crosses.setup(", "func _make_trees", None),
    (T, "T.trees.cones.setup", "cones.setup(", "func _make_trees", None),
    (T, "T.trees.set_clearings", "if _clearings.size() == 3:", "func _make_trees", None),
    (T, "T.trees.pass_forest_mask", "_pass_forest_mask(models)", "func _make_trees", None),
    (T, "T.grass.setup", "grass.setup(", "func _make_grass", None),
    # Game.start
    (G, "G.load_terrain", "if not await _load_terrain():", "func start(", None),
    (G, "G.weather_context", "_weather_ctx = _weather_context()", "func start(", None),
    (G, "G.derive_weather", "_peak_spacing = float(", "func start(", None),
    (G, "G.air.set_weather", "air.call(\"set_weather\"", "func start(", None),
    (G, "G.air.set_ground", "air.call(\"set_ground\"", "func start(", None),
    (G, "G.sky.start_flight", "sky.clock.start_flight(", "func start(", None),
    (G, "G.terrain.set_sun", "if terrain.has_method(\"set_sun\"):", "func start(", None),
    (G, "G.terrain.set_flight_date", "if terrain.has_method(\"set_flight_date\"):", "func start(", None),
    (G, "G.heating.setup", "_heating.setup(", "func start(", None),
    (G, "G.on_sun_changed", "_on_sun_changed(sky.clock.to_sun())", "func start(", None),
    (G, "G.make_day", "if air.has_method(\"set_day\"):", "_on_sun_changed(sky.clock.to_sun())", None),
    (G, "G.static_thermals", "if air.has_method(\"load_static_thermals\"):", "func start(", None),
    (G, "G.world_link.link", "world_link.link(terrain, air, glider)", "func start(", None),
    (G, "G.choose_start", "_choose_start()", "func start(", None),
    (G, "G.set_wind", "air.call(", "_site_heading = _start_heading", None),
    (G, "G.load_air_field", "await _load_air_field(progress)", "func start(", None),
    (G, "G.align_start_heading", "_align_start_heading()", "func start(", None),
    (G, "G.place_thermals_near", "if air.has_method(\"place_thermals_near\"):", "func start(", None),
    (G, "G.apply_haze", "_apply_haze()", "func start(", None),
    (G, "G.setup_glider", "_setup_glider()", "func start(", None),
    (G, "G.collisions.setup", "collisions.setup(", "func start(", None),
    (G, "G.place_camp", "world_link.place_camp()", "func start(", None),
    (G, "G.bots.setup", "bots.setup_in_world(", "func start(", None),
    (G, "G.relief_wait", "while terrain.has_method(\"relief_busy\")", "func start(", None),
    (G, "G.goals_setup", "_goals_setup()", "func start(", None),
    (G, "G.restart", "restart()", "_goals_setup()", None),
    (G, "G.air.refresh_now", "if air.has_method(\"refresh_now\"):", "func start(", None),
    # WorldLink.link
    (W, "W.set_wind_sources", "if terrain.has_method(\"set_wind_sources\"):", "func link(", None),
    (W, "W.rock_scatter", "RockScatter.attach(terrain)", "func link(", None),
    (W, "W.shrub_scatter", "ShrubScatter.attach(terrain)", "func link(", None),
    (W, "W.clearings", "if loc != \"\" and terrain.has_method(\"set_clearings\"):", "func link(", None),
    (W, "W.objects.setup", "if objects != null and objects.has_method(\"setup\"):", "func link(", None),
    # WorldObjects.build
    (O, "O.clear", "clear()", "func build(", None),
    (O, "O.starts", "for s in start_sites:", "func build(", None),
    (O, "O.landings", "for site in WorldObjects.landing_specs(", "func build(", None),
    (O, "O.osm", "_build_osm(loc_id, center, height_fn)", "func build(", None),
    (O, "O.start_tracks", "if bool(cfg.start_tracks.get(\"enabled\", true)):", "func build(", None),
    (O, "O.villages", "_build_villages(patches, height_fn)", "func build(", None),
    (O, "O.start_gear", "_build_start_gear(start_sites)", "func build(", None),
    (O, "O.osm.load_for", "osm = OsmData.load_for(", "func _build_osm", None),
    (O, "O.osm.layer_build", "osm_layer.build(osm, cfg", "func _build_osm", None),
    (O, "O.vil.patches", "if patches == null:", "func _build_villages", None),
    (O, "O.vil.plan", "houses = VillagePlacer.plan(", "func _build_villages", None),
    (O, "O.vil.layer_build", "village_layer.build(houses, cfg, height_fn)", "func _build_villages", None),
    (O, "O.vil.gardens", "var gardens := CityTrees.build_gardens(", "func _build_villages", None),
]
L = "scripts/world_objects/osm_layer.gd"
EXPRS = [
    (L, "OsmCityGround.build(data, cfg, height_fn)", "osm.CityGround"),
    (L, "OsmRoads.build(data, cfg, height_fn, obstacles)", "osm.Roads"),
    (L, "OsmPilot.build(data, cfg, height_fn, obstacles)", "osm.Pilot"),
    (L, "OsmChimneyPlumes.build(data, cfg, height_fn)", "osm.ChimneyPlumes"),
    (L, "OsmWindTurbines.build(data, cfg, height_fn, obstacles)", "osm.Wind"),
    (L, "OsmCableCars.build(data, cfg, height_fn, obstacles)", "osm.Cabins"),
    (L, "OsmTraffic.build(data, cfg, height_fn, obstacles)", "osm.Traffic"),
    (L, "OsmBuildings.build(data, cfg, height_fn, building_obstacles)", "osm.Buildings"),
    (L, "CityTrees.build(data, cfg, height_fn, forest_fn)", "osm.CityTrees"),
    (T, "models.setup(layers[0], surfaces[0], trees_cfg)", "T.trees.models.setup"),
]

# --- второй круг: внутри самых долгих ---
C = "scripts/world_objects/world_clearings.gd"
A = "scripts/atmosphere/atmosphere.gd"
F = "scripts/atmosphere/thermal_field.gd"
P = "scripts/world_objects/osm/osm_pilot.gd"
M = "scripts/terrain/terrain_tree_models.gd"
R = "scripts/terrain/terrain_renderer.gd"
AR = "scripts/atmosphere/air_model/air_runtime.gd"
REGIONS += [
    (C, "C.landing_specs", "for spec in WorldObjects.landing_specs(", "static func build_for", None),
    (C, "C.tracks(height_fn+plan)", "if bool(cfg.start_tracks.get(\"enabled\", true)):", "static func build_for", None),
    (C, "C.houses.load_height_fn", "var hf := _load_height_fn(dem_dir2)", "static func build_for", None),
    (C, "C.houses.plan", "if hf.is_valid():", "var hf := _load_height_fn(dem_dir2)", None),
    (C, "C.osm.load_for", "if bool(ocfg.get(\"enabled\", true)):", "static func build_for", None),
    (C, "C.build", "c.build(landings, cfg, half, tracks, houses, osm)", "static func build_for", None),
    (C, "C.b.image_create", "image = Image.create_empty(n, n, false, Image.FORMAT_L8)", "func build(", None),
    (C, "C.b.osm_roads_buildings_rails", "if osm != null:", "func build(", None),
    (C, "C.b.houses", "for b: Array in houses:", "func build(", None),
    (A, "A.refresh_begin", "_refresh_begin(false)", "func refresh_now", None),
    (A, "A.step_refresh", "field.step_refresh(-1)", "func refresh_now", None),
    (A, "A.refresh_finish", "_refresh_finish()", "func refresh_now", None),
    (F, "F.begin.update_air", "_update_air()", "func begin_refresh", None),
    (F, "F.erase", "if not _job_erase(dl):", "func step_refresh", None),
    (F, "F.gen_begin", "if mode != \"static\":", "_j_cells = []", None),
    (F, "F.gen", "if not _job_gen(dl):", "func step_refresh", None),
    (F, "F.prune", "_prune(_j_t)", "func step_refresh", None),
    (F, "F.buckets", "if not _job_buckets(dl):", "func step_refresh", None),
    (F, "F.params", "if not _job_params(dl):", "func step_refresh", None),
    (F, "F.commit", "_job_commit()", "func step_refresh", None),
    (P, "pilot.peaks", "if bool(pc.peaks.enabled):", "static func build(", None),
    (P, "pilot.power", "if bool(pc.power.enabled)", "static func build(", None),
    (P, "pilot.verticals", "if bool(pc.verticals.enabled)", "static func build(", None),
    (P, "pilot.aerialways", "if bool(pc.aerialways.enabled)", "static func build(", None),
    (P, "pilot.aeroways", "if bool(pc.aeroways.enabled)", "static func build(", None),
    (M, "trees.placer.setup", "placer.setup(layer, surface, cfg)", "func setup(", None),
    (M, "trees.load_lods", "for k in TreePlacer.SPECIES.size():", "func setup(", None),
    (M, "trees.multimeshes", "for kv in meshes.size():", "func setup(", None),
    (R, "R.clear", "clear()", "func build(", None),
    (R, "R.make_material", "var mat := _make_material(", "func build(", None),
    (R, "R.grid_meshes", "for lod in n_lod:", "var meshes: Array[Mesh] = []", None),
    (R, "R.chunks", "for cj in (layer.height - 1) / cells:", "func build(", None),
    (R, "R.update_lods", "update_lods(true)", "func build(", None),
    (R, "R.warm_up", "_warm_up()", "func build(", None),
    (AR, "AR.prep.coarse_domain", "if coarse > 1:", "static func _prep_task", None),
    (AR, "AR.prep.domain", "var base := _domain(place, c, k, DX)", "static func _prep_task", None),
    (AR, "AR.prep.prepared_case", "var pc := PreparedCase.from_case(base)", "static func _prep_task", None),
]
RAW = [
    # переходы стадий AirRuntime: время главного потока и кадры на стадию
    (AR, '''	_stage_ms[sk] = maxf(float(_stage_ms.get(sk, 0.0)), dt)
''', '''	_stage_ms[sk] = maxf(float(_stage_ms.get(sk, 0.0)), dt)
	_lp_ms[sk] = float(_lp_ms.get(sk, 0.0)) + dt
	_lp_fr[sk] = int(_lp_fr.get(sk, 0)) + 1
	if _stage != st_in:
		print("[lpair] %s -> %s @%.3f main %.0f ms frames %d" % [sk, Stage.keys()[_stage], Time.get_ticks_usec() / 1e6, _lp_ms[sk], _lp_fr[sk]])
		_lp_ms[sk] = 0.0
		_lp_fr[sk] = 0
'''),
    (AR, "enum Stage { IDLE, PREP, PHASE, COARSE, NEXT, SOLVE, BUILD, WINDOWS, SHIFT }\n",
     "enum Stage { IDLE, PREP, PHASE, COARSE, NEXT, SOLVE, BUILD, WINDOWS, SHIFT }\nvar _lp_ms := {}\nvar _lp_fr := {}\n"),
    # счётчики
    (O, "	osm_layer.build(osm, cfg", '''	LP.n("osm.counts", {"roads": osm.roads.size(), "rivers": osm.rivers.size(), "rail": osm.rail.size(), "buildings": osm.buildings.size(), "power": osm.power.size(), "verticals": osm.verticals.size(), "peaks": osm.peaks.size(), "tiles_ok": osm.tiles_ok})
	osm_layer.build(osm, cfg'''),
    (L, "	stats[\"layers\"] = made\n", '''	stats["layers"] = made
	for c in get_children():
		if c.has_meta(&"stats"):
			LP.n("osm.stats." + String(c.name), c.get_meta(&"stats"))
'''),
    (C, "	build_time_s = (Time.get_ticks_usec() - t0) / 1.0e6\n", '''	build_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
	LP.n("clearings", {"n": n, "roads": osm.roads.size() if osm != null else 0, "buildings": osm.buildings.size() if osm != null else 0, "houses": houses.size(), "stamps": _lp_stamps})
'''),
    (C, "func stamp(x: float, z: float, r: float) -> void:\n", "func stamp(x: float, z: float, r: float) -> void:\n\t_lp_stamps += 1\n"),
    (C, "var build_time_s: float = 0.0\n", "var build_time_s: float = 0.0\nvar _lp_stamps := 0\n"),
    (F, "func _job_commit() -> void:\n", "func _job_commit() -> void:\n\tLP.n(\"thermals\", {\"cells\": _j_cells.size(), \"thermals\": _wt.size(), \"active\": _na.size()})\n"),
    (M, "	return true\n\n\nfunc _process", "	LP.n(\"trees.mmi\", _mmis.size())\n	return true\n\n\nfunc _process"),
]

# --- третий круг ---
RD = "scripts/world_objects/osm/osm_roads.gd"
REGIONS += [
    (RD, "roads.groups", "var groups := _groups(data, cfg)", "static func build(", None),
    (RD, "roads.threads_wait", "for t in tasks:", "static func build(", None),
    (RD, "roads.meshes_main", "for g: Dictionary in groups:", "for t in tasks:", None),
    (RD, "roads.add_nodes", "for g: Dictionary in groups:", "var stats := {", None),
    (P, "power.plan", "var plan := PowerLinePlanner.plan(lines, pc, height_fn)", "static func _power(", None),
    (P, "power.supports", "for s: Dictionary in plan.supports:", "static func _power(", None),
    (P, "power.wires", "_wires(node, plan.wires, pc, obstacles)", "static func _power(", None),
    (R, "R.mat.height_tex", "var tex := layer.make_texture()", "func _make_material(", None),
    (R, "R.mat.max_tex", "var mtex := layer.make_max_texture()", "func _make_material(", None),
    (R, "R.mat.surface_tex", "var stex := surface.make_texture()", "func _make_material(", None),
    (R, "R.mat.forest_built", "set_forest_mask(m, surface)", "func _make_material(", None),
    (M, "trees.load_lods_files", "var lods := _load_lods(", "func setup(", None),
    (M, "trees.with_sway", "for lod in 3:", "var mh := lods[0].get_aabb().end.y", None),
]
