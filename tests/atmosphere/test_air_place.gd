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
	# эталон снят по таблицам (Python, без климата места): суточная амплитуда — таблица diurnal.range_k
	ClimateGrid.set_paths({"hh5": "res://data/climate/__none5.bin"})
	_domain_input_vs_reference()
	ClimateGrid.set_paths({})


func _domain_input_vs_reference() -> void:
	var lw := load_detail("ongudai")
	check(lw.size() == 2 and lw[0] != null, "слой detail Онгудая")
	if lw.size() != 2:
		return
	var loc := load_loc("ongudai")
	for dx in [400.0, 200.0]:
		var m := TestAirPicard.load_fix(FIX + "ongudai_d%d_h12" % int(dx))
		var tm := float(m.day.t_max)  # Tmax, с которой снят эталон (без климата места)
		var t0 := Time.get_ticks_msec()
		var c := AirPlace.domain_case(lw[0], lw[1], loc, dx, 12.0, 3.0, 150.0, tm)
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
		var e_q := _max_diff_64(c.heat, expected_heat(c, lw[0], lw[1], loc, 12.0, 3.0, tm, null))
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
			var cu := c if u == 3.0 else AirPlace.domain_case(lw[0], lw[1], loc, dx, 12.0, u, 150.0, tm)
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


## Tmax таблицы typical_max_c без климата места (так сняты эталоны и так считает случай при тесте без ctx).
static func table_t_max(detail: HeightLayer, loc: Dictionary) -> float:
	var cfg := WeatherModel.config()
	var ctx := AirPlace.context(detail, loc, cfg)
	return WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)


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

