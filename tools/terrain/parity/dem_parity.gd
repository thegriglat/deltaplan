extends SceneTree
## Паритет DemStage с встроенными высотами (OA-1): собирает слои для центров мест из локальных
## копий исходников (~/.cache/deltaplan_terrain/copernicus/*.tif и terrarium/z/x/y.png) и сравнивает
## с data/terrain/<id>/*.f32.br. Печатает rmse_detail_m, rmse_far_m, max_abs_detail_m, max_abs_far_m
## (худшее из мест), stage_seconds (худшее время стадии).
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s res://tools/terrain/parity/dem_parity.gd
## Места — аргументы после "--" (по умолчанию askarovo altai). Тайлы Terrarium, которых нет локально,
## докачиваются в ~/.cache/deltaplan_parity (не в user://); сеть нужна только для них.

const IDS := ["askarovo", "altai"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Автозагрузки недоступны при разборе -s скрипта: берём узел и грузим классы стадии на лету.
	var cfg: Node = root.get_node("Config")
	var ctx_script: GDScript = load("res://scripts/terrain/build/location_build_context.gd")
	var stage_script: GDScript = load("res://scripts/terrain/build/dem_stage.gd")
	var height_script: GDScript = load("res://scripts/terrain/height_layer.gd")
	var home := OS.get_environment("HOME")
	var ids: Array = IDS
	var user_args := Array(OS.get_cmdline_user_args())
	# --online: источники из сети (HTTP range / тайлы) в кеш user://terrain_cache, затем второй прогон
	# офлайн из этого кеша (net_requests должно быть 0).
	var online: bool = user_args.has("--online")
	user_args.erase("--online")
	if not user_args.is_empty():
		ids = user_args
	var worst := {"rmse_detail_m": 0.0, "rmse_far_m": 0.0, "max_abs_detail_m": 0.0, "max_abs_far_m": 0.0, "stage_seconds": 0.0}
	var out_root := "user://parity_dem"
	for id: String in ids:
		var loc: Dictionary = cfg.get_config("locations/" + id)
		var ctx = ctx_script.new()
		ctx.key = id
		ctx.center_lat = float(loc.center_lat)
		ctx.center_lon = float(loc.center_lon)
		ctx.dir = out_root.path_join(id)
		ctx.host = root
		ctx.offline = not online
		ctx.spec = {
			"dem": loc.dem,
			"dem_sources": {
				"copernicus_dir": home + "/.cache/deltaplan_terrain/copernicus",
				"terrarium_dir": home + "/.cache/deltaplan_terrain/terrarium",
				"terrarium_cache_dir": home + "/.cache/deltaplan_parity/terrarium",
			},
		}
		if online:
			ctx.spec.erase("dem_sources")
		var t0 := Time.get_ticks_msec()
		var err: Error = await stage_script.new().run(ctx)
		if err == ERR_UNAVAILABLE:
			print("%s: локально не хватает тайлов — докачка в ~/.cache/deltaplan_parity" % id)
			ctx.offline = false
			ctx.log_lines = PackedStringArray()
			t0 = Time.get_ticks_msec()
			err = await stage_script.new().run(ctx)
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		if online:
			print("%s: онлайн-прогон %.1f c, net_requests=%d" % [id, secs, ctx.net_requests])
			ctx.offline = true
			ctx.net_requests = 0
			t0 = Time.get_ticks_msec()
			err = await stage_script.new().run(ctx)
			secs = (Time.get_ticks_msec() - t0) / 1000.0
			print("%s: повтор из кеша, net_requests=%d" % [id, ctx.net_requests])
		if err != OK:
			print("%s: ОШИБКА %d %s" % [id, err, ctx.log_lines])
			quit(1)
			return
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(cfg.get_config("locations/" + id).data_dir + "/meta.json"))
		for info: Dictionary in meta.layers:
			var ref = height_script.load_from_file(
				"%s/%s" % [loc.data_dir, info.file], info)
			var mine: PackedFloat32Array = ctx.heights[info.id]
			var ss := 0.0
			var mx := 0.0
			for k in mine.size():
				var d: float = mine[k] - ref.heights[k]
				ss += d * d
				mx = maxf(mx, absf(d))
			var rmse := sqrt(ss / mine.size())
			print("%s %s: n=%d rmse=%.4f max_abs=%.3f высоты %.1f..%.1f (эталон %.1f..%.1f)" % [id, info.id, mine.size(), rmse, mx, ctx.layers[info.id].min_height_m, ctx.layers[info.id].max_height_m, info.min_height_m, info.max_height_m])
			worst["rmse_%s_m" % info.id] = maxf(worst["rmse_%s_m" % info.id], rmse)
			worst["max_abs_%s_m" % info.id] = maxf(worst["max_abs_%s_m" % info.id], mx)
			# сверка с файлом на диске (.f32.zst) и meta
			var back = height_script.load_from_file("%s/%s" % [ctx.dir, ctx.layers[info.id].file], ctx.layers[info.id])
			if back == null or back.heights != mine:
				print("%s %s: ОШИБКА чтения .f32.zst" % [id, info.id])
				quit(1)
				return
		worst.stage_seconds = maxf(worst.stage_seconds, secs)
		print("%s: stage %.1f c, net_requests=%d" % [id, secs, ctx.net_requests])
	print("rmse_detail_m=%.4f" % worst.rmse_detail_m)
	print("rmse_far_m=%.4f" % worst.rmse_far_m)
	print("max_abs_detail_m=%.3f" % worst.max_abs_detail_m)
	print("max_abs_far_m=%.3f" % worst.max_abs_far_m)
	print("stage_seconds=%.1f" % worst.stage_seconds)
	quit(0)
