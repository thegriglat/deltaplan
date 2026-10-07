extends Node
## Кадр главного меню со списком «Избранное» (QL-12). Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/favorites_shot.tscn -- --out=<каталог>


func _ready() -> void:
	var out := "/tmp"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var path := "user://favorites_shot_tmp.json"
	var s := FlightSettings.defaults()
	s.wind_into_launch = false
	s.wind_from_deg = 315.0
	s.wind_speed_kmh = 10.8
	s.start_hour = 12.0
	Favorites.add(s, path, 1.0)
	s.start_hour = 15.0
	s.wind_speed_kmh = 18.0
	s.wing = "wings/trainer"
	Favorites.add(s, path, 2.0)
	s.start_hour = 9.0
	s.wind_into_launch = true
	s.wing = "wings/sport"
	Favorites.add(s, path, 3.0)
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = path
	add_child(m)
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join("menu_favorites.png"))
	DirAccess.remove_absolute(path)
	get_tree().quit(0)
