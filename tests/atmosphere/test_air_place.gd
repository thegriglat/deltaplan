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

