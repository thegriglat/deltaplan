extends TestCase
## SL-К7 v1: горизонт к солнцу упакован в канал A relief_tex (бывший relief_shadow_tex, R8):
## A = round(горизонт/60°·255) — те же байты, что был R8; RGB — прежние поля (влажность, AO,
## северность), побитово; смена азимута переписывает только A.
## Запуск — godot --headless --path . res://tests/run_tests.tscn -- --filter=test_relief_pack

const SPACING := 25.0
const N := 81


## Гребни вдоль Z с наклоном — есть и тень, и влажность.
func _ridges() -> HeightLayer:
	var data := PackedFloat32Array()
	data.resize(N * N)
	var o := -(N - 1) * SPACING * 0.5
	for j in N:
		for i in N:
			var x := o + i * SPACING
			var z := o + j * SPACING
			data[j * N + i] = 500.0 + 100.0 * cos(TAU * x / 1000.0) + 0.05 * z
	return HeightLayer.from_heights("detail", N, N, SPACING, o, o, data)


func _cfg() -> Dictionary:
	return Config.get_config("world").get("surface", {}).get("relief", {})


## Эталон: байты прежних текстур (relief_tex RGB и relief_shadow_tex R8) по float-полям.
func _expect(r: TerrainRelief, k: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out[0] = int(clampf(r.moisture[k], 0.0, 1.0) * 255.0 + 0.5)
	out[1] = int(clampf(r.ao[k], 0.0, 1.0) * 255.0 + 0.5)
	out[2] = int(clampf(r.north[k] * 0.5 + 0.5, 0.0, 1.0) * 255.0 + 0.5)
	out[3] = mini(int(r.horizon_deg[k] * 255.0 / TerrainRelief.HORIZON_MAX_DEG + 0.5), 255)
	return out


func _mismatch(r: TerrainRelief) -> int:
	var data := r.texture_bytes()
	var bad := 0
	for k in r.width * r.height:
		var e := _expect(r, k)
		for c in 4:
			if data[k * 4 + c] != e[c]:
				bad += 1
	return bad


func test_channels_equal_sources() -> void:
	var r := TerrainRelief.compute(_ridges(), _cfg(), 90.0)
	check(r.texture != null, "текстура полей есть")
	check(r.texture.get_format() == Image.FORMAT_RGBA8, "RGBA8")
	check(r.texture_bytes().size() == r.width * r.height * 4, "размер байтов = сетка relief × 4")
	check(_mismatch(r) == 0, "RGB = поля, A = горизонт (побитово), расхождений: %d" % _mismatch(r))
	var shade := 0
	for k in r.width * r.height:
		if r.texture_bytes()[k * 4 + 3] > 0:
			shade += 1
	check(shade > 0, "в A есть ненулевой горизонт (тень гребней): %d" % shade)


func test_azimuth_rewrites_only_alpha() -> void:
	var r := TerrainRelief.compute(_ridges(), _cfg(), 90.0)
	var before := r.texture_bytes().duplicate()
	var tex := r.texture
	r.recompute_horizon(270.0)
	r.update_shadow_texture()
	var after := r.texture_bytes()
	check(r.texture == tex, "текстура обновлена на месте")
	var rgb_changed := 0
	var a_changed := 0
	for k in r.width * r.height:
		for c in 3:
			if after[k * 4 + c] != before[k * 4 + c]:
				rgb_changed += 1
		if after[k * 4 + 3] != before[k * 4 + 3]:
			a_changed += 1
	check(rgb_changed == 0, "RGB не меняется при смене азимута: %d" % rgb_changed)
	check(a_changed > 0, "A меняется при смене азимута: %d" % a_changed)
	check(_mismatch(r) == 0, "после смены азимута A = новый горизонт: %d" % _mismatch(r))


func test_no_shadow_texture_uniform() -> void:
	for p in [
		"res://scripts/terrain/terrain_main.gdshaderinc",
		"res://scripts/terrain/scene_look.gdshaderinc",
		"res://scripts/terrain/meadow_look.gdshaderinc",
	]:
		var t := FileAccess.get_file_as_string(p)
		check(not t.contains("relief_shadow_tex"), "%s без relief_shadow_tex" % p)
	var main := FileAccess.get_file_as_string("res://scripts/terrain/terrain_main.gdshaderinc")
	check(main.contains("hz_deg = rel.a * 60.0"), "горизонт — из A relief_tex")
