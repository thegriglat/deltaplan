extends TestCase
## Контракт CLF-К4 (docs/contracts/cloud-field.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/cloud-field.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (CLF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("CLF-К4", 0) == VERSION, "CLF-К4 (v%d) в заголовках: %s" % [VERSION, found])


func test_snapshot_format() -> void:
	var cf := CloudField.new({})
	cf.setup_grid(4, 4, 400.0, -800.0, -800.0)
	cf.base_msl = 1234.5
	cf.bg_cover = 0.25
	cf.bg_depth = 300.0
	cf.cover[5] = 0.75
	cf.depth[5] = 500.0
	var b := cf.snapshot()
	var raw := b.decompress(CloudFieldCodec.expected_size(cf), FileAccess.COMPRESSION_ZSTD)
	var s := StreamPeerBuffer.new()
	s.data_array = raw
	check(s.get_u8() == CloudField.FORMAT_VERSION, "u8 FORMAT_VERSION")
	var ln := s.get_u16()
	var sig := (s.get_data(ln)[1] as PackedByteArray).get_string_from_utf8()
	check(sig == cf.signature(), "подпись сетки с длиной u16: %s" % sig)
	s.get_double()
	approx(s.get_float(), 1234.5, 0.01, "base_msl f32")
	approx(s.get_float(), 0.25, 1.0e-6, "bg_cover f32")
	approx(s.get_float(), 300.0, 0.01, "bg_depth f32")
	check(raw.size() - s.get_position() == 4 * 4 * 4, "затем RGBA8 nx·ny·4")
	var other := CloudField.new({})
	other.setup_grid(4, 4, 400.0, -800.0, -800.0)
	check(other.apply_snapshot(b, 0.5), "та же сетка — true")
	approx(other.cover[5], 0.375, 1.0 / 255.0, "blend 0,5 — половина")
	approx(other.base_msl, 617.25, 0.01, "base_msl тоже lerp")
	var alien := CloudField.new({})
	alien.setup_grid(4, 5, 400.0, -800.0, -800.0)
	check(not alien.apply_snapshot(b, 1.0) and alien.cover.count(0.0) == 20, "чужая сетка — false, поле не тронуто")
