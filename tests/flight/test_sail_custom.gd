extends TestCase
## SLT-К2: SailMaterial.set_custom, аспекты обшивок по мешу, парус игрока (Glider) и ботов (BotGlider).

const GLIDER_SCENE := preload("res://scenes/glider/glider.tscn")
const DIR := "user://slt3_test"
const UV_TABLE := "res://tools/research/sail-texture/uv_table.json"


func _tex(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	return ImageTexture.create_from_image(img)


## custom_on материала; не заданный uniform (родная, set_custom не вызывали) — 0.
func _on(mat: ShaderMaterial) -> float:
	var v: Variant = mat.get_shader_parameter("custom_on")
	return 0.0 if v == null else float(v)


func _root() -> Node:
	return Engine.get_main_loop().current_scene


func _prepare_file() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	SailTexture.path = DIR + "/sail.png"
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 1, 0, 1))
	img.save_png(SailTexture.path)


func _cleanup() -> void:
	SailTexture.path = SailTexture.DEFAULT_PATH
	var d := DirAccess.open(DIR)
	if d != null:
		for f in d.get_files():
			d.remove(f)
	DirAccess.remove_absolute(DIR)


func _wing_visual(wing: String) -> GliderVisual:
	var v := GliderVisual.new()
	_root().add_child(v)
	v.build(Config.get_config("wings/" + wing), Config.get_config("pilot"), Config.get_config("flight").visual)
	return v


func test_set_custom_null_safe() -> void:
	SailMaterial.set_custom(null, _tex(8, 8))
	SailMaterial.set_custom(null, null)
	var mat := ShaderMaterial.new()
	mat.shader = load(SailMaterial.SHADER_PATH) as Shader
	SailMaterial.set_custom(mat, null)
	check(float(mat.get_shader_parameter("custom_on")) == 0.0, "tex == null: custom_on = 0")


func test_set_custom_uniforms() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(SailMaterial.SHADER_PATH) as Shader
	var t := _tex(300, 100)
	SailMaterial.set_custom(mat, t)
	check(float(mat.get_shader_parameter("custom_on")) == 1.0, "custom_on = 1")
	check(mat.get_shader_parameter("custom_tex") == t, "custom_tex")
	approx(float(mat.get_shader_parameter("custom_img_aspect")), 3.0, 1e-5, "custom_img_aspect = w/h")
	SailMaterial.set_custom(mat, null)
	check(float(mat.get_shader_parameter("custom_on")) == 0.0, "сброс: custom_on = 0")


func test_aspects_match_uv_table() -> void:
	var f := FileAccess.open(UV_TABLE, FileAccess.READ)
	check(f != null, "uv_table.json")
	if f == null:
		return
	var table: Dictionary = JSON.parse_string(f.get_as_text())
	var by_id := {}
	for m: Dictionary in table["models"]:
		by_id[m["id"]] = m
	for id: String in ["aeros_discus", "atlas", "slavutich_ut", "dp_she1"]:
		var v := _wing_visual(id)
		var mat := v.sail_material
		check(mat != null, id + ": шейдер на парусе")
		if mat != null:
			var want: float = by_id[id]["aspect_span_over_root_chord"]
			var top: float = mat.get_shader_parameter("custom_aspect_top")
			var bottom: float = mat.get_shader_parameter("custom_aspect_bottom")
			check(absf(top - want) <= 0.05 * want, "%s: аспект верха %.3f, ожидалось %.3f ± 5 %%" % [id, top, want])
			# нижняя обшивка короче по хорде: у моделей без кармана низ/верх в [1.0, 1.35], у atlas и slavutich_ut — до 8 (нижняя обшивка узкая)
			var ratio := bottom / top
			var pocket := id in ["atlas", "slavutich_ut"]
			check(ratio >= 0.99 and ratio <= (8.0 if pocket else 1.35), "%s: аспект низа %.3f / верха %.3f = %.2f" % [id, bottom, top, ratio])
			check(_on(mat) == 0.0, id + ": без set_custom — родная")
		v.queue_free()


func test_shader_uniforms_declared() -> void:
	var names := {}
	for u: Dictionary in (load(SailMaterial.SHADER_PATH) as Shader).get_shader_uniform_list():
		names[u["name"]] = true
	for n in ["custom_tex", "custom_on", "custom_img_aspect", "custom_aspect_top", "custom_aspect_bottom"]:
		check(names.has(n), "uniform " + n)


func test_orientation_geometry() -> void:
	# Опора раскладки К2: правая сторона пилота — +X, нос — −Z (руки на штанге впереди плеч).
	var v := _wing_visual("aeros_discus")
	check(v.bar_grip(1).x > v.bar_grip(-1).x, "правая рука пилота — +X")
	check(v.bar_grip(1).z < v.shoulder(1).z, "руки на штанге впереди плеч — нос −Z")
	var sail := v.wing.find_child("Sail", true, false) as MeshInstance3D
	var arr := sail.mesh.surface_get_arrays(0)
	var zn := 0.0
	var n := 0
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	for i in verts.size():
		if uvs[i].y > 0.97 and absf(verts[i].x) < 0.2:
			zn += verts[i].z
			n += 1
	check(n > 0 and zn / n < 0.0, "UV.y ≈ 1 (передняя кромка, q = 0) у носа — отрицательный z")
	v.queue_free()


func test_glider_player_gets_custom() -> void:
	_prepare_file()
	var g: Glider = GLIDER_SCENE.instantiate()
	g.auto_start = Glider.AutoStart.NONE
	_root().add_child(g)
	g.setup("sport")
	var mat: ShaderMaterial = g.visual.sail_material
	check(mat != null, "шейдер на парусе")
	if mat != null:
		check(float(mat.get_shader_parameter("custom_on")) == 1.0, "файл есть: custom_on = 1")
		approx(float(mat.get_shader_parameter("custom_img_aspect")), 2.0, 1e-5, "аспект картинки 64:32")
	g.free()
	SailTexture.clear()
	var g2: Glider = GLIDER_SCENE.instantiate()
	g2.auto_start = Glider.AutoStart.NONE
	_root().add_child(g2)
	g2.setup("sport")
	var mat2: ShaderMaterial = g2.visual.sail_material
	check(mat2 != null and float(mat2.get_shader_parameter("custom_on")) == 0.0, "без файла: custom_on = 0")
	g2.free()
	_cleanup()


func test_bot_keeps_native() -> void:
	_prepare_file()
	var bots := BotPilots.new()
	bots.setup(
		{
			"ground_fn": func(_x: float, _z: float) -> float: return 300.0,
			"air_fn": func(_p: Vector3) -> Vector3: return Vector3.ZERO,
			"start": Vector3(0, 300, 0),
			"count": 2,
			"seed": 3,
		}
	)
	_root().add_child(bots)
	var seen := 0
	for c in bots.find_children("*", "BotGlider", true, false):
		var bg := c as BotGlider
		if bg.visual != null and bg.visual.sail_material != null:
			seen += 1
			check(_on(bg.visual.sail_material) == 0.0, "бот: custom_on = 0")
	check(seen > 0, "есть бот с визуалом паруса (%d)" % seen)
	bots.free()
	_cleanup()
