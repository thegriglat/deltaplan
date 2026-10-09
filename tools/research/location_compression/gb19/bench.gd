extends SceneTree
## godot --headless --path godot_bench --script bench.gd -- <место> <слой>
## Пишет в user:// (XDG_DATA_HOME временный), печатает JSON с размерами/временем/ошибкой.

const ROOT := "res://../../../../data/terrain"

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var place := a[0]
	var lid := a[1]
	var base := ProjectSettings.globalize_path("res://").path_join("../../../../data/terrain").simplify_path()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base.path_join(place).path_join("meta.json")))
	var li: Dictionary
	for l in meta.layers:
		if l.id == lid:
			li = l
	var w := int(li.width)
	var h := int(li.height)
	var packed := FileAccess.get_file_as_bytes(base.path_join(place).path_join(li.file))
	var raw := packed.decompress(w * h * 4, FileAccess.COMPRESSION_ZSTD)
	var hs := raw.to_float32_array()
	var out := {"place": place, "layer": lid, "zstd_level": ProjectSettings.get_setting("compression/formats/zstd/compression_level", 3), "ldm": ProjectSettings.get_setting("compression/formats/zstd/long_distance_matching", false), "wlog": ProjectSettings.get_setting("compression/formats/zstd/window_log_size", 27)}
	var mn := hs[0]
	for v in hs:
		mn = minf(mn, v)
	# 0. f32 zstd как сейчас
	var t := Time.get_ticks_usec()
	var c := raw.compress(FileAccess.COMPRESSION_ZSTD)
	out["f32_zstd"] = {"bytes": c.size(), "write_ms": (Time.get_ticks_usec() - t) / 1000.0}
	t = Time.get_ticks_usec()
	var d := c.decompress(raw.size(), FileAccess.COMPRESSION_ZSTD)
	out["f32_zstd"]["read_ms"] = (Time.get_ticks_usec() - t) / 1000.0
	# 1. квантование 1/32 -> целые q (смещение от минимума)
	var Q := float(a[2]) if a.size() > 2 else 32.0
	out["Q"] = Q
	var q := PackedInt32Array()
	q.resize(w * h)
	for i in w * h:
		q[i] = int(roundf((hs[i] - mn) * Q))
	# 1a. u16 raw (если влезает) / 3 байта; 1b. дельта по строке + zigzag + byte shuffle
	out["delta_shuffle"] = _delta_variant(q, w, h, mn, Q, hs)
	# 2. EXR float / half
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RF, raw)
	out["exr_rf"] = _img_variant(img, "exr", hs, w, h, 1.0)
	var imh := img.duplicate()
	imh.convert(Image.FORMAT_RH)
	out["exr_rh"] = _img_variant(imh, "exr", hs, w, h, 1.0)
	# 3. RGB-кодирование 24 бит (hi, mid, lo) -> PNG/WebP lossless
	var rgb := PackedByteArray()
	rgb.resize(w * h * 3)
	for i in w * h:
		var v := q[i]
		rgb[i * 3] = (v >> 16) & 255
		rgb[i * 3 + 1] = (v >> 8) & 255
		rgb[i * 3 + 2] = v & 255
	var ir := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb)
	out["png_rgb24"] = _rgb_variant(ir, "png", q, w, h)
	out["webp_lossless_rgb24"] = _rgb_variant(ir, "webp", q, w, h)
	# 3b. RG8: 16 бит (hi, lo) при шаге 1/Q16, чтобы влезло
	var rng := 0.0
	for v in hs:
		rng = maxf(rng, v - mn)
	var q16 := floorf(65535.0 / rng * 1.0)
	q16 = minf(q16, 32.0)
	var rg := PackedByteArray()
	rg.resize(w * h * 2)
	for i in w * h:
		var v := int(roundf((hs[i] - mn) * q16))
		rg[i * 2] = (v >> 8) & 255
		rg[i * 2 + 1] = v & 255
	var irg := Image.create_from_data(w, h, false, Image.FORMAT_RG8, rg)
	out["png_rg16_step"] = 1.0 / q16
	out["png_rg16"] = _rg_variant(irg, "png", hs, mn, q16, w, h)
	# 4. 16-бит PNG напрямую?
	var i16 := Image.create_from_data(w, h, false, Image.FORMAT_RH, imh.get_data())
	i16.save_png("user://t16.png")
	var back := Image.load_from_file(ProjectSettings.globalize_path("user://t16.png"))
	out["png_RH_direct"] = {"bytes": FileAccess.get_file_as_bytes("user://t16.png").size(), "readback_format": back.get_format()}
	print("RESULT " + JSON.stringify(out))
	quit()


func _delta_variant(q: PackedInt32Array, w: int, h: int, mn: float, Q: float, hs: PackedFloat32Array) -> Dictionary:
	var t := Time.get_ticks_usec()
	var n := w * h
	# предсказатель: среднее W и N (floor), zigzag, 3 плоскости байт
	var zz := PackedInt32Array()
	zz.resize(n)
	for j in h:
		var row := j * w
		for i in w:
			var p := 0
			if j > 0 and i > 0:
				p = (q[row + i - 1] + q[row - w + i]) >> 1
			elif i > 0:
				p = q[row + i - 1]
			elif j > 0:
				p = q[row - w + i]
			var dd := q[row + i] - p
			zz[row + i] = (dd << 1) ^ (dd >> 31)
	var buf := PackedByteArray()
	buf.resize(n * 2)
	var over := 0
	for i in n:
		var v := zz[i]
		if v > 65535:
			over += 1
		buf[i] = v & 255
		buf[n + i] = (v >> 8) & 255
	var enc_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var c := buf.compress(FileAccess.COMPRESSION_ZSTD)
	var zms := (Time.get_ticks_usec() - t) / 1000.0
	# чтение
	t = Time.get_ticks_usec()
	var b2 := c.decompress(n * 2, FileAccess.COMPRESSION_ZSTD)
	var zr := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var out := PackedFloat32Array()
	out.resize(n)
	var qq := PackedInt32Array()
	qq.resize(n)
	var inv := 1.0 / Q
	for j in h:
		var row := j * w
		for i in w:
			var v := b2[row + i] | (b2[n + row + i] << 8)
			var dd := (v >> 1) ^ -(v & 1)
			var p := 0
			if j > 0 and i > 0:
				p = (qq[row + i - 1] + qq[row - w + i]) >> 1
			elif i > 0:
				p = qq[row + i - 1]
			elif j > 0:
				p = qq[row - w + i]
			var x := p + dd
			qq[row + i] = x
			out[row + i] = x * inv + mn
	var dec_ms := (Time.get_ticks_usec() - t) / 1000.0
	var me := 0.0
	for i in n:
		me = maxf(me, absf(out[i] - hs[i]))
	return {"bytes": c.size(), "overflow16": over, "encode_gd_ms": enc_ms, "zstd_write_ms": zms, "zstd_read_ms": zr, "decode_gd_ms": dec_ms, "max_err": me}


func _img_variant(img: Image, kind: String, hs: PackedFloat32Array, w: int, h: int, _s: float) -> Dictionary:
	var t := Time.get_ticks_usec()
	img.save_exr("user://t.exr", false)
	var wm := (Time.get_ticks_usec() - t) / 1000.0
	var sz := FileAccess.get_file_as_bytes("user://t.exr").size()
	t = Time.get_ticks_usec()
	var b := Image.load_from_file(ProjectSettings.globalize_path("user://t.exr"))
	var rm := (Time.get_ticks_usec() - t) / 1000.0
	var me := 0.0
	if b.get_format() != Image.FORMAT_RF:
		b.convert(Image.FORMAT_RF)
	var d := b.get_data().to_float32_array()
	for i in w * h:
		me = maxf(me, absf(d[i] - hs[i]))
	return {"bytes": sz, "write_ms": wm, "read_ms": rm, "max_err": me}


func _rgb_variant(img: Image, kind: String, q: PackedInt32Array, w: int, h: int) -> Dictionary:
	var path := "user://t." + kind
	var t := Time.get_ticks_usec()
	if kind == "png":
		img.save_png(path)
	else:
		img.save_webp(path, false, 1.0)
	var wm := (Time.get_ticks_usec() - t) / 1000.0
	var sz := FileAccess.get_file_as_bytes(path).size()
	t = Time.get_ticks_usec()
	var b := Image.load_from_file(ProjectSettings.globalize_path(path))
	var rm := (Time.get_ticks_usec() - t) / 1000.0
	b.convert(Image.FORMAT_RGB8)
	var d := b.get_data()
	var bad := 0
	for i in w * h:
		if ((d[i * 3] << 16) | (d[i * 3 + 1] << 8) | d[i * 3 + 2]) != q[i]:
			bad += 1
	return {"bytes": sz, "write_ms": wm, "read_ms": rm, "mismatch": bad}


func _rg_variant(img: Image, kind: String, hs: PackedFloat32Array, mn: float, q16: float, w: int, h: int) -> Dictionary:
	var t := Time.get_ticks_usec()
	img.save_png("user://t2.png")
	var wm := (Time.get_ticks_usec() - t) / 1000.0
	var sz := FileAccess.get_file_as_bytes("user://t2.png").size()
	t = Time.get_ticks_usec()
	var b := Image.load_from_file(ProjectSettings.globalize_path("user://t2.png"))
	var rm := (Time.get_ticks_usec() - t) / 1000.0
	return {"bytes": sz, "write_ms": wm, "read_ms": rm, "format": b.get_format()}
