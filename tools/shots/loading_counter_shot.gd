extends Node
## NO-7: экран загрузки при холодной сборке произвольной точки (нужна сеть, пустой кеш —
## временный XDG_DATA_HOME). Печатает строки счётчика в журнал, кадр — на середине покрова.
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1280x720 \
##     res://tools/shots/loading_counter_shot.tscn -- --out=<каталог> [--lat=43.2 --lon=76.9]


func _ready() -> void:
	var out := "/tmp"
	var lat := 43.2
	var lon := 76.9
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
	DirAccess.make_dir_recursive_absolute(out)
	var layer := CanvasLayer.new()
	add_child(layer)
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	layer.add_child(l)
	var p := LoadProgress.new()
	p.begin()
	p.stage("dem", tr("loading_dem"))
	l.open(p, "%.4f, %.4f" % [lat, lon])
	var builder := LocationBuilder.new()
	var st := {"shot": false, "line": ""}
	builder.progress.connect(
		func(stage: String, f: float) -> void:
			if stage == "surface" and p.text != tr("loading_landcover"):
				p.stage("landcover", tr("loading_landcover"))
			p.sub(f, 1.0)
	)
	builder.counter.connect(
		func(stage: String, d: int, t: int) -> void:
			p.counter(stage, d, t)
			var line := l.counter_line()
			if line != st.line:
				st.line = line
				print("[counter] %s  bar=%.3f" % [line, p.fraction])
			if stage == "surface" and d * 2 >= t and t > 1 and not st.shot:
				st.shot = true
	)
	var t0 := Time.get_ticks_msec()
	var res: Dictionary = {}
	var done := [false]
	(func() -> void:
		res = await builder.build(self, lat, lon)
		done[0] = true
	).call()
	var shot_done := false
	while not done[0]:
		await get_tree().process_frame
		if st.shot and not shot_done:
			shot_done = true
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out.path_join("loading_counter.png"))
			print("[shot] saved: " + l.counter_line())
	if not shot_done:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("loading_counter.png"))
		print("[shot] saved at end: " + l.counter_line())
	print("[done] ok=%s error=%s %.1f s requests=%d final=%s" % [res.get("ok"), res.get("error"), (Time.get_ticks_msec() - t0) / 1000.0, builder.net_requests, str(p.counters)])
	get_tree().quit(0)
