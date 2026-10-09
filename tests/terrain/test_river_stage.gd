extends TestCase
## RiverStage: синтетическая V-долина — русло по дну, сток в нижний край, привязка и запись PNG.

const N := 65


func _layers() -> Dictionary:
	var info := {"id": "far", "width": N, "height": N, "spacing_m": 100.0, "origin_x_m": 0.0, "origin_z_m": 0.0}
	return {"far": info}


## Долина вдоль z: дно на x = 3200, уклон к z = max.
func _heights() -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for r in N:
		for c in N:
			h[r * N + c] = 50.0 * abs(c - 32) + (N - r) * 1.0 + 100.0
	return h


func _cfg() -> Dictionary:
	return {"source_layer": "far", "min_area_km2": 0.3, "width_k": 20.0, "min_width_m": 100.0,
		"max_width_m": 200.0, "snap_radius_m": 80.0}


func test_compute_valley() -> void:
	var imgs := RiverStage.compute({"far": _heights()}, _layers(), _cfg())
	check(imgs.has("far"), "маска слоя far")
	var img: Image = imgs.far
	check(img.get_width() == N and img.get_height() == N and img.get_format() == Image.FORMAT_L8, "L8 по сетке слоя")
	check(img.get_pixel(32, 40).r > 0.9, "дно долины — вода")
	check(img.get_pixel(5, 40).r == 0.0 and img.get_pixel(60, 10).r == 0.0, "склоны — суша")


func test_flow_tree_and_accumulate() -> void:
	var ft := RiverStage.flow_tree(_heights(), N, N)
	var parent: PackedInt32Array = ft.parent
	check(ft.order.size() == N * N, "порядок обходит все клетки")
	check(parent[0] == -1 and parent[N * N - 1] == -1, "граничные клетки — стоки")
	var acc := RiverStage.accumulate(parent, ft.order, 0.01)
	var mx := 0.0
	for a in acc:
		mx = maxf(mx, a)
	check(absf(mx - 0.01 * N * N) < 1e-6 or mx > 0.01 * N * 0.5, "водосбор растёт к стоку (%.3f км²)" % mx)


func test_run_writes_png() -> void:
	var ctx := LocationBuildContext.new()
	ctx.dir = "user://test_river_stage_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	ctx.spec = {"rivers": _cfg()}
	ctx.heights = {"far": _heights()}
	ctx.layers = _layers()
	var err: Error = await RiverStage.new().run(ctx)
	check(err == OK, "run: OK")
	var p := "%s/far_water.png" % ctx.dir
	check(FileAccess.file_exists(p), "far_water.png записан")
	var img := Image.load_from_file(ProjectSettings.globalize_path(p))
	check(img != null and img.get_width() == N and img.get_pixel(32, 40).r > 0.9, "PNG читается, русло на месте")
	check(ctx.layers.far.get("water_file", "") == "far_water.png", "water_file в слое")
	DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(ctx.dir)
	ctx.spec = {}
	var e2: Error = await RiverStage.new().run(ctx)
	check(e2 == OK, "без rivers — OK, без масок")
