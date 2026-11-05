extends Node
## SLT-К1: SailTexture — члены, константы, prepare/import_file/load_texture/clear.

const DIR := "user://slt_contract_test"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _gen(w: int, h: int, jpg: bool, file: String) -> String:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in range(0, h):
		for x in range(0, w):
			img.set_pixel(x, y, Color(float(x) / w, float(y) / h, 0.5))
	var p := DIR + "/" + file
	if jpg:
		img.save_jpg(p, 0.8)
	else:
		img.save_png(p)
	return p


func _begin() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	SailTexture.path = DIR + "/profile/sail.png"


func _end() -> void:
	SailTexture.path = SailTexture.DEFAULT_PATH
	for sub in ["", "/profile"]:
		var d := DirAccess.open(DIR + sub)
		if d != null:
			for f in d.get_files():
				d.remove(f)
	DirAccess.remove_absolute(DIR + "/profile")
	DirAccess.remove_absolute(DIR)


func test_members() -> void:
	check(SailTexture.DEFAULT_PATH == "user://sail_texture.png", "DEFAULT_PATH")
	check(SailTexture.MAX_FILE_BYTES == 20 * 1024 * 1024, "MAX_FILE_BYTES")
	check(SailTexture.MIN_SIDE_PX == 16, "MIN_SIDE_PX")
	check(SailTexture.MAX_INPUT_SIDE_PX == 16384, "MAX_INPUT_SIDE_PX")
	check(SailTexture.MAX_SIDE_PX == 2048, "MAX_SIDE_PX")
	check(SailTexture.path == SailTexture.DEFAULT_PATH, "path по умолчанию")


func test_prepare() -> void:
	_begin()
	for jpg in [false, true]:
		var r := SailTexture.prepare(_gen(300, 100, jpg, "a.png" if not jpg else "a.jpg"))
		check(r["error"] == "", "успех jpg=%s" % jpg)
		var img: Image = r["image"]
		check(img != null and img.get_format() == Image.FORMAT_RGBA8, "RGBA8")
		check(img != null and not img.has_mipmaps(), "без мипмапов")
	var big: Dictionary = SailTexture.prepare(_gen(3000, 600, false, "big.png"))
	var bi: Image = big["image"]
	check(bi != null and bi.get_width() == 2048, "большая сторона 2048")
	check(bi != null and absi(bi.get_height() - 410) <= 1, "пропорции")
	# JPEG под именем .png — формат по содержимому
	var jp := _gen(64, 64, true, "fake.png")
	check(SailTexture.prepare(jp)["error"] == "", "JPEG в .png")
	var txt := DIR + "/t.png"
	var f := FileAccess.open(txt, FileAccess.WRITE)
	f.store_string("не картинка, просто текст")
	f.close()
	check(SailTexture.prepare(txt)["error"] == "sail_tex_err_format", "текст")
	check(SailTexture.prepare(DIR + "/нет.png")["error"] == "sail_tex_err_read", "нет файла")
	var small := SailTexture.prepare(_gen(8, 8, false, "s.png"))
	check(small["error"] == "sail_tex_err_too_small" and small["image"] == null, "8x8")
	_end()


func test_import_clear() -> void:
	_begin()
	check(not SailTexture.has_custom(), "пока нет")
	check(SailTexture.load_texture() == null, "load без файла — null")
	check(SailTexture.import_file(_gen(200, 100, false, "ok.png")) == "", "import ok")
	check(SailTexture.has_custom(), "has_custom")
	var t := SailTexture.load_texture()
	check(t != null and t.get_image().has_mipmaps(), "мипмапы")
	var before := FileAccess.get_file_as_bytes(SailTexture.path)
	check(SailTexture.import_file(DIR + "/нет.png") == "sail_tex_err_read", "ошибка импорта")
	check(FileAccess.get_file_as_bytes(SailTexture.path) == before, "прежний файл цел")
	check(not FileAccess.file_exists(SailTexture.path + ".tmp"), "tmp убран")
	SailTexture.clear()
	check(not SailTexture.has_custom(), "clear")
	check(SailTexture.load_texture() == null, "после clear — null")
	SailTexture.clear()
	_end()


## SLT-К2: SailMaterial.set_custom и uniform'ы шейдера паруса.
func test_k2_sail_material() -> void:
	var sm: Script = load("res://assets/shaders/sail/sail_material.gd")
	var has_set_custom := false
	for m: Dictionary in sm.get_script_method_list():
		if m["name"] == "set_custom":
			has_set_custom = true
			check(m["args"].size() == 2, "set_custom(mat, tex)")
	check(has_set_custom, "SailMaterial.set_custom")
	var uniforms := {}
	for u: Dictionary in (load("res://assets/shaders/sail/sail.gdshader") as Shader).get_shader_uniform_list():
		uniforms[u["name"]] = u
	for n in ["custom_tex", "custom_on", "custom_img_aspect", "custom_aspect_top", "custom_aspect_bottom"]:
		check(uniforms.has(n), "uniform " + n)
	if uniforms.has("custom_tex"):
		check(uniforms["custom_tex"]["type"] == TYPE_OBJECT, "custom_tex — текстура")
	for n in ["custom_on", "custom_img_aspect", "custom_aspect_top", "custom_aspect_bottom"]:
		if uniforms.has(n):
			check(uniforms[n]["type"] == TYPE_FLOAT, n + " — float")
