extends SceneTree
## Разовый перевод папки места из старого формата (.f32.zst + PNG) в N5 (WebP lossless):
## высоты — RGB8 24 бит от минимума, шаг 1/8 м; растры — WebP с теми же значениями.
## Правит meta.json, surface.json, build.json (format_version); старые файлы удаляет.
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s res://tools/terrain/convert_place_webp.gd -- data/terrain/altai ...

const STEP := 0.125


func _initialize() -> void:
	for d in OS.get_cmdline_user_args():
		_convert(ProjectSettings.globalize_path("res://").path_join(d))
	quit()


func _convert(dir: String) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	for info: Dictionary in meta.layers:
		var w := int(info.width)
		var h := int(info.height)
		var raw := FileAccess.get_file_as_bytes(dir.path_join(info.file)).decompress(w * h * 4, FileAccess.COMPRESSION_ZSTD)
		var hs := raw.to_float32_array()
		var mn := hs[0]
		for v in hs:
			mn = minf(mn, v)
		var img: Image = load("res://scripts/terrain/height_layer.gd").encode_rgb24(hs, w, h, mn, STEP)
		DirAccess.remove_absolute(dir.path_join(info.file))
		info.file = "%s.webp" % info.id
		img.save_webp(dir.path_join(info.file), false)
		info.height_min_m = mn
		info.height_step_m = STEP
		info.min_height_m = mn
		var wf := String(info.water_file)
		info.water_file = wf.get_basename() + ".webp"
		_png_to_webp(dir, wf, false)
	_write(dir.path_join("meta.json"), meta)
	var surf: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("surface.json")))
	for l: Dictionary in surf.layers:
		l.file = _png_to_webp(dir, l.file, false)
		if l.has("detail10"):
			l.detail10.file = _png_to_webp(dir, l.detail10.file, true)
		if l.has("built10"):
			l.built10.file = _png_to_webp(dir, l.built10.file, false)
	_write(dir.path_join("surface.json"), surf)
	var b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("build.json")))
	b.erase("builder_version")
	b.format_version = Locations.FORMAT_VERSION
	_write(dir.path_join("build.json"), b)
	# .import: WebP — не текстуры (как у прежних масок)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".webp") and not FileAccess.file_exists(dir.path_join(f + ".import")):
			var imp := FileAccess.open(dir.path_join(f + ".import"), FileAccess.WRITE)
			imp.store_string("[remap]\n\nimporter=\"keep\"\n")
			imp.close()
	print("converted ", dir)


func _png_to_webp(dir: String, png: String, la8: bool) -> String:
	var img := Image.load_from_file(dir.path_join(png))
	img.convert(Image.FORMAT_RGBA8 if la8 else Image.FORMAT_RGB8)
	var out := png.get_basename() + ".webp"
	img.save_webp(dir.path_join(out), false)
	DirAccess.remove_absolute(dir.path_join(png))
	DirAccess.remove_absolute(dir.path_join(png + ".import"))
	return out


## JSON.parse_string даёт числа float; целые поля возвращаем в int (иначе «1601.0» в файле).
func _ints(v: Variant) -> void:
	if v is Dictionary:
		for k in v:
			if v[k] is float and k in ["width", "height", "patches", "net_requests"]:
				v[k] = int(v[k])
			else:
				_ints(v[k])
	elif v is Array:
		for x in v:
			_ints(x)


func _write(path: String, d: Dictionary) -> void:
	_ints(d)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", true) + "\n")
	f.close()
