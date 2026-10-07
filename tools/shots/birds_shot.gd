extends Node
## QL-8: птицы в термике с 500 и 800 м (мин. размер на экране). Стенд — atmosphere_preview (плоская земля).
## godot --path . res://tools/shots/birds_shot.tscn -- --out=<папка> [--weather=strong]
## Пишет <out>/birds_500m.png и birds_800m.png.

const PREVIEW := preload("res://scenes/atmosphere/atmosphere_preview.tscn")


func _ready() -> void:
	var out := "/tmp/birds_shot"
	var weather := "strong"
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv[0] == "out":
			out = kv[1]
		elif kv[0] == "weather":
			weather = kv[1]
	DirAccess.make_dir_recursive_absolute(out)
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	var preview: Node = PREVIEW.instantiate()
	add_child(preview)
	var atmo: Atmosphere = preview.get_node("Atmosphere")
	atmo.set_weather("weather/" + weather)
	preview.set_process(false)
	preview.set_process_input(false)
	preview.set_process_unhandled_input(false)
	preview.get_node("Camera3D").queue_free()
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.fov = 60.0
	atmo.set_focus(Vector3(0, 400, 0))
	for i in 20:
		atmo.step(1.0)
		await get_tree().process_frame
	var birds: BirdFlock = atmo.get("_birds")
	for i in 30:
		await get_tree().process_frame
	var th: AtmoThermal = null
	var target := Vector3.ZERO
	for entry in birds._flocks:
		if not bool(entry[3]) and not (entry[1] as Array).is_empty():
			th = entry[0]
			target = (entry[1][0] as Dictionary).pos
			break
	if th == null:
		push_error("birds_shot: нет стаи")
		get_tree().quit(1)
		return
	for d in [500.0, 800.0]:
		cam.global_position = Vector3(target.x - d, target.y, target.z)
		cam.look_at(target)
		print("cam ", cam.global_position, " target ", target, " thermal top ", th.top)
		for i in 6:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(out.path_join("birds_%dm.png" % int(d)))
		# Увеличенный фрагмент вокруг стаи (птицы по 3 px не видны на уменьшенном просмотре).
		var c := Vector2i(cam.unproject_position(target))
		var r := Rect2i(c.x - 160, c.y - 100, 320, 200).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		var crop := img.get_region(r)
		crop.resize(crop.get_width() * 3, crop.get_height() * 3, Image.INTERPOLATE_NEAREST)
		crop.save_png(out.path_join("birds_%dm_zoom.png" % int(d)))
		var dark := 0
		for y in r.size.y:
			for x in r.size.x:
				if img.get_pixel(r.position.x + x, r.position.y + y).get_luminance() < 0.35:
					dark += 1
		print("тёмных px в окне 320x200: ", dark)
		print("shot ", d, " птиц ", birds._mm.instance_count)
	get_tree().quit(0)
