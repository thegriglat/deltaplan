extends Node
## Кадр экрана загрузки (без главной сцены). Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/loading_screen_shot.tscn -- --out=<каталог>


func _ready() -> void:
	var out := "/tmp"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var layer := CanvasLayer.new()
	add_child(layer)
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	layer.add_child(l)
	var p := LoadProgress.new({"a": 1.0, "b": 3.0})
	p.begin()
	l.open(p, "50.6000, 86.4000")
	p.stage("b", tr("loading_dem"))
	p.sub(1, 2)
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join("loading.png"))
	get_tree().quit(0)
