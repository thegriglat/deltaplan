extends SceneTree
## Проба тонмаппинга: HDR-цвет (линейный RGB, как у композитора облаков) -> sRGB кадра при настройках проекта
## (AgX, exposure 1.1, white 6.0, saturation 1.08, contrast 1.04; glow по флагу).
## godot --path <корень> -s tools/research/haze_humidity/sunset_color/tonemap_probe.gd -- in.json out.json [glow] [agx|filmic|reinhard]
var _colors: Array = []
var _out := ""
var _i := -1
var _quad: MeshInstance3D
var _res: Array = []
var _wait := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_colors = JSON.parse_string(FileAccess.get_file_as_string(a[0]))
	_out = a[1]
	var glow := a.size() > 2 and a[2] == "glow"
	var w: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/world.json"))
	var rend: Dictionary = w.rendering
	var fx: Dictionary = w.effects
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	var mode := String(rend.tonemap_mode)
	if a.size() > 3:
		mode = a[3]
	env.tonemap_mode = Environment.TONE_MAPPER_AGX if mode == "agx" else (Environment.TONE_MAPPER_REINHARDT if mode == "reinhard" else Environment.TONE_MAPPER_FILMIC)
	env.tonemap_exposure = float(rend.tonemap_exposure)
	env.tonemap_white = float(rend.tonemap_white)
	env.glow_enabled = glow
	env.glow_intensity = float(fx.glow_intensity)
	env.glow_bloom = float(fx.glow_bloom)
	env.glow_hdr_threshold = float(fx.glow_hdr_threshold)
	env.adjustment_enabled = true
	env.adjustment_saturation = float(fx.saturation)
	env.adjustment_contrast = float(fx.contrast)
	env.adjustment_brightness = float(fx.brightness)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 0, 1)
	_quad = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(4, 4)
	_quad.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_quad.material_override = m
	root.add_child(_quad)
	root.size = Vector2i(64, 64)

func _process(_d: float) -> bool:
	_wait += 1
	if _wait < 4:
		return false
	_wait = 0
	if _i >= 0:
		var img := root.get_texture().get_image()
		var c := img.get_pixel(32, 32)
		_res.append([c.r8, c.g8, c.b8])
	_i += 1
	if _i >= _colors.size():
		var f := FileAccess.open(_out, FileAccess.WRITE)
		f.store_string(JSON.stringify(_res))
		f.close()
		quit()
		return true
	var c: Array = _colors[_i]
	((_quad.material_override) as StandardMaterial3D).albedo_color = Color(c[0], c[1], c[2])
	return false
