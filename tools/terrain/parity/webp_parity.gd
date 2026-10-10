extends SceneTree
## Сравнение файлов мест N5 (WebP) со старыми (float32 .f32.zst + PNG). Аргументы после "--":
## <старый_корень> <новый_корень> [--time]; корни — папки с <id>/ (data/terrain). Печатает
## max_dh_m (высоты против float32), raster_mismatch (несовпавших байт во всех растрах),
## с --time — read_ratio (новое/старое время чтения мест: высоты и все растры, лучшее из 3).

const REPS := 3


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := Array(OS.get_cmdline_user_args())
	var timed := args.has("--time")
	args.erase("--time")
	var old_root: String = args[0]
	var new_root: String = args[1]
	var hl: GDScript = load("res://scripts/terrain/height_layer.gd")
	var sl: GDScript = load("res://scripts/terrain/surface_layer.gd")
	var max_dh := 0.0
	var mism := 0
	var pixels := 0
	var t_old := 0.0
	var t_new := 0.0
	for id in DirAccess.get_directories_at(new_root):
		var od := old_root.path_join(id)
		var nd := new_root.path_join(id)
		if not DirAccess.dir_exists_absolute(od):
			continue
		var ometa: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(od.path_join("meta.json")))
		var nmeta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(nd.path_join("meta.json")))
		for k in ometa.layers.size():
			var oi: Dictionary = ometa.layers[k]
			var ni: Dictionary = nmeta.layers[k]
			var old_h := _old_heights(od.path_join(oi.file), oi)
			var nl = hl.load_from_file(nd.path_join(ni.file), ni)
			if nl == null or nl.heights.size() != old_h.size():
				max_dh = INF
				continue
			for j in old_h.size():
				max_dh = maxf(max_dh, absf(old_h[j] - nl.heights[j]))
		# растры: старые PNG против новых WebP (после приведения к прежнему формату)
		for f in DirAccess.get_files_at(od):
			if not f.ends_with(".png"):
				continue
			var a := Image.load_from_file(od.path_join(f))
			var b := _new_raster(sl, nd.path_join(f.get_basename() + ".webp"), a.get_format())
			if b == null or b.get_format() != a.get_format() or b.get_width() != a.get_width() or b.get_height() != a.get_height():
				mism += a.get_width() * a.get_height()
				continue
			var da := a.get_data()
			var db := b.get_data()
			var cs := 2 if a.get_format() == Image.FORMAT_LA8 else 1
			if da != db:
				for p in a.get_width() * a.get_height():
					if da[p * cs] != db[p * cs] or (cs == 2 and da[p * cs + 1] != db[p * cs + 1]):
						mism += 1
			pixels += a.get_width() * a.get_height()
		if timed:
			t_old += _best(func() -> void: _read_old(od, ometa))
			t_new += _best(func() -> void: _read_new(nd, nmeta, hl, sl))
	print("max_dh_m %.5f" % max_dh)
	print("raster_mismatch %d" % mism)
	print("raster_pixels %d" % pixels)
	if timed:
		print("read_old_s %.3f" % t_old)
		print("read_new_s %.3f" % t_new)
		print("read_ratio %.2f" % (t_new / maxf(t_old, 1e-6)))
	quit()


func _best(fn: Callable) -> float:
	var best := INF
	for r in REPS:
		var t0 := Time.get_ticks_usec()
		fn.call()
		best = minf(best, (Time.get_ticks_usec() - t0) / 1e6)
	return best


func _old_heights(path: String, info: Dictionary) -> PackedFloat32Array:
	var n := int(info.width) * int(info.height)
	return FileAccess.get_file_as_bytes(path).decompress(n * 4, FileAccess.COMPRESSION_ZSTD).to_float32_array()


## Новый растр, приведённый к формату старого (L8 / LA8), как это делают читатели игры.
func _new_raster(sl: GDScript, path: String, fmt: int) -> Image:
	if fmt == Image.FORMAT_LA8:
		return sl.decode_detail10(path)
	var img := Image.new()
	if img.load_webp_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	img.convert(fmt)
	return img


## Чтение места по-старому: высоты zstd + все PNG байтами (как читал игровой код).
func _read_old(dir: String, meta: Dictionary) -> void:
	for info: Dictionary in meta.layers:
		_old_heights(dir.path_join(info.file), info)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".png"):
			var img := Image.new()
			img.load_png_from_buffer(FileAccess.get_file_as_bytes(dir.path_join(f)))


func _read_new(dir: String, meta: Dictionary, hl: GDScript, sl: GDScript) -> void:
	for info: Dictionary in meta.layers:
		hl.load_from_file(dir.path_join(info.file), info)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with("detail10.webp"):
			sl.decode_detail10(dir.path_join(f))
		elif f.ends_with(".webp") and not f.begins_with("detail.") and not f.begins_with("far."):
			var img := Image.new()
			img.load_webp_from_buffer(FileAccess.get_file_as_bytes(dir.path_join(f)))
			img.convert(Image.FORMAT_L8)
