extends TestCase
## Кеш пирамиды максимумов в папке места (FL-8): из кеша — те же байты, что расчёт; чужой или
## битый файл — пересчёт и перезапись без падения.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=height_cache

const DIR := "user://test_height_cache"


func _info(w: int, h: int) -> Dictionary:
	return {"id": "t", "file": "t.webp", "width": w, "height": h, "spacing_m": 25.0,
		"origin_x_m": 0.0, "origin_z_m": 0.0, "height_min_m": 0.0, "height_step_m": 0.03125}


func _write_webp(w: int, h: int, seed_: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var hs := PackedFloat32Array()
	hs.resize(w * h)
	for k in hs.size():
		hs[k] = rng.randf() * 2000.0
	DirAccess.make_dir_recursive_absolute(DIR)
	HeightLayer.encode_rgb24(hs, w, h, 0.0, 0.03125).save_webp(DIR.path_join("t.webp"), false)


## Пирамида и текстура посчитанные заново (слой из массива — без кеша).
func _fresh(l: HeightLayer) -> Array:
	var ref := HeightLayer.from_heights("t", l.width, l.height, 25.0, 0.0, 0.0, l.heights)
	return [ref.max_pyramid(), ref.make_max_texture().get_image().get_data()]


func _load(w: int, h: int) -> HeightLayer:
	return HeightLayer.load_files(DIR, [_info(w, h)])[0]


func _cleanup() -> void:
	LocationCache.remove_dir(DIR)


func test_cache_same_bytes_as_compute() -> void:
	_cleanup()
	var w := 301
	var h := 157  # нечётные края, больше одной полосы строк
	_write_webp(w, h, 3)
	var l1 := _load(w, h)
	check(l1 != null and l1._max_pyr.is_empty(), "первая загрузка: кеша нет")
	var ref := _fresh(l1)
	var t1 := l1.make_max_texture().get_image().get_data()
	l1.wait_cache_write()
	check(t1 == ref[1], "расчёт: текстура как у слоя без кеша")
	check(FileAccess.file_exists(l1.max_cache_path()), "кеш записан: %s" % l1.max_cache_path())
	check(l1.max_cache_path().begins_with(DIR.path_join("cache")), "кеш — в подпапке cache/ места")
	var l2 := _load(w, h)
	check(not l2._max_pyr.is_empty(), "вторая загрузка: пирамида из кеша")
	var same: bool = l2._max_pyr.size() == (ref[0] as Array).size()
	for k in mini(l2._max_pyr.size(), (ref[0] as Array).size()):
		same = same and (l2._max_pyr[k] as PackedFloat32Array) == (ref[0][k] as PackedFloat32Array)
	check(same, "пирамида из кеша бит-в-бит как расчёт")
	var t2 := l2.make_max_texture().get_image().get_data()
	check(t2 == ref[1], "текстура из кеша бит-в-бит как расчёт")
	check(l2.max_texel(3, 5, 4) == l1.max_texel(3, 5, 4), "max_texel тот же")
	_cleanup()


func test_foreign_or_broken_recomputed() -> void:
	_cleanup()
	var w := 65
	var h := 40
	_write_webp(w, h, 5)
	var l1 := _load(w, h)
	l1.make_max_texture()
	l1.wait_cache_write()
	var path := l1.max_cache_path()
	# другие высоты того же размера — ключ не совпал
	_write_webp(w, h, 6)
	var l2 := _load(w, h)
	check(l2._max_pyr.is_empty(), "чужой кеш (другой файл высот) не принят")
	check(l2.make_max_texture().get_image().get_data() == _fresh(l2)[1], "пересчёт верный")
	l2.wait_cache_write()
	check(_load(w, h).load_cached_max_pyramid(), "кеш перезаписан под новый файл")
	# обрезанный файл
	var bytes := FileAccess.get_file_as_bytes(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes.slice(0, bytes.size() - 7))
	f.close()
	var l3 := _load(w, h)
	check(l3 != null and l3._max_pyr.is_empty(), "обрезанный кеш не принят")
	# мусор в теле той же длины
	var junk := bytes.duplicate()
	for k in range(bytes.size() - 40, bytes.size()):
		junk[k] = k & 255
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(junk)
	f.close()
	var l4 := _load(w, h)
	check(l4 != null, "битый кеш — без падения")
	if not l4._max_pyr.is_empty():
		check(l4._max_pyr == _fresh(l4)[0], "битый кеш принят только если тело совпало")
	# пустой файл
	f = FileAccess.open(path, FileAccess.WRITE)
	f.close()
	var l5 := _load(w, h)
	check(l5._max_pyr.is_empty(), "пустой кеш не принят")
	check(l5.make_max_texture().get_image().get_data() == _fresh(l5)[1], "после битого — пересчёт")
	l5.wait_cache_write()
	check(_load(w, h).load_cached_max_pyramid(), "битый кеш перезаписан")
	_cleanup()


func test_res_data_cached_in_user() -> void:
	var p := HeightCache.path_for("res://data/locations/isl/far.webp", "far", "maxpyr")
	check(p.begins_with(HeightCache.RES_ROOT), "кеш данных из res:// — в user://: %s" % p)
	var l := HeightLayer.from_heights("t", 9, 9, 25.0, 0.0, 0.0, PackedFloat32Array())
	check(l.max_cache_path() == "" and not l.load_cached_max_pyramid(), "слой из массива — без кеша")
