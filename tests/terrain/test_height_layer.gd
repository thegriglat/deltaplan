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
	check(HeightLayer.encode_rgb24(hs, w, h, mn, 0.125).save_webp(path, false) == OK, "WebP записан")
	var l := HeightLayer.load_from_file(path, _info(w, h, mn, 0.125))
	check(l != null and l.heights.size() == hs.size(), "слой читается")
	if l == null:
		return
	var worst := 0.0
	for k in hs.size():
		worst = maxf(worst, absf(l.heights[k] - hs[k]))
	check(worst <= 0.0625 + 1e-4, "ошибка ≤ шаг/2: %.5f" % worst)
	check(is_equal_approx(l.heights[0], hs[0]) or absf(l.heights[0] - hs[0]) <= 0.0625, "первый узел")
	var many := HeightLayer.load_files("user://", [{"file": "test_height_layer.webp"}, {"file": "nope.webp"}].map(
		func(d: Dictionary) -> Dictionary: return _info(w, h, mn, 0.125).merged(d, true)))
	check(many[0] != null and many[1] == null, "load_files: параллельно, отсутствующий файл — null")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_wrong_size_is_error() -> void:
	var hs := PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	var path := "user://test_height_layer2.webp"
	HeightLayer.encode_rgb24(hs, 2, 2, 1.0, 0.125).save_webp(path, false)
	check(HeightLayer.load_from_file(path, _info(3, 3, 1.0, 0.125)) == null, "размер не совпал — null")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
