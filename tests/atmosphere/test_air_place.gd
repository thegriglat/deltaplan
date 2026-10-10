class_name TestAirPlace
extends TestCase
## Вход решения масштаба 1 для места (AirPlace, AM-03) против эталона AM-01
## (tools/research/air3d/picard_gpu_refs.py → fixtures/air_model/picard/): рельеф области
## (блочное среднее), z_i и dθ̄/dz погоды игры. Поток тепла H — не по эталону (air.py solar_flux
## старый): источник истины — SurfaceHeat (C2 v8, SH3), H клетки = SurfaceHeat.mix_flux по её долям
## классов, влажности, нормали и воде. Снимок поверхности (AirPlace.surface_of): доли классов, вода
## карты и маски 10 м, уклон → скала, лёд, детерминизм. Без GPU.

const FIX := "res://tests/atmosphere/fixtures/air_model/picard/"


static func load_detail(loc_id: String) -> Array:
	var dir := Locations.data_dir(loc_id)
	var meta: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(dir.path_join("meta.json"))
	)
	for info: Dictionary in meta.layers:
		if String(info.id) == "detail":
			var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
			var img: Image = null
			if info.has("water_file"):
				var tex := TerrainRenderer.load_mask_texture(dir.path_join(String(info.water_file)))
				img = tex.get_image() if tex != null else null
			return [l, img]
	return []


static func load_loc(loc_id: String) -> Dictionary:
	var loc: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://configs/locations/%s.json" % loc_id)
	)
	loc.id = loc_id
	return loc


func test_domain_input_vs_reference() -> void:
	var lw := load_detail("ongudai")
	check(lw.size() == 2 and lw[0] != null, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := load_loc("ongudai")
	for dx in [400.0, 200.0]:
		var m := TestAirPicard.load_fix(FIX + "ongudai_d%d_h12" % int(dx))
		var t0 := Time.get_ticks_msec()
		var c := AirPlace.domain_case(lw[0], lw[1], loc, dx, 12.0, 3.0, 150.0)
		var t_ms := Time.get_ticks_msec() - t0
		check(c != null, "случай построен")
		if c == null:
			return
		check(
			c.nx == int(m.nx) and c.nz == int(m.nz) and c.z_bot == float(m.z_bot),
			"сетка как в эталоне"
		)
		var dat: Dictionary = m.data
		var e_h := _max_diff(c.hc, dat.hc)
		var e_q := _max_diff_64(c.heat, expected_heat(c, lw[0], lw[1], loc, 12.0, 3.0, NAN, null))
		var e_g := _max_diff(c.gam, dat.gam)
		var fmt := TestAirPicard.sci
		print(
			(
				"  %d м: подготовка %d мс; max|Δhc| %s м, max|ΔH − mix_flux| %s Вт/м², max|Δγ| %s К/м, z_i %.2f / %.2f м"
				% [int(dx), t_ms, fmt.call(e_h), fmt.call(e_q), fmt.call(e_g), c.z_i, float(m.z_i)]
			)
		)
		# высоты места квантованы шагом 1/32 м (N5), как float32 эталона
		check(e_h < 1e-3, "рельеф: %s м" % fmt.call(e_h))
		check(e_q < 1e-9, "H клетки = SurfaceHeat.mix_flux по её долям: %s Вт/м²" % fmt.call(e_q))
		check(e_g < 1e-7, "dθ̄/dz: %s К/м" % fmt.call(e_g))
		check(absf(c.z_i - float(m.z_i)) < 0.5, "z_i: %.2f против %.2f" % [c.z_i, float(m.z_i)])
		# профиль притока (C2 v4): α и max_profile случая игры = эталона на тот же час и ветер
		for u in [0.0, 3.0, 6.0]:
			var cu := c if u == 3.0 else AirPlace.domain_case(lw[0], lw[1], loc, dx, 12.0, u, 150.0)
			var pr: Dictionary = m.profiles["%d" % int(u)]
			print(
				(
					"    %d м/с: α %.6f / %.6f, max_profile %.6f / %.6f (игра / эталон, класс %s)"
					% [int(u), cu.p.alpha, pr.alpha, cu.p.max_profile, pr.max_profile, pr.cls]
				)
			)
			approx(float(cu.p.alpha), float(pr.alpha), 1e-9, "α %d м/с как в эталоне" % int(u))
			approx(
				float(cu.p.max_profile),
				float(pr.max_profile),
				1e-9 * float(pr.max_profile),
				"max_profile %d м/с как в эталоне" % int(u)
			)


static func _max_diff(a: PackedFloat64Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for i in a.size():
		e = maxf(e, absf(a[i] - b[i]))
	return e


static func _max_diff_64(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	if a.size() != b.size():
		return INF
	var e := 0.0
	for i in a.size():
		e = maxf(e, absf(a[i] - b[i]))
	return e


## H клеток случая c заново — прямо через SurfaceHeat (SH3): доли и влажность клетки (cell_surface),
## нормаль (−∂h/∂x, 1, ∂h/∂y) по hc (np.gradient), солнце классов SurfaceHeating, небо дня, вода —
## water_temp_c/air_temp_c на высоте клетки, u10 случая.
static func expected_heat(
	c: AirCase,
	detail: HeightLayer,
	water: Image,
	loc: Dictionary,
	hour: float,
	u10: float,
	t_max: float,
	surface: AirPlace.Surface,
	ctx := {}
) -> PackedFloat64Array:
	var cfg := WeatherModel.config()
	if ctx.is_empty():
		ctx = AirPlace.context(detail, loc, cfg)
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
	var d := AirPlace.day(ctx, hour, t_max, "clear", cfg)
	var cells := AirPlace.cell_surface(surface, water, detail, c.x0, c.y0, c.dx, c.nx, c.ny)
	var fr: PackedFloat32Array = cells.fr
	var mo: PackedFloat32Array = cells.m
	var sh := SurfaceHeating.new()
	sh.setup(float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h))
	var sun := sh.directions(hour)
	var scfg := SurfaceHeat.config()
	var wcfg: Dictionary = scfg.water
	var nc := SurfaceLayer.CLASS_COUNT
	var out := PackedFloat64Array()
	out.resize(c.nx * c.ny)
	for j in c.ny:
		for i in c.nx:
			var q := j * c.nx + i
			var il := maxi(i - 1, 0)
			var ir := mini(i + 1, c.nx - 1)
			var jl := maxi(j - 1, 0)
			var jr := mini(j + 1, c.ny - 1)
			var gx := (c.hc[j * c.nx + ir] - c.hc[j * c.nx + il]) / ((ir - il) * c.dx)
			var gy := (c.hc[jr * c.nx + i] - c.hc[jl * c.nx + i]) / ((jr - jl) * c.dx)
			var w := {}
			if fr[q * nc + SurfaceLayer.WATER] > 0.0:
				var z := c.hc[q]
				w = {
					t_water_c = SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), z, ctx, wcfg),
					t_air_c = SurfaceHeat.air_temp_c(hour, t_max, z, ctx, wcfg),
					u_ms = u10,
					z_m = z,
				}
			var sky := {cover = float(d.cover), sky_heat = float(d.sky_heat)}
			out[q] = SurfaceHeat.mix_flux(
				fr, q * nc, Vector3(-gx, 1.0, gy), sun, float(mo[q]), sky, w, scfg
			)
	return out


## Terrain для снимка поверхности: только то, что читает AirPlace.surface_of.
class FakeTerrain:
	extends RefCounted
	var surfaces: Array = []
	var reliefs: Array = []


const SYN_N := 81  # синтетический слой: 81 × 81 узлов 25 м, начало −1000 (±1 км)
const SYN_O := -1000.0


static func _syn_layer(slope := 0.0) -> HeightLayer:
	var hs := PackedFloat32Array()
	hs.resize(SYN_N * SYN_N)
	for j in SYN_N:
		for i in SYN_N:
			hs[j * SYN_N + i] = 500.0 + slope * (SYN_O + 25.0 * i)
	return HeightLayer.from_heights("detail", SYN_N, SYN_N, 25.0, SYN_O, SYN_O, hs)


## Карта: x < −100 — лес, иначе луг; узлы x ≥ 400, z ≥ 425 — вода (клетка (3, 0) сетки 400 м
## от (−800, −800)); маска 10 м: лес R = 255 при x < −100 (маска главнее карты: R = 0 — не лес),
## вода G = 255 над клеткой (2, 3); маска рек — над клеткой (0, 3).
static func _syn_place(slope := 0.0, moist := 0.8) -> Array:
	var layer := _syn_layer(slope)
	var cls := PackedByteArray()
	cls.resize(SYN_N * SYN_N)
	for j in SYN_N:
		for i in SYN_N:
			var x := SYN_O + 25.0 * i
			var z := SYN_O + 25.0 * j
			var c := SurfaceLayer.FOREST if x < -100.0 else SurfaceLayer.GRASS
			if x >= 400.0 and z >= 425.0:
				c = SurfaceLayer.WATER
			cls[j * SYN_N + i] = c
	var sl := SurfaceLayer.from_classes("detail", SYN_N, SYN_N, 25.0, SYN_O, SYN_O, cls)
	var mn := 201
	var md := PackedByteArray()
	md.resize(mn * mn * 2)
	for j in mn:
		for i in mn:
			var x := SYN_O + 10.0 * i
			var z := SYN_O + 10.0 * j
			if x < -100.0:
				md[(j * mn + i) * 2] = 255  # лес маски — там же, где лес карты
			if x >= -10.0 and x <= 400.0 and z >= -790.0 and z <= -390.0:
				md[(j * mn + i) * 2 + 1] = 255
	sl.set_forest_mask(Image.create_from_data(mn, mn, false, Image.FORMAT_RG8, md), 10.0, SYN_O, SYN_O)
	var riv := Image.create(SYN_N, SYN_N, false, Image.FORMAT_L8)
	for j in SYN_N:
		for i in SYN_N:
			var x := SYN_O + 25.0 * i
			var z := SYN_O + 25.0 * j
			if x >= -800.0 and x <= -425.0 and z >= -775.0 and z <= -400.0:
				riv.set_pixel(i, j, Color.WHITE)
	var rel := TerrainRelief.new()
	rel.width = 41
	rel.height = 41
	rel.cell_m = 50.0
	rel.origin_x = SYN_O
	rel.origin_z = SYN_O
	rel.moisture.resize(41 * 41)
	rel.moisture.fill(moist)
	var t := FakeTerrain.new()
	t.surfaces = [sl]
	t.reliefs = [rel]
	return [layer, riv, t]


static func _frac(cells: Dictionary, i: int, j: int, cls: int) -> float:
	return float((cells.fr as PackedFloat32Array)[(j * 4 + i) * SurfaceLayer.CLASS_COUNT + cls])


## SH3: доли классов клетки — по узлам 25 м block_mean; вода = карта ∪ маска 10 м ∪ маска рек;
## влажность — среднее поля по узлам; без снимка — NONE + маска рек, m_norm.
func test_cell_fractions_synthetic() -> void:
	var p := _syn_place()
	var layer: HeightLayer = p[0]
	var riv: Image = p[1]
	var sf := AirPlace.surface_of(p[2], layer, riv)
	check(sf != null, "снимок построен")
	if sf == null:
		return
	check(sf.width == SYN_N and sf.height == SYN_N, "снимок — узлы слоя 25 м")
	var cells := AirPlace.cell_surface(sf, riv, layer, -800.0, -800.0, 400.0, 4, 4)
	approx(_frac(cells, 0, 0, SurfaceLayer.FOREST), 1.0, 1e-7, "клетка (0, 0): лес")
	approx(_frac(cells, 1, 1, SurfaceLayer.FOREST), 0.75, 1e-7, "клетка (1, 1): 12 из 16 столбцов — лес")
	approx(_frac(cells, 1, 1, SurfaceLayer.GRASS), 0.25, 1e-7, "клетка (1, 1): 4 из 16 — луг")
	approx(_frac(cells, 3, 0, SurfaceLayer.WATER), 1.0, 1e-7, "клетка (3, 0): вода карты")
	approx(_frac(cells, 2, 3, SurfaceLayer.WATER), 1.0, 1e-7, "клетка (2, 3): вода маски 10 м")
	approx(_frac(cells, 0, 3, SurfaceLayer.WATER), 1.0, 1e-7, "клетка (0, 3): вода маски рек поверх леса")
	approx(_frac(cells, 2, 2, SurfaceLayer.GRASS), 1.0, 1e-7, "клетка (2, 2): луг")
	var worst := 0.0
	for v in (cells.m as PackedFloat32Array):
		worst = maxf(worst, absf(v - 0.8))
	check(worst < 1e-6, "влажность клетки — среднее поля (0,8): %s" % worst)
	# без снимка: класс NONE, вода — только маска рек, m = m_norm
	var c0 := AirPlace.cell_surface(null, riv, layer, -800.0, -800.0, 400.0, 4, 4)
	approx(_frac(c0, 0, 3, SurfaceLayer.WATER), 1.0, 1e-7, "без снимка: маска рек — вода")
	approx(_frac(c0, 3, 0, SurfaceLayer.NONE), 1.0, 1e-7, "без снимка: класс NONE")
	approx(
		float((c0.m as PackedFloat32Array)[5]),
		float(SurfaceHeat.config().moisture.m_norm),
		1e-7,
		"без снимка: m_norm"
	)
	# H окна на этой сетке = mix_flux по долям; вода днём в июле холоднее воздуха → H < 0, лес > 0
	var loc := {id = "syn", center_lat = 50.75, center_lon = 86.13, utc_offset_h = 7.0}
	var c := AirWindowCase.window_at(
		layer, riv, loc, 400.0, -800.0, -800.0, 12.0, 3.0, 150.0, NAN, "clear", true, {}, 4, 1.0, sf
	)
	check(c != null and c.heat.size() == 16, "окно 4 × 4 на синтетике")
	if c == null:
		return
	var e := _max_diff_64(c.heat, expected_heat(c, layer, riv, loc, 12.0, 3.0, NAN, sf))
	check(e < 1e-9, "H клетки = mix_flux по её долям: %s" % e)
	check(c.heat[0 * 4 + 3] < 0.0, "вода в июльский полдень: H < 0 (%.1f)" % c.heat[3])
	check(c.heat[0] > 50.0, "лес в полдень: H > 50 (%.1f)" % c.heat[0])


## Уклон круче terrain_look.rock_slope_deg: луг → скала (BARE), лес остаётся лесом.
func test_steep_grass_is_bare() -> void:
	var p := _syn_place(1.0)  # 45°
	var sf := AirPlace.surface_of(p[2], p[0], null)
	var cells := AirPlace.cell_surface(sf, null, p[0], -800.0, -800.0, 400.0, 4, 4)
	approx(_frac(cells, 2, 2, SurfaceLayer.BARE), 1.0, 1e-7, "луг 45° → скала")
	approx(_frac(cells, 0, 0, SurfaceLayer.FOREST), 1.0, 1e-7, "лес 45° — лес")


## T_воды ≤ 0 (январь) → вода считается льдом (класс SNOW): H клетки воды = H снега.
func test_water_ice_january() -> void:
	var layer := _syn_layer()
	var loc := {id = "syn", center_lat = 50.75, center_lon = 86.13, utc_offset_h = 7.0}
	var cfg := WeatherModel.config()
	var ctx := AirPlace.context(layer, loc, cfg)
	ctx.month = 1
	ctx.day = 15
	var wcfg: Dictionary = SurfaceHeat.config().water
	var tw := SurfaceHeat.water_temp_c(1, 15, 500.0, ctx, wcfg)
	approx(tw, 0.0, 0.0, "январь: T_воды = 0 (лёд)")
	var t_max := WeatherModel.typical_max_c(1, 15, cfg)
	var d := AirPlace.day(ctx, 12.0, t_max, "clear", cfg)
	var nc := SurfaceLayer.CLASS_COUNT
	var fr := PackedFloat32Array()
	fr.resize(4 * nc)
	var fs := PackedFloat32Array()
	fs.resize(nc)
	fs[SurfaceLayer.SNOW] = 1.0
	var m := PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	for q in 4:
		fr[q * nc + SurfaceLayer.WATER] = 1.0
	var hc := PackedFloat64Array([500.0, 500.0, 500.0, 500.0])
	var h := AirPlace.surface_flux(hc, 400.0, 2, 2, d, ctx, cfg, {fr = fr, m = m}, 3.0, t_max)
	var sh := SurfaceHeating.new()
	sh.setup(float(ctx.lat), float(ctx.lon), 1, 15, float(ctx.utc_offset_h))
	var hs := SurfaceHeat.mix_flux(
		fs,
		0,
		Vector3.UP,
		sh.directions(12.0),
		0.5,
		{cover = float(d.cover), sky_heat = float(d.sky_heat)},
		{},
		SurfaceHeat.config()
	)
	approx(h[0], hs, 1e-9, "лёд: H воды = H снега (%.1f Вт/м²)" % hs)


## Детерминизм (SH3): два снимка одного места и две сборки одного случая — побитно одно heat;
## вода карты поверхности (озёра OSM, маска 10 м) добавляется к маске рек.
func test_surface_determinism_ongudai() -> void:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location("ongudai")
	var loc := load_loc("ongudai")
	var utc := float(loc.get("utc_offset_h", NAN))
	var p1 := AirRuntime.place_of(t, utc)
	var p2 := AirRuntime.place_of(t, utc)
	var s1: AirPlace.Surface = p1.get("surface")
	var s2: AirPlace.Surface = p2.get("surface")
	check(s1 != null and s2 != null, "снимок у места игры")
	if s1 == null or s2 == null:
		t.free()
		return
	print("  снимок поверхности Онгудая: %.0f мс, %d × %d узлов" % [s1.build_ms, s1.width, s1.height])
	check(s1.cls == s2.cls and s1.moist == s2.moist, "два снимка — побитно одинаковые")
	# класс узла снимка = Terrain.surface_at (вода снимка, которой нет у Terrain, — маска рек —
	# не сверяется), влажность = moisture_at
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var diff := 0
	var n_cmp := 0
	var dm := 0.0
	for k in 4000:
		var i := rng.randi_range(1, s1.width - 2)
		var j := rng.randi_range(1, s1.height - 2)
		var x := s1.origin_x + 25.0 * i
		var z := s1.origin_z + 25.0 * j
		dm = maxf(dm, absf(s1.moist[j * s1.width + i] - t.moisture_at(x, z)))
		var cs := s1.cls[j * s1.width + i]
		var ct := t.surface_at(x, z)
		if cs == SurfaceLayer.WATER and ct != SurfaceLayer.WATER:
			continue  # вода маски рек поверх класса карты
		n_cmp += 1
		if cs != ct:
			diff += 1
	print("  класс узла ≠ Terrain.surface_at: %d из %d; max|Δm| %s" % [diff, n_cmp, dm])
	check(diff <= n_cmp / 200, "класс узла снимка = Terrain.surface_at (≤ 0,5 %%): %d из %d" % [diff, n_cmp])
	check(dm < 1e-6, "влажность узла = Terrain.moisture_at: %s" % dm)
	var a := AirPlace.domain_case(p1.detail, p1.water, p1.loc, 400.0, 12.0, 3.0, 150.0, NAN, "clear", true, 1.0, s1)
	var b := AirPlace.domain_case(p2.detail, p2.water, p2.loc, 400.0, 12.0, 3.0, 150.0, NAN, "clear", true, 1.0, s2)
	check(a != null and b != null and a.heat == b.heat, "две сборки — побитно одинаковое heat")
	if a != null:
		var e := _max_diff_64(a.heat, expected_heat(a, p1.detail, p1.water, p1.loc, 12.0, 3.0, NAN, s1))
		check(e < 1e-9, "H клетки = mix_flux по её долям (снимок): %s" % e)
		var cells := AirPlace.cell_surface(s1, p1.water, p1.detail, a.x0, a.y0, 400.0, a.nx, a.ny)
		var wf := AirPlace.water_fraction(p1.water, p1.detail, a.x0, a.y0, 400.0, a.nx, a.ny)
		var w_map := 0.0
		var w_riv := 0.0
		var nc := SurfaceLayer.CLASS_COUNT
		var bad := 0
		for q in a.nx * a.ny:
			var fw := (cells.fr as PackedFloat32Array)[q * nc + SurfaceLayer.WATER]
			w_map += fw
			w_riv += wf[q]
			if fw < wf[q] - 1e-6:
				bad += 1
		check(bad == 0, "вода клетки ⊇ маска рек (нарушений %d)" % bad)
		print("  доля воды области: маска рек %.4f, снимок %.4f" % [w_riv / wf.size(), w_map / wf.size()])
	t.free()


## z0 по покрову (SH-6, C2 v9): z0 клетки — лог-среднее по долям классов (z0_m П4), p.z0 — лог-среднее
## карты; C_d стенки и u* замыкания — по столбцу (лес > луг), без карты — прежние скаляры; детерминизм.
func test_z0_cells_synthetic() -> void:
	var p := _syn_place()
	var layer: HeightLayer = p[0]
	var riv: Image = p[1]
	var sf := AirPlace.surface_of(p[2], layer, riv)
	check(sf != null, "снимок построен")
	if sf == null:
		return
	var classes: Dictionary = SurfaceHeat.config().classes
	var z_for := float(classes.forest.z0_m)
	var z_gr := float(classes.grass.z0_m)
	var z_wat := float(classes.water.z0_m)
	var loc := {id = "syn", center_lat = 50.75, center_lon = 86.13, utc_offset_h = 7.0}
	var c := AirWindowCase.window_at(
		layer, riv, loc, 400.0, -800.0, -800.0, 12.0, 3.0, 150.0, NAN, "clear", true, {}, 4, 1.0, sf
	)
	check(c != null and c.z0_map.size() == 16, "карта z0 окна ny·nx")
	if c == null or c.z0_map.size() != 16:
		return
	approx(c.z0_map[0], z_for, 1e-9, "клетка (0, 0): лес — z0 леса")
	approx(c.z0_map[1 * 4 + 1], exp(0.75 * log(z_for) + 0.25 * log(z_gr)), 1e-9, "клетка (1, 1): лог-среднее 3:1")
	approx(c.z0_map[2 * 4 + 2], z_gr, 1e-9, "клетка (2, 2): луг")
	approx(c.z0_map[0 * 4 + 3], z_wat, 1e-12, "клетка (3, 0): вода")
	approx(float(c.p.z0), AirCase.log_mean(c.z0_map), 1e-12, "p.z0 — лог-среднее карты")
	var m := c.meta()
	check(m.z0 is PackedFloat32Array and (m.z0 as PackedFloat32Array).size() == 16, "meta.z0 — карта ny·nx")
	approx(float(m.z0_eff), float(c.p.z0), 1e-12, "meta.z0_eff = p.z0")
	check(c.prepare(), "prepare с картой z0")
	var nyx := c.nx_h * c.ny_h
	var q_for := 1 * c.nx_h + 1  # столбец (0, 0) с ореолом
	var q_gr := 3 * c.nx_h + 3  # (2, 2)
	var cd_for := float(c.col[AirCase.COL_CD * nyx + q_for])
	var cd_gr := float(c.col[AirCase.COL_CD * nyx + q_gr])
	approx(cd_for, pow(0.4 / log(0.5 * c.dz / z_for), 2.0), 1e-8, "C_d леса = (κ/ln(½dz/z0))²")
	approx(cd_gr, pow(0.4 / log(0.5 * c.dz / z_gr), 2.0), 1e-8, "C_d луга")
	var us_for := float(c.col[AirCase.COL_UST * nyx + q_for])
	var us_gr := float(c.col[AirCase.COL_UST * nyx + q_gr])
	check(cd_for > 2.0 * cd_gr and us_for > us_gr, "лес: C_d %.4f > луг %.4f; u* %.3f > %.3f" % [cd_for, cd_gr, us_for, us_gr])
	# u* столбца — из одного ветра на ½dz: u*·ln(½dz/z0) одинаково у всех столбцов и = u*_обл·ln(½dz/z0_обл)
	var a := 0.5 * c.dz
	approx(us_for * log(a / z_for), us_gr * log(a / z_gr), 1e-5, "u*·ln(½dz/z0) — общий ветер на ½dz")
	approx(us_gr * log(a / z_gr), c.ustar * log(a / float(c.p.z0)), 1e-5, "… = u*_обл·ln(½dz/z0_обл)")
	check(c.h_bl[0] >= c.h_bl[2 * 4 + 2], "h_мех леса ≥ луга")
	# без нагрева — та же карта; повторная сборка — побитно та же
	var nh := c.without_heat()
	check(nh.z0_map == c.z0_map, "without_heat: та же карта z0")
	var c2 := AirWindowCase.window_at(
		layer, riv, loc, 400.0, -800.0, -800.0, 12.0, 3.0, 150.0, NAN, "clear", true, {}, 4, 1.0, sf
	)
	check(c2.z0_map == c.z0_map and c2.prepare() and c2.col == c.col, "две сборки — побитно одинаковые z0 и col")
	# без снимка — без карты: прежний скаляр AirCase.Z0, C_d и u* столбцов = скалярам
	var c0 := AirWindowCase.window_at(
		layer, riv, loc, 400.0, -800.0, -800.0, 12.0, 3.0, 150.0, NAN, "clear", true, {}, 4, 1.0, null
	)
	check(c0.z0_map.is_empty() and float(c0.p.z0) == AirCase.Z0, "без снимка — z0 = AirCase.Z0")
	check(c0.prepare(), "prepare без карты")
	var same := true
	for q in nyx:
		same = same and c0.col[AirCase.COL_CD * nyx + q] == c0.prm[3]
		same = same and c0.col[AirCase.COL_UST * nyx + q] == c0.prm[14]
	check(same, "без карты: C_d и u* столбцов = прежним скалярам prm[P_CD], prm[P_USTAR]")
	check(c0.meta().z0 is float, "без карты: meta.z0 — число")


## WindField с картой z0 (C3 v2): лог-профиль ниже первой клетки и u* — по z0 столбца точки.
func test_z0_wind_field_map() -> void:
	var nx := 4
	var ny := 4
	var nz := 6
	var n := nx * ny * nz
	var u := PackedFloat32Array()
	u.resize(n)
	u.fill(5.0)
	var z := PackedFloat32Array()
	z.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(nx * ny)
	var zm := PackedFloat32Array()
	zm.resize(nx * ny)
	for j in ny:
		for i in nx:
			zm[j * nx + i] = 1.0 if i < 2 else 0.03
	var m := {dx = 100.0, dz = 50.0, x0 = 0.0, y0 = 0.0, z_bot = 0.0, nx = nx, ny = ny, nz = nz, z0 = zm}
	var f := WindField.from_arrays(m, u, z, z, z, z, hc)
	check(f != null, "поле с картой z0")
	if f == null:
		return
	approx(f.z0, exp(0.5 * log(1.0) + 0.5 * log(0.03)), 1e-6, "WindField.z0 — лог-среднее карты")
	var pf := Vector3(50.0, 10.0, -50.0)  # столбец (0, 0): лес
	var pg := Vector3(350.0, 10.0, -50.0)  # столбец (3, 0): луг
	approx(f.z0_at(pf), 1.0, 1e-7, "z0_at: лес")
	approx(f.z0_at(pg), 0.03, 1e-7, "z0_at: луг")
	# первая воздушная клетка — центр 25 м: U(10 м) = 5·ln(10/z0)/ln(25/z0) по своему z0 столбца
	var uf := f.sample(pf, 0.0).length()
	var ug := f.sample(pg, 0.0).length()
	approx(uf, 5.0 * log(10.0) / log(25.0), 1e-4, "лес: U(10 м) по z0 = 1 м")
	approx(ug, 5.0 * log(10.0 / 0.03) / log(25.0 / 0.03), 1e-4, "луг: U(10 м) по z0 = 0,03 м")
	check(uf < ug, "у земли над лесом тише: %.2f < %.2f" % [uf, ug])
	var tf := f.turb_at(Vector3(50.0, 60.0, -50.0), 0.0)
	var tg := f.turb_at(Vector3(350.0, 60.0, -50.0), 0.0)
	check(tf[WindField.T_USTAR] > tg[WindField.T_USTAR], "u* над лесом больше")
	m.z0 = PackedFloat32Array([0.1])
	check(WindField.from_arrays(m, u, z, z, z, z, hc) == null, "карта z0 не того размера — отказ")
