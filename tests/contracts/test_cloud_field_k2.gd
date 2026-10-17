extends TestCase
## Контракт CLF-К2 (docs/contracts/cloud-field.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

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
	check(found.get("CLF-К2", 0) == VERSION, "CLF-К2 (v%d) в заголовках: %s" % [VERSION, found])


func test_image_format() -> void:
	var cf := CloudField.new({})
	cf.setup_grid(5, 3, 400.0, 0.0, 0.0)
	cf.cover[1 * 5 + 2] = 0.5
	cf.depth[1 * 5 + 2] = 0.5 * float(cf.cfg.get("depth_max_m", 2500.0))
	cf.stage[1 * 5 + 2] = 1.0
	cf.activity[1 * 5 + 2] = 0.25
	var img := cf.to_image()
	check(img.get_format() == Image.FORMAT_RGBA8, "FORMAT_RGBA8")
	check(img.get_width() == 5 and img.get_height() == 3, "nx × ny")
	var px := img.get_pixel(2, 3 - 1 - 1)
	approx(px.r, 0.5, 1.0 / 255.0, "R = cover в строке ny − 1 − j")
	approx(px.g, 0.5, 1.0 / 255.0, "G = depth/depth_max_m")
	approx(px.b, 1.0, 1.0 / 255.0, "B = (stage + 1)/2")
	approx(px.a, 0.25, 1.0 / 255.0, "A = activity")
	check(img.get_pixel(2, 2).r == 0.0, "пустая клетка — 0")
	var raw := cf.snapshot().decompress(CloudFieldCodec.expected_size(cf), FileAccess.COMPRESSION_ZSTD)
	check(raw.slice(raw.size() - 60) == img.get_data(), "те же байты, что в снимке К4")
