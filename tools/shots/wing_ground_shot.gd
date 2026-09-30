extends Node3D
## Кадры SF-4 «крыло и земля на старте»: планер (крыло + pilot.glb) стоит на синтетическом склоне,
## поза — из FlightModel после нескольких секунд ввода (как в tools/flight/wing_clearance_run.gd),
## вид сбоку/сзади низко над землёй. Над кадром — наименьший зазор крыла, м.
## Запуск (под timeout, с временным профилем):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --resolution 1280x720 \
##     res://tools/shots/wing_ground_shot.tscn -- --out=<каталог> [--wing=sport] [--prefix=до]
## Пишет <out>/<prefix>_<случай>.png.

const WC := preload("res://tools/flight/wing_clearance.gd")
const DT := 1.0 / 120.0
## случай: [склон «flat» / «down20» / «cross15», pitch, roll, секунд, камера (оси планера), взгляд]
const CASES := {
	"ровно_A": ["flat", 0.0, -1.0, 3.0, Vector3(-3.0, 1.2, 9.0), Vector3(-2.5, 1.2, 0.0)],
	"склон20_стоит": ["down20", 0.0, 0.0, 3.0, Vector3(-9.0, 1.5, 1.5), Vector3(0.0, 1.2, 0.0)],
	"склон20_нос_вверх": ["down20", 1.0, 0.0, 3.0, Vector3(-9.0, 1.5, 1.5), Vector3(0, 1.2, 0)],
	"косой15_стоит": ["cross15", 0.0, 0.0, 3.0, Vector3(1.0, 2.5, 9.0), Vector3(2.5, 1.2, 0.0)],
}

var _out := ""
var _wing := "sport"
var _prefix := "кадр"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
		elif a.begins_with("--prefix="):
			_prefix = a.substr(9)
	if _out == "":
		push_error("wing_ground_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


static func ground_fn(kind: String) -> Callable:
	match kind:
		"down20":
			return func(_x: float, z: float) -> float: return 100.0 + tan(deg_to_rad(20.0)) * z
		"cross15":
			return func(x: float, _z: float) -> float: return 100.0 + tan(deg_to_rad(15.0)) * x
	return func(_x: float, _z: float) -> float: return 100.0


func _env() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.3, 0.5, 0.85)
	sm.sky_horizon_color = Color(0.7, 0.8, 0.9)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 150, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)


## Плоскость рельефа (полупрозрачная, с сеткой 1 м — видно, где крыло уходит под землю).
func _ground(kind: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	pm.subdivide_width = 79
	pm.subdivide_depth = 79
	mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.5, 0.25, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	var b := Basis.IDENTITY
	if kind == "down20":
		b = Basis(Vector3.RIGHT, deg_to_rad(-20.0))
	elif kind == "cross15":
		b = Basis(Vector3.BACK, deg_to_rad(15.0))
	mi.transform = Transform3D(b, Vector3(0, 100, 0))
	add_child(mi)
	return mi


func _run() -> void:
	_env()
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.fov = 60.0
	cam.near = 0.05
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 26)
	label.position = Vector2(20, 14)
	var cl := CanvasLayer.new()
	add_child(cl)
	cl.add_child(label)
	for case: String in CASES:
		var c: Array = CASES[case]
		var gm := _ground(String(c[0]))
		var gf := ground_fn(String(c[0]))
		var g := WC.make_glider(self, _wing)
		var pts := WC.wing_points(g.visual)
		var m := g.model
		m.reset_on_ground(Vector3(0, 100, 0), 0.0)
		var inp := ControlInput.new()
		inp.pitch = float(c[1])
		inp.roll = float(c[2])
		var zero := func(_p: Vector3) -> Vector3: return Vector3.ZERO
		for i in int(float(c[3]) / DT):
			m.step(DT, inp, zero, gf)
		var x := WC.pose(m)
		g.global_transform = x
		for ap: AnimationPlayer in g.visual.find_children("*", "AnimationPlayer", true, false):
			if ap.has_animation("stand"):
				ap.play("stand", 0.0)
		for i in 4:
			g.visual.set_pose(0.0, 0.0, false, 1.0e6)
			await get_tree().process_frame
		var cl_res := WC.clearance(pts, x, gf)
		label.text = (
			"%s  %s: крен %.1f°, тангаж %.1f°, наименьший зазор %.2f м (%s)"
			% [_prefix, case, rad_to_deg(m.bank), rad_to_deg(m.theta), cl_res.min, cl_res.part]
		)
		var yaw := Basis(Vector3.UP, -m.heading)
		cam.global_position = m.position + yaw * (c[4] as Vector3)
		cam.look_at(m.position + yaw * (c[5] as Vector3), Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var f := "%s/%s_%s.png" % [_out, _prefix, case]
		get_viewport().get_texture().get_image().save_png(f)
		print("wing_ground_shot: ", f)
		g.free()
		gm.free()
	get_tree().quit(0)
