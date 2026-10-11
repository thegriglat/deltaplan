extends Node
## Кадры рисунка НЛО на поле (EE-3): главная сцена, пасхалка с повышенной вероятностью, камера над рисунком.
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/crop_circle_shot.tscn -- --autostart --bots=0 --location=askarovo --out=<каталог>
const PREVIEW := preload("res://scenes/terrain/terrain_preview.tscn")

var _out := ""
var _main: Node = null


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(240.0, true, false, true).timeout.connect(func(): get_tree().quit(1))
	_run()


func _run() -> void:
	_main = Node3D.new()
	add_child(_main)
	_main.add_child(load("res://scenes/world/environment.tscn").instantiate())
	var terrain := Terrain.new()
	terrain.name = "Terrain"
	_main.add_child(terrain)
	var cam := Camera3D.new()
	_main.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	await get_tree().process_frame
	Locations.fixtures_root = "res://tests/fixtures/locations"
	terrain.load_location("askarovo")
	terrain.wait_relief()
	terrain.renderer.lod_camera = cam
	terrain.set_pilot(cam)
	var s: Vector3 = terrain.get_start_sites()[0].position
	var place := EggPlace.build(terrain, Objs.new())
	var ctx := EggContext.new()
	ctx.place = place
	ctx.terrain = terrain
	ctx.height_at = place.height_at
	ctx.pilot_pos = Vector3(s.x, s.y, s.z)
	var cfg: Dictionary = Config.get_config("easter_eggs").eggs.crop_circles.duplicate()
	cfg.probability = 0.03
	cfg.visible_m = 4000.0
	var egg: EggCropCircles = null
	var best := Vector2.ZERO
	var bd := 1.0e9
	var most := -1
	var at0 := Vector2(s.x, s.z)
	for gx in range(-14000, 14001, 7000):
		for gz in range(-14000, 14001, 7000):
			var c0 := at0 + Vector2(gx, gz)
			var e := EggCropCircles.new()
			e.fixed_seed = 2024
			ctx.pilot_pos = Vector3(c0.x, s.y, c0.y)
			e.begin(ctx, cfg, RandomNumberGenerator.new(), 0.0)
			e.settle(ctx)
			if e.circles.size() > most:
				most = e.circles.size()
				if egg != null:
					egg.free()
				egg = e
				at0 = at0  # центр круга — ближайший к c0 рисунок
				bd = 1.0e9
				for cell in e.circles:
					var d: float = (e.circles[cell].center as Vector2).distance_to(c0)
					if d < bd:
						bd = d
						best = e.circles[cell].center
			else:
				e.free()
	add_child(egg)
	print("crop_circle_shot: рисунков %d, выбран (%.0f, %.0f)" % [egg.circles.size(), best.x, best.y])
	var gh := place.height_at(best.x, best.y)
	cam.fov = 55.0
	var views := {
		"03_рисунок_нло_сверху": [Vector3(best.x, gh + 330.0, best.y + 1.0), Vector3(best.x, gh, best.y)],
		"04_рисунок_нло_наискосок": [Vector3(best.x - 450.0, gh + 330.0, best.y + 450.0), Vector3(best.x, gh, best.y)],
	}
	for name in views:
		var v: Array = views[name]
		cam.look_at_from_position(v[0], v[1], Vector3(0, 0, -1))
		ctx.camera = cam
		ctx.pilot_pos = v[0]
		for i in 40:
			egg.update(ctx)
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		print("crop_circle_shot: ", name, " ", error_string(img.save_jpg("%s/%s.jpg" % [_out, name], 0.9)))
	get_tree().quit(0)
