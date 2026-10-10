extends Node
## Кадр экрана загрузки со счётчиком «OSM: N/9» (OT-8) на середине загрузки тайлов. Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/osm_counter_shot.tscn -- --out=<каталог> [--n=4] [--skipped]


func _ready() -> void:
	var out := "/tmp"
	var n := 4
	var skipped := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--n="):
			n = int(a.substr(4))
		elif a == "--skipped":
			skipped = true
	DirAccess.make_dir_recursive_absolute(out)
	var layer := CanvasLayer.new()
	add_child(layer)
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	layer.add_child(l)
	var p := LoadProgress.new()
	p.begin()
	l.open(p, "46.3600, 14.1000")
	p.stage("dem", tr("loading_dem"))
	p.counter("dem", 63, 63)
	p.stage("landcover", tr("loading_landcover"))
	p.counter("surface", 86, 86)
	p.stage("osm", tr("loading_osm"))
	p.counter("osm_tiles", -1 if skipped else n, 9)
	for i in 30:
		await get_tree().process_frame
	print("[shot] ", l.counter_line())
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join("loading_osm_counter.png"))
	get_tree().quit(0)
