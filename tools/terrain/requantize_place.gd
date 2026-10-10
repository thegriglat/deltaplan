extends SceneTree
## Разовая пересборка высот фикстуры места с новым шагом из исходных float32 (.f32.zst, квантование 1/32):
##   godot --headless --path . -s res://tools/terrain/requantize_place.gd -- <папка_места> <папка_с_f32.zst>
## Печатает max ошибку против float32 по слоям, правит meta.json и build.json (format_version).

const STEP := 0.03125


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_run(ProjectSettings.globalize_path("res://").path_join(a[0]), a[1])
	quit()


func _run(dir: String, f32dir: String) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	for info: Dictionary in meta.layers:
		var w := int(info.width)
		var h := int(info.height)
		var raw := FileAccess.get_file_as_bytes(f32dir.path_join("%s.f32.zst" % info.id)).decompress(
			w * h * 4, FileAccess.COMPRESSION_ZSTD
		)
		var hs := raw.to_float32_array()
		var mn := hs[0]
		for v in hs:
			mn = minf(mn, v)
		var img: Image = load("res://scripts/terrain/height_layer.gd").encode_rgb24(hs, w, h, mn, STEP)
		img.save_webp(dir.path_join(info.file), false)
		var back: PackedFloat32Array = load("res://scripts/terrain/height_layer.gd").decode_rgb24(
			img.get_data(), w * h, mn, STEP
		)
		var worst := 0.0
		for k in hs.size():
			worst = maxf(worst, absf(back[k] - hs[k]))
		print("%s %s: max ошибка %.6f м, min %.5f" % [dir.get_file(), info.id, worst, mn])
		info.height_min_m = mn
		info.height_step_m = STEP
		info.min_height_m = mn
	_write(dir.path_join("meta.json"), meta)
	var b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("build.json")))
	b.format_version = 3
	_write(dir.path_join("build.json"), b)


func _write(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", true) + "\n")
	f.close()
