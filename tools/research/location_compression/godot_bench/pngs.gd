extends SceneTree
## godot --headless --path godot_bench --script pngs.gd -- <место>
## PNG-слои -> WebP lossless (Image.save_webp), сравнение пикселей, osm.json -> zstd.
func _init() -> void:
	var place := OS.get_cmdline_user_args()[0]
	var base := ProjectSettings.globalize_path("res://").path_join("../../../../data/terrain").simplify_path().path_join(place)
	var res := {"place": place}
	for f in DirAccess.get_files_at(base):
		if f.ends_with(".png"):
			var img := Image.load_from_file(base.path_join(f))
			var t := Time.get_ticks_usec()
			var fmt := img.get_format()
			img.save_webp("user://t.webp", false, 1.0)
			var wm := (Time.get_ticks_usec() - t) / 1000.0
			t = Time.get_ticks_usec()
			var b := Image.load_from_file(ProjectSettings.globalize_path("user://t.webp"))
			var rm := (Time.get_ticks_usec() - t) / 1000.0
			var t2 := Time.get_ticks_usec()
			var p0 := Image.load_from_file(base.path_join(f))
			var pm := (Time.get_ticks_usec() - t2) / 1000.0
			var a := img.get_data()
			var same := true
			var bf := b.get_format()
			# сравнить первый канал(ы): webp вернёт RGB8/RGBA8
			if fmt == Image.FORMAT_L8:
				b.convert(Image.FORMAT_L8)
				same = b.get_data() == a
			elif fmt == Image.FORMAT_LA8:
				var bb := b.duplicate()
				bb.convert(Image.FORMAT_LA8)
				same = bb.get_data() == a
			res[f] = {"fmt": fmt, "webp_fmt": bf, "png_bytes": FileAccess.get_file_as_bytes(base.path_join(f)).size(), "webp_bytes": FileAccess.get_file_as_bytes("user://t.webp").size(), "webp_write_ms": wm, "webp_read_ms": rm, "png_read_ms": pm, "same": same}
	var raw := FileAccess.get_file_as_bytes(base.path_join("osm.json"))
	var t := Time.get_ticks_usec()
	var c := raw.compress(FileAccess.COMPRESSION_ZSTD)
	res["osm_json"] = {"raw": raw.size(), "zstd": c.size(), "ms": (Time.get_ticks_usec() - t) / 1000.0, "level": ProjectSettings.get_setting("compression/formats/zstd/compression_level", 3)}
	print("RESULT " + JSON.stringify(res))
	quit()
