extends Node
## TW-1: профиль ветра у старта (как в e2e: меню → первый старт → «Лететь», сид --tw-seeds):
## mean_wind_at и air_velocity_at на высотах над землёй 0,5…30 м в точках 0…150 м по курсу старта,
## плюс высота рельефа. Пишет <out>/profile_<loc>_<seed>.csv.
## godot --headless --path . res://tools/research/takeoff_wind/TW-1/profile.tscn -- \
##   --tw-locs=training_island --tw-seeds=1 --tw-out=<dir>

const MAIN_SCENE := preload("res://scenes/main.tscn")
const HEIGHTS := [0.5, 1.0, 1.6, 2.0, 3.0, 4.0, 6.0, 8.0, 10.0, 15.0, 20.0, 30.0, 50.0]
const DISTS := [-20.0, 0.0, 10.0, 20.0, 30.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0]

var locs: PackedStringArray = []
var seeds: Array[int] = []
var out_dir := ""
var flow := "e2e"
var wind_kmh := 18.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--tw-"):
			continue
		var kv := a.substr(5).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"locs": locs = v.split(",", false)
			"seeds":
				for s in v.split(",", false):
					seeds.append(int(s))
			"out": out_dir = v
			"flow": flow = v
			"wind": wind_kmh = float(v)
	if seeds.is_empty():
		seeds = [1]
	if not out_dir.begins_with("/"):
		out_dir = ProjectSettings.globalize_path("res://") + out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	for loc in locs:
		for sd in seeds:
			await _one(loc, sd)
	get_tree().quit(0)


func _one(loc_id: String, seed_v: int) -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var opts: LaunchOptions = main.get("opts")
	opts.seed = seed_v
	if flow == "matrix":
		await main.call("load_menu_world")
		opts.autostart = true
		var s := FlightSettings.new()
		s.location_id = loc_id
		s.wing = "wings/training"
		s.temperature_c = 31.0
		s.wind_speed_kmh = wind_kmh
		game.world_seed = seed_v
		await main.call("_fly", s)
	else:
		var menu: StartMenu = main.get_node("UI/StartMenu")
		for i in 600:
			if menu.visible:
				break
			await get_tree().process_frame
		var fss: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
		menu.setup_requested.emit()
		var place := {}
		for p: Dictionary in (fss.get("_places_catalog") as Dictionary).get("takeoffs", []):
			if String(p.get("location", "")) == loc_id:
				place = p
				break
		if Locations.is_training_only(loc_id):
			var st0: Dictionary = (Locations.config(loc_id).get("start_sites", []) as Array)[0]
			place = {"id": "builtin/%s/%s" % [loc_id, st0.id], "lat": st0.lat, "lon": st0.lon, "country": "",
				"location": loc_id, "site": st0.id, "heading_deg": st0.heading_deg}
		fss.call("_on_place_chosen", place)
		(fss.get("_done_btn") as Button).emit_signal("pressed")
		(menu.get("_fly_btn") as Button).emit_signal("pressed")
	for i in 3000:
		if int(main.get("state")) == 2:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var tel := game.glider.get_telemetry()
	var p0 := tel.position
	var h := deg_to_rad(tel.heading_deg)
	var fwd := Vector3(sin(h), 0.0, -cos(h))
	var air: Node = game.air
	var f := FileAccess.open("%s/profile_%s_%d.csv" % [out_dir, loc_id, seed_v], FileAccess.WRITE)
	f.store_line("d,agl,ground,mean_u_fwd,mean_w,air_u_fwd,air_w,air_speed")
	for d: float in DISTS:
		var p := p0 + fwd * d
		var gh: float = game.terrain.height_at(p.x, p.z)
		for z: float in HEIGHTS:
			var q := Vector3(p.x, gh + z, p.z)
			var mw: Vector3 = air.call("mean_wind_at", q)
			var av: Vector3 = air.call("air_velocity_at", q)
			f.store_line("%.0f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f" % [d, z, gh, -mw.dot(fwd), mw.y,
				-av.dot(fwd), av.y, Vector2(av.x, av.z).length()])
	f.close()
	print("PROFILE %s %d heading %.0f p0 %s" % [loc_id, seed_v, tel.heading_deg, p0])
	main.queue_free()
	for i in 3:
		await get_tree().process_frame
