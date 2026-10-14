extends TestCase
## SL-18: LOD2-кресты в шейдере — радиусы по пресетам, кольцо клеток (цена: экземпляры и вершины),
## общий хеш в include без зависимостей от рельефа, кольцо импостеров за крестами, ближний стык в
## материалах моделей. Побитовая сверка хеша и масок стыка — GPU-тест tests/terrain/test_tree_cross_gpu.gd.

static var _terrain: Terrain


func _ongudai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location("ongudai")
	return _terrain


func _trees_cfg() -> Dictionary:
	return (Config.get_config("world").get("trees", {}) as Dictionary).duplicate(true)


func test_config_keys() -> void:
	var t := _trees_cfg()
	check(t.has("crosses_enabled"), "trees.crosses_enabled")
	check(float(t.get("cell_m", 0.0)) == 8.0, "trees.cell_m = 8 (SL-К5)")
	var agl := float(t.get("cross_max_agl_m", 0.0))
	check(agl >= 1500.0 and agl <= 2000.0, "cross_max_agl_m 1500–2000: %.0f" % agl)
	var want := {"low": 900.0, "medium": 1100.0, "high": 1500.0}
	var presets: Dictionary = Config.get_config("game").get("graphics_presets", {})
	for p in want:
		var tr: Dictionary = presets[p].configs.world.trees
		approx(float(tr.get("cross_radius_m", 0.0)), want[p], 0.5, "cross_radius_m %s" % p)


func test_ring_cost_by_preset() -> void:
	# цена крестов: экземпляров кольца (вершин — ×8) по пресетам; каждый — до outer_m
	var t := _trees_cfg()
	var out := []
	var prev := 0
	for r in [900.0, 1100.0, 1500.0]:
		t["cross_radius_m"] = r
		var tc := TreeCrosses.new()
		tc.read_config(t)
		var n := GrassField.ring_offsets(tc.cell_m, -1.0, tc.outer_m()).size()
		check(n > prev, "кольцо растёт с радиусом")
		check(tc.outer_m() >= r * tc.k_max + tc.dither * 0.5, "кольцо покрывает r·k_max + dither/2")
		prev = n
		out.append("%.0f м: outer %.0f м, экземпляров %d, вершин %d" % [r, tc.outer_m(), n, n * 8])
		tc.free()
	print("SL-18 кресты: " + "; ".join(out))


func test_include_self_contained() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/terrain/tree_cell.gdshaderinc")
	check(src.find("#include") < 0, "tree_cell.gdshaderinc без include")
	for name in ["h_bilinear", "forest_mask", "surface_node", "layer_spacing", "hash12"]:
		check(src.find(name) < 0, "tree_cell без %s (terrain_common)" % name)
	for fn in ["uvec2 tc_hash(ivec2 c)", "tc_present", "tc_offset", "tc_model_t", "tc_cross_window"]:
		check(src.find(fn) >= 0, "есть %s" % fn)
	var model := FileAccess.get_file_as_string("res://scripts/terrain/tree_model.gdshader")
	check(model.find("tc_model_window(") >= 0, "tree_model: окно модели (LOD0/1 и ближний стык) из tree_cell")
	var imp := FileAccess.get_file_as_string("res://scripts/terrain/forest_impostors.gdshader")
	check(imp.find("band_mode") < 0, "band-импостеры SL-17 сняты")


func test_crosses_on_by_default() -> void:
	# SL-20: LOD2 на CPU нет (SL-19) — кресты включены по умолчанию, Terrain их создаёт
	var t := _ongudai()
	check(bool(_trees_cfg().get("crosses_enabled", false)), "trees.crosses_enabled = true")
	check(t.crosses != null, "Terrain.crosses создан")


func test_setup_stitches_models_and_impostors() -> void:
	var t := _ongudai()
	var models := t.trees as TerrainTreeModels
	if models == null or t.impostors == null:
		check(false, "нет моделей/импостеров")
		return
	var cfg := _trees_cfg()
	cfg["crosses_enabled"] = true
	cfg["cross_radius_m"] = 1500.0
	t.impostors.set_cross_active(false)
	var legacy := t.impostors.grid_ring()
	var tc := TreeCrosses.new()
	var ok := tc.setup(t.layers[0], t.renderer.height_textures[0], t.surfaces[0], t.renderer.surface_textures[0],
			cfg, models, t.impostors)
	check(ok, "setup")
	if ok:
		var r1 := float(cfg.lod_distances_m[1])
		approx(float(models.materials[0].get_shader_parameter("cross_near_m")), r1, 1e-3, "модели: cross_near_m = r1")
		var ring := t.impostors.grid_ring()
		approx(ring.x, 1500.0 * tc.k_min - tc.dither * 0.5, 1e-3, "импостеры начинаются за крестами")
		approx(ring.y, 1500.0 * tc.k_max + tc.dither * 0.5, 1e-3, "импостеры в полную силу за крестами")
		check(tc.instance_total > 0 and tc.multimesh.instance_count == tc.instance_total, "кольцо экземпляров")
		t.impostors.set_cross_active(false)
		check(t.impostors.grid_ring() == legacy, "кресты скрыты — прежнее кольцо импостеров")
		t.impostors.set_cross_active(true)
		check(t.impostors.grid_ring() == ring, "снова за крестами")
		# вернуть как было (общий Terrain тестов: его собственные кресты)
		if t.crosses != null:
			t.impostors.set_cross_ring(
				Vector2(t.crosses.r_far * t.crosses.k_min - 0.5 * t.crosses.dither,
						t.crosses.r_far * t.crosses.k_max + 0.5 * t.crosses.dither))
	tc.free()


## SL-24: вдали крест тянется к своей средней (альбедо полога), а не к общим far_canopy_luma = 0,32
## (линейный ALBEDO: 0,32 в 2–6 раз светлее хвои 0,05 → «седые» кресты). Формула прежнего хвоста:
## при 1200 м и яркости 0,05 прежний код давал ~0,107 (×2,1); шейдер теперь зовёт sl_tree_tone.
func test_far_tone_not_pulled_to_old_luma() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/terrain/tree_cross.gdshader")
	check(src.contains("sl_tree_tone(rgb, mix(sl_canopy_albedo.y, sl_canopy_albedo.x, con)"),
			"крест вдали: sl_tree_tone к альбедо полога породы")
	var l := 0.05
	var old := l + 0.35 * (0.6 * 0.32 + 0.4 * l - l)
	check(old > 2.0 * l, "прежний хвост поднимал яркость хвои ×%.1f" % (old / l))


## Последним: освободить общий Terrain файла (без него — утечки RID при выходе).
func test_zz_free_terrain() -> void:
	if _terrain != null:
		_terrain.free()
		_terrain = null
	check(true)
