extends SceneTree
## Пересборка только покрова встроенного места (NO-1): SurfaceStage поверх готовых высот и маски рек,
## без DEM, рек и OSM. Пишет в data/terrain/<id>/: detail_detail10.png, detail_built10.png,
## built_patches.json, surface.json; *_surface.png — только если байты изменились.
##   XDG_DATA_HOME=/tmp/no1_xdg godot --headless --path . -s res://tools/terrain/rebuild_cover.gd -- --id askarovo [--local]
## --local — блоки COG сначала из ~/.cache/deltaplan_terrain/cog и ~/.cache/deltaplan_parity (только чтение).

const FILES := ["detail_detail10.png", "detail_built10.png", "built_patches.json", "surface.json"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var id := ""
	var local := false
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--id":
				i += 1
				id = args[i]
			"--local":
				local = true
		i += 1
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/locations/%s.json" % id))
	if not spec is Dictionary:
		print("Нет конфига места " + id)
		quit(2)
		return
	var final_dir := ProjectSettings.globalize_path(String(spec.data_dir))
	var tmp := OS.get_user_data_dir().path_join("rebuild_cover_" + id)
	DirAccess.make_dir_recursive_absolute(tmp)
	var da := DirAccess.open(final_dir)
	for f in da.get_files():
		if f.ends_with("_water.png") or f == "meta.json":
			DirAccess.copy_absolute(final_dir.path_join(f), tmp.path_join(f))
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(tmp.path_join("meta.json")))
	var ctx := LocationBuildContext.new()
	ctx.center_lat = float(spec.center_lat)
	ctx.center_lon = float(spec.center_lon)
	ctx.dir = tmp
	ctx.host = root
	ctx.spec = {"surface": spec.surface}
	for info: Dictionary in meta.layers:
		ctx.layers[String(info.id)] = info
	var stage: Object = (load("res://scripts/terrain/build/surface_stage.gd") as GDScript).new()
	if local:
		var home := OS.get_environment("HOME")
		stage.extra_cache_dirs = PackedStringArray(
			[home + "/.cache/deltaplan_terrain/cog", home + "/.cache/deltaplan_parity"]
		)
	var t0 := Time.get_ticks_usec()
	var err: int = await stage.run(ctx)
	print("%s: stage err=%d, %.1f c, net_requests=%d" % [id, err, (Time.get_ticks_usec() - t0) / 1e6, ctx.net_requests])
	for l in ctx.log_lines:
		print("  журнал: " + l)
	if err != OK:
		quit(1)
		return
	for f in FILES:
		if FileAccess.file_exists(tmp.path_join(f)):
			DirAccess.copy_absolute(tmp.path_join(f), final_dir.path_join(f))
		else:
			DirAccess.remove_absolute(final_dir.path_join(f))
			print("  нет %s — старый удалён" % f)
	for l in ["detail", "far"]:
		var n := "%s_surface.png" % l
		if FileAccess.file_exists(tmp.path_join(n)):
			if FileAccess.get_file_as_bytes(tmp.path_join(n)) != FileAccess.get_file_as_bytes(final_dir.path_join(n)):
				DirAccess.copy_absolute(tmp.path_join(n), final_dir.path_join(n))
				print("  %s изменился" % n)
	quit(0)
