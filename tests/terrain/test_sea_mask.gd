extends TestCase
## SeaMask (S2): признак «море» на синтетических сетках, расстояние до берега, стадия sea, load_for.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=sea_mask

const N := 200
const CELL := 100.0
const P := {"min_cells": 100, "median_max_m": 0.25, "q99_min_m": -1.0}


class Grid:
	var w: int
	var h: int
	var hs := PackedFloat32Array()
	var cls := PackedByteArray()

	func _init(w_: int, h_: int, h0: float, c0: int) -> void:
		w = w_
		h = h_
		hs.resize(w * h)
		hs.fill(h0)
		cls.resize(w * h)
		cls.fill(c0)

	func set_cell(x: int, y: int, height: float, c: int) -> void:
		hs[y * w + x] = height
		cls[y * w + x] = c

	func compute() -> PackedByteArray:
		return SeaMask.compute(hs, cls, w, h, CELL, P)


func _sum(m: PackedByteArray) -> int:
	var s := 0
	for v in m:
		if v > 0:
			s += 1
	return s


## Остров радиуса 20 клеток в океане: класс 0, батиметрия до −3000 м, у берега (до 10 клеток) 0 м.
func _island_ocean() -> Grid:
	var g := Grid.new(N, N, 0.0, 0)
	var c := Vector2(N / 2.0, N / 2.0)
	for y in N:
		for x in N:
			var d := Vector2(x, y).distance_to(c)
			if d <= 20.0:
				g.set_cell(x, y, 50.0, 1)
			elif d > 30.0:
				g.set_cell(x, y, -minf(3000.0, (d - 30.0) * 60.0), 0)
	return g


func test_island_in_ocean_with_bathymetry() -> void:
	var g := _island_ocean()
	var m := g.compute()
	var land := 0
	for i in N * N:
		if g.cls[i] == 1:
			land += 1
			if m[i] != 0:
				check(false, "суша помечена морем")
				return
	check(_sum(m) == N * N - land, "море — вся вода: %d из %d" % [_sum(m), N * N - land])
	# по оси вправо от острова: центр (100, 100), берег суши x = 120 (d = 20), вода с x = 121
	var row := N / 2 * N
	check(m[row + 121] == 2, "первая клетка воды от суши: 1 + floor(100/100) = 2, а %d" % m[row + 121])
	check(m[row + 126] == 7, "6-я клетка воды (d = 6): 7, а %d" % m[row + 126])
	check(m[row + 199] == 80, "x = 199 (d = 79): 80, а %d" % m[row + 199])


func test_lake_300m_touching_edge_is_not_sea() -> void:
	var g := Grid.new(N, N, 400.0, 1)
	for y in range(50, 150):
		for x in range(0, 120):  # касается западного края
			g.set_cell(x, y, 300.0, 6)
	check(_sum(g.compute()) == 0, "озеро на 300 м у края — не море")


func test_low_lake_minus_400_touching_edge_is_not_sea() -> void:
	var g := Grid.new(N, N, 100.0, 1)
	for y in range(50, 150):
		for x in range(0, 120):
			g.set_cell(x, y, -400.0, 6)
	check(_sum(g.compute()) == 0, "озеро −400 м ровно у края — не море (берег q99 < −1 м)")


func test_training_island_zero_sea() -> void:
	var g := Grid.new(N, N, 0.0, 6)  # море 0 м, класс 6, без батиметрии
	for y in range(90, 110):
		for x in range(90, 110):
			g.set_cell(x, y, 30.0, 3)
	var m := g.compute()
	check(_sum(m) == N * N - 400, "остров 0 м: всё вокруг — море, %d" % _sum(m))
	check(m[89 * N + 100] == 2 and m[88 * N + 100] == 3, "расстояние от острова: %d, %d" % [m[89 * N + 100], m[88 * N + 100]])


func test_water_inside_square_is_not_sea() -> void:
	var g := Grid.new(N, N, 30.0, 1)
	for y in range(60, 140):
		for x in range(60, 140):
			g.set_cell(x, y, 0.0, 6)
	check(_sum(g.compute()) == 0, "вода на 0 м целиком внутри квадрата — не море (край)")


func test_deep_water_without_shore_is_not_sea() -> void:
	var g := Grid.new(N, N, -500.0, 0)  # только глубокая вода, берега нет
	check(_sum(g.compute()) == 0, "q99 < −1 м — не море")


func test_small_component_is_not_sea() -> void:
	var g := Grid.new(N, N, 20.0, 1)
	for y in 9:
		for x in 10:  # 90 клеток у края < 100
			g.set_cell(x, y, 0.0, 6)
	check(_sum(g.compute()) == 0, "компонента меньше min_cells — не море")
	for x in 10:
		g.set_cell(x, 9, 0.0, 6)
	g.set_cell(0, 10, 0.0, 6)
	check(_sum(g.compute()) == 101, "101 клетка у края — море: %d" % _sum(g.compute()))


func test_diagonal_connection() -> void:
	var g := Grid.new(30, 30, 20.0, 1)
	for y in 6:
		for x in 10:
			g.set_cell(x, y, 0.0, 6)  # 60, касается края
	for y in range(6, 12):
		for x in range(10, 20):
			g.set_cell(x, y, 0.0, 6)  # 60, связь только по диагонали (9,5)-(10,6)
	check(_sum(g.compute()) == 120, "8-связность: обе части — одно море, %d" % _sum(g.compute()))


func test_no_water_all_zero_and_deterministic() -> void:
	var g := Grid.new(N, N, 100.0, 1)
	check(_sum(g.compute()) == 0, "суша — ноль")
	var o := _island_ocean()
	check(o.compute() == o.compute(), "детерминизм: побайтно одинаково")


func test_all_sea_and_cap_255() -> void:
	var g := Grid.new(N, N, 0.0, 6)
	var m := g.compute()
	var all255 := true
	for v in m:
		all255 = all255 and v == 255
	check(all255, "нет берега в квадрате — 255 везде")
	var long := Grid.new(400, 20, 0.0, 6)
	for y in 20:
		long.set_cell(0, y, 5.0, 1)
	var lm := long.compute()
	check(lm[1] == 2 and lm[100] == 101 and lm[300] == 255 and lm[399] == 255, "потолок 255: %d %d %d" % [lm[100], lm[300], lm[399]])


func test_distance_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var w := 60
	var g := Grid.new(w, w, 0.0, 6)
	for k in 120:
		g.set_cell(rng.randi_range(2, w - 3), rng.randi_range(2, w - 3), 10.0, 1)
	var m := g.compute()
	var bad := 0
	for y in w:
		for x in w:
			var best := 1.0e9
			for ly in w:
				for lx in w:
					if m[ly * w + lx] == 0:
						best = minf(best, Vector2(x - lx, y - ly).length())
			if m[y * w + x] != 0 and m[y * w + x] != mini(255, 1 + int(floor(best))):
				bad += 1
	check(bad == 0, "расстояние против перебора: расхождений %d" % bad)


# ---------- стадия и загрузка ----------

const W := 120


func _write_place(dir: String, with_surface: bool) -> Grid:
	DirAccess.make_dir_recursive_absolute(dir)
	var g := Grid.new(W, W, 0.0, 0)
	for y in W:
		for x in W:
			if x < 40:
				g.set_cell(x, y, 40.0, 1)
				g.hs[y * W + x] = 40.0 + y * 0.5
			else:
				g.hs[y * W + x] = -minf(500.0, maxf(0.0, (x - 60.0) * 20.0))
	var mn := -500.0
	var step := 0.03125
	HeightLayer.encode_rgb24(g.hs, W, W, mn, step).save_webp(dir.path_join("far.webp"), false)
	var info := {"id": "far", "file": "far.webp", "width": W, "height": W, "spacing_m": CELL,
		"origin_x_m": -6000.0, "origin_z_m": -6000.0, "height_min_m": mn, "height_step_m": step}
	var f := FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"layers": [info]}))
	f.close()
	if with_surface:
		SeaMask.write_l8(dir.path_join("far_surface.webp"), W, W, g.cls)
	return g


func _ctx(dir: String) -> LocationBuildContext:
	var c := LocationBuildContext.new()
	c.dir = dir
	return c


func test_stage_and_load_for() -> void:
	var dir := "user://test_sea_stage"
	var g := _write_place(dir, true)
	var abs_dir := ProjectSettings.globalize_path(dir)
	var err: int = await SeaStage.new().run(_ctx(dir))
	check(err == OK, "стадия: ошибка %d" % err)
	check(FileAccess.file_exists(dir.path_join("far_sea.webp")), "far_sea.webp записан")
	var want := SeaMask.compute(g.hs, g.cls, W, W, CELL, SeaMask.params_from_config())
	check(_sum(want) == W * (W - 40), "ожидаемое море: вся вода, %d" % _sum(want))
	var sj: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("sea.json")))
	check(sj is Dictionary and int(sj.version) == 1 and int(sj.sea_cells) == _sum(want) and int(sj.components) == 1
		and sj.has("seconds"), "sea.json: %s" % str(sj))
	var res := SeaMask.load_for(dir)
	check(not res.is_empty() and res.cell_m == CELL and res.origin == Vector2(-6000.0, -6000.0), "load_for: поля")
	var img: Image = res.image
	check(img.get_format() == Image.FORMAT_L8 and img.get_data() == want, "far_sea.webp без потерь == compute")
	# без файла маски — счёт на лету
	DirAccess.remove_absolute(abs_dir.path_join("far_sea.webp"))
	var res2 := SeaMask.load_for(dir)
	check(not res2.is_empty() and (res2.image as Image).get_data() == want, "load_for без файла считает compute")
	check(SeaMask.load_for("user://test_sea_no_such_dir").is_empty(), "нет места — пустой словарь")
	for fn in ["far.webp", "meta.json", "far_surface.webp", "far_sea.webp", "sea.json"]:
		DirAccess.remove_absolute(abs_dir.path_join(fn))
	DirAccess.remove_absolute(abs_dir)


func test_stage_without_surface_is_unavailable() -> void:
	var dir := "user://test_sea_stage_nosurf"
	_write_place(dir, false)
	var err: int = await SeaStage.new().run(_ctx(dir))
	check(err == ERR_UNAVAILABLE, "нет far_surface.webp — ERR_UNAVAILABLE, а %d" % err)
	check(not FileAccess.file_exists(dir.path_join("far_sea.webp")), "файл маски не пишется")
	check(SeaMask.load_for(dir).is_empty(), "load_for: нет покрова — {}")
	var abs_dir := ProjectSettings.globalize_path(dir)
	for fn in ["far.webp", "meta.json"]:
		DirAccess.remove_absolute(abs_dir.path_join(fn))
	DirAccess.remove_absolute(abs_dir)
