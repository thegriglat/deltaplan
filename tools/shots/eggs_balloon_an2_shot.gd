extends Node
## Кадры воздушного шара и Ан-2: с 3 км, 1,5 км и вблизи (~200 м) на локации askarovo (фикстура).
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/eggs_balloon_an2_shot.tscn -- --out=<каталог> [--suffix=_после]
const PREVIEW := preload("res://scenes/terrain/terrain_preview.tscn")

var _out := ""
var _suffix := ""


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--suffix="):
			_suffix = a.substr(9)
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(300.0, true, false, true).timeout.connect(func(): get_tree().quit(1))
	_run()


func _shot(cam: Camera3D, ctx: EggContext, egg: Node3D, name: String, dist: float, dh: float) -> void:
	# камера на расстоянии dist по горизонтали от яйца (с юго-запада), выше на dh
	var target := egg.global_position
	var from := target + Vector3(-dist * 0.7, dh, dist * 0.7)
	var gh := float(ctx.height_at.call(from.x, from.z))
	from.y = maxf(from.y, gh + 5.0)
	cam.fov = 60.0 if dist > 500.0 else 40.0
	cam.look_at_from_position(from, target, Vector3.UP)
	ctx.camera = cam
	ctx.pilot_pos = from
	for i in 30:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("eggs_shot: ", name, " dist=", dist, " ", error_string(img.save_jpg("%s/%s%s.jpg" % [_out, name, _suffix], 0.9)))


func _run() -> void:
	var main := Node3D.new()
	add_child(main)
	main.add_child(load("res://scenes/world/environment.tscn").instantiate())
	var terrain := Terrain.new()
	terrain.name = "Terrain"
	main.add_child(terrain)
	var cam := Camera3D.new()
	main.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = 60.0
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
	ctx.pilot_pos = s
	ctx.world_key = "shot"
	ctx.month = 7
	ctx.hour = 8.5
	ctx.sun_elev_deg = 30.0
	ctx.wind_ms = 2.0
	ctx.wind_from_deg = 270.0
	ctx.sky = "clear"
	var cfgs: Dictionary = Config.get_config("easter_eggs").eggs
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var bal := EggBalloon.new()
	bal.t0 = 0.0
	bal.lifetime_s = 4500.0
	bal.begin(ctx, cfgs.balloon, rng, 0.0)
	main.add_child(bal)
	rng.seed = 5
	var an2 := EggAn2.new()
	an2.t0 = 0.0
	an2.begin(ctx, cfgs.an2, rng, 0.0)
	main.add_child(an2)
	print("eggs_shot: шаров ", bal.count(), ", Ан-2 трасса ", an2.track_ok)
	# шар: на 12-й минуте набрал высоту; Ан-2: на середине трассы
	ctx.t = 720.0
	bal.update(ctx)
	var bpos := bal.to_global(bal.envelopes().multimesh.get_instance_transform(0).origin)
	bpos.y -= 8.0
	var anchor := Node3D.new()
	main.add_child(anchor)
	anchor.global_position = bpos
	print("eggs_shot: шар на ", bpos, ", до старта ", Vector2(bpos.x - s.x, bpos.z - s.z).length())
	for d in [3000.0, 1500.0, 200.0]:
		await _shot(cam, ctx, anchor, "balloon_%dm" % int(d), d, 60.0 if d > 500.0 else 10.0)
	ctx.t = an2.length_m() / 50.0 * 0.5
	an2.update(ctx)
	anchor.global_position = an2.global_position
	print("eggs_shot: Ан-2 на ", an2.global_position, ", до старта ", Vector2(an2.global_position.x - s.x, an2.global_position.z - s.z).length())
	for d in [3000.0, 1500.0, 200.0]:
		await _shot(cam, ctx, anchor, "an2_%dm" % int(d), d, 60.0 if d > 500.0 else 10.0)
	get_tree().quit(0)
