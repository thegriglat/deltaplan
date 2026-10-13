extends TestCase
## Слой высот в файле (N5): WebP lossless, 24 бит в RGB8, смещение от минимума, шаг height_step_m.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=height_layer


func _info(w: int, h: int, mn: float, step: float) -> Dictionary:
	return {"id": "t", "width": w, "height": h, "spacing_m": 25.0, "origin_x_m": -50.0, "origin_z_m": -50.0,
		"height_min_m": mn, "height_step_m": step}


func test_roundtrip_within_half_step() -> void:
	var w := 700
	var h := 400  # больше одной порции параллельного кодирования
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var hs := PackedFloat32Array()
	hs.resize(w * h)
	for k in hs.size():
		hs[k] = -10.0 + rng.randf() * 2400.0
	var mn := hs[0]
	for v in hs:
		mn = minf(mn, v)
	var path := "user://test_height_layer.webp"
	check(HeightLayer.encode_rgb24(hs, w, h, mn, 0.03125).save_webp(path, false) == OK, "WebP записан")
	var l := HeightLayer.load_from_file(path, _info(w, h, mn, 0.03125))
	check(l != null and l.heights.size() == hs.size(), "слой читается")
	if l == null:
		return
	var worst := 0.0
	for k in hs.size():
		worst = maxf(worst, absf(l.heights[k] - hs[k]))
	check(worst <= 0.015625 + 1e-4, "ошибка ≤ шаг/2: %.5f" % worst)
	check(is_equal_approx(l.heights[0], hs[0]) or absf(l.heights[0] - hs[0]) <= 0.015625, "первый узел")
	var many := HeightLayer.load_files("user://", [{"file": "test_height_layer.webp"}, {"file": "nope.webp"}].map(
		func(d: Dictionary) -> Dictionary: return _info(w, h, mn, 0.03125).merged(d, true)))
	check(many[0] != null and many[1] == null, "load_files: параллельно, отсутствующий файл — null")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_wrong_size_is_error() -> void:
	var hs := PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	var path := "user://test_height_layer2.webp"
	HeightLayer.encode_rgb24(hs, 2, 2, 1.0, 0.03125).save_webp(path, false)
	check(HeightLayer.load_from_file(path, _info(3, 3, 1.0, 0.03125)) == null, "размер не совпал — null")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Пирамида максимумов (MLK-К2 v2): каждый тексель уровня k — максимум своих узлов, нечётный край не
## теряется; текстура — уровень 1 + свои мипы (max), не среднее.
func test_max_pyramid_matches_brute_force() -> void:
	var w := 37
	var h := 23
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var hs := PackedFloat32Array()
	hs.resize(w * h)
	for k in hs.size():
		hs[k] = rng.randf() * 1000.0
	var l := HeightLayer.from_heights("t", w, h, 25.0, 0.0, 0.0, hs)
	var pyr := l.max_pyramid()
	check(pyr.size() == 5, "уровни до 1×1 (37×23 → 18×11 … 1×1): %d" % pyr.size())
	var bad := 0
	for k in range(1, pyr.size() + 1):
		var kw := maxi(1, w >> k)
		var kh := maxi(1, h >> k)
		for j in kh:
			for i in kw:
				var i1 := w - 1 if i == kw - 1 else ((i + 1) << k) - 1
				var j1 := h - 1 if j == kh - 1 else ((j + 1) << k) - 1
				var m := -INF
				for jj in range(j << k, j1 + 1):
					for ii in range(i << k, i1 + 1):
						m = maxf(m, hs[jj * w + ii])
				if l.max_texel(k, i, j) != m:
					bad += 1
	check(bad == 0, "максимумы совпадают с перебором (расхождений %d)" % bad)
	check(l.max_texel(pyr.size(), 0, 0) == l.max_h, "верхний уровень = максимум слоя")
	var tex := l.make_max_texture()
	var img := tex.get_image()
	check(img.get_width() == 18 and img.get_height() == 11 and img.has_mipmaps(), "текстура: уровень 1 + мипы")
	var mip_ofs := img.get_mipmap_offset(1)
	var top := img.get_data().slice(mip_ofs, mip_ofs + 4).decode_float(0)
	check(is_equal_approx(top, l.max_texel(2, 0, 0)), "мип 1 текстуры — уровень 2 пирамиды (max)")
