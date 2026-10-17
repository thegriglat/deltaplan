class_name CloudFieldCodec
extends RefCounted
## Текстура поля облачности для рендера (CLF-К2) и снимок для сети (CLF-К4).
## RGBA8, nx × ny, пиксель (i, r), r = ny − 1 − j; R = cover, G = depth/depth_max_m,
## B = (stage + 1)/2, A = activity; квантование округлением — те же байты в снимке.
## Снимок: FORMAT_VERSION u8, подпись сетки (u16 длина + utf8), t f64, base_msl f32, bg_cover f32,
## bg_depth f32, RGBA8; всё сжато zstd.


static func encode_rgba(cf: CloudField) -> PackedByteArray:
	var nx := cf.nx
	var ny := cf.ny
	var out := PackedByteArray()
	out.resize(nx * ny * 4)
	var inv_dmax := 1.0 / maxf(float(cf.cfg.get("depth_max_m", 2500.0)), 1.0)
	var cover := cf.cover
	var depth := cf.depth
	var stage := cf.stage
	var act := cf.activity
	for j in ny:
		var r := ny - 1 - j
		for i in nx:
			var c := j * nx + i
			var o := (r * nx + i) * 4
			out[o] = int(round(clampf(cover[c], 0.0, 1.0) * 255.0))
			out[o + 1] = int(round(clampf(depth[c] * inv_dmax, 0.0, 1.0) * 255.0))
			out[o + 2] = int(round(clampf((stage[c] + 1.0) * 0.5, 0.0, 1.0) * 255.0))
			out[o + 3] = int(round(clampf(act[c], 0.0, 1.0) * 255.0))
	return out


static func to_image(cf: CloudField) -> Image:
	if cf.nx == 0 or cf.ny == 0:
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	return Image.create_from_data(cf.nx, cf.ny, false, Image.FORMAT_RGBA8, encode_rgba(cf))


static func snapshot(cf: CloudField) -> PackedByteArray:
	var sig := cf.signature().to_utf8_buffer()
	var head := StreamPeerBuffer.new()
	head.big_endian = false
	head.put_u8(CloudField.FORMAT_VERSION)
	head.put_u16(sig.size())
	head.put_data(sig)
	head.put_double(cf.time)
	head.put_float(cf.base_msl)
	head.put_float(cf.bg_cover)
	head.put_float(cf.bg_depth)
	var raw: PackedByteArray = head.data_array
	raw.append_array(encode_rgba(cf))
	return raw.compress(FileAccess.COMPRESSION_ZSTD)


## Размер несжатого снимка этой сетки, байт (zstd нужен размер; чужая сетка — не сойдётся → false).
static func expected_size(cf: CloudField) -> int:
	return 1 + 2 + cf.signature().to_utf8_buffer().size() + 8 + 12 + cf.nx * cf.ny * 4


## Применить снимок: версия и сетка совпали — поле = lerp(поле, снимок, blend), true; иначе false.
static func apply_snapshot(cf: CloudField, b: PackedByteArray, blend: float) -> bool:
	var raw := b.decompress(expected_size(cf), FileAccess.COMPRESSION_ZSTD)
	if raw.size() != expected_size(cf):
		return false
	var s := StreamPeerBuffer.new()
	s.big_endian = false
	s.data_array = raw
	if s.get_u8() != CloudField.FORMAT_VERSION:
		return false
	var ln := s.get_u16()
	var sig_b: Array = s.get_data(ln)
	if int(sig_b[0]) != OK:
		return false
	var sig := (sig_b[1] as PackedByteArray).get_string_from_utf8()
	if sig != cf.signature():
		return false
	s.get_double()
	var base := s.get_float()
	var bgc := s.get_float()
	var bgd := s.get_float()
	var n := cf.nx * cf.ny
	var o0 := s.get_position()
	if raw.size() - o0 != n * 4:
		return false
	var k := clampf(blend, 0.0, 1.0)
	var dmax := maxf(float(cf.cfg.get("depth_max_m", 2500.0)), 1.0)
	var nx := cf.nx
	var ny := cf.ny
	for j in ny:
		var r := ny - 1 - j
		for i in nx:
			var c := j * nx + i
			var o := o0 + (r * nx + i) * 4
			var cov := raw[o] / 255.0
			var dep := raw[o + 1] / 255.0 * dmax
			var st := raw[o + 2] / 255.0 * 2.0 - 1.0
			var ac := raw[o + 3] / 255.0
			cf.cover[c] += (cov - cf.cover[c]) * k
			cf.depth[c] += (dep - cf.depth[c]) * k
			cf.stage[c] += (st - cf.stage[c]) * k
			cf.activity[c] += (ac - cf.activity[c]) * k
			if cf.cover[c] <= 0.0:
				cf.depth[c] = 0.0
	cf.base_msl += (base - cf.base_msl) * k
	cf.bg_cover += (bgc - cf.bg_cover) * k
	cf.bg_depth += (bgd - cf.bg_depth) * k
	cf._state_from_outputs()
	return true
