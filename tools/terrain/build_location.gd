extends SceneTree
## Сборка места для точки в user://locations (как в игре, OA-К4):
##   godot --headless --path . -s res://tools/terrain/build_location.gd -- --lat 47.05 --lon 11.0 [--offline]
## Встроенное место (OA-7, только из рабочей копии):
##   godot --headless --path . -s res://tools/terrain/build_location.gd -- --id altai [--local]
## собирает по configs/locations/<id>.json (центр, dem, surface, rivers) в его data_dir (user://locations/<id>/, как при первом выборе в игре);
## --local — рельеф и покров сначала из ~/.cache/deltaplan_terrain и ~/.cache/deltaplan_parity (только чтение).
## location.json не пишется (конфиг встроенного — configs/locations), ручные данные конфига не трогаются.
## Печатает ключ, missing, время по стадиям, net_requests, размер папки. Код выхода 1 — ошибка рельефа.
## Профиль — user:// текущего XDG_DATA_HOME (для проверок: XDG_DATA_HOME=$(mktemp -d)).
## Автозагрузки (Config) в -s-скрипте недоступны при разборе: классы грузим через load() после кадра.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var lat := NAN
	var lon := NAN
	var offline := false
	var id := ""
	var local := false
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--lat":
				i += 1
				lat = float(args[i])
			"--lon":
				i += 1
				lon = float(args[i])
			"--offline":
				offline = true
			"--id":
				i += 1
				id = args[i]
			"--local":
				local = true
		i += 1
	var spec: Dictionary = {}
	if id != "":
		var path := "res://configs/locations/%s.json" % id
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not d is Dictionary:
			print("Нет конфига " + path)
			quit(2)
			return
		spec = d
		lat = float(spec.center_lat)
		lon = float(spec.center_lon)
	if is_nan(lat) or is_nan(lon):
		print("Использование: -- --lat <градусы> --lon <градусы> [--offline]  или  -- --id <id> [--local]")
		quit(2)
		return
	var cache: GDScript = load("res://scripts/terrain/build/location_cache.gd")
	var builder: Object = (load("res://scripts/terrain/build/location_builder.gd") as GDScript).new()
	builder.offline = offline
	if id != "":
		var home := OS.get_environment("HOME")
		builder.out_dir = ProjectSettings.globalize_path("user://locations/" + id)
		builder.fixed_key = id
		var keep := {}
		for k in ["dem", "surface", "rivers", "center_lat", "center_lon"]:
			keep[k] = spec[k]
		builder.fixed_spec = keep
		builder.stages = builder.default_stages()
		if local:
			builder.spec_override = {
				"dem_sources":
				{
					"copernicus_dir": home + "/.cache/deltaplan_terrain/copernicus",
					"terrarium_dir": home + "/.cache/deltaplan_terrain/terrarium",
					"terrarium_cache_dir": "user://dem_tiles",
				}
			}
			for st in builder.stages:
				if st.name == "surface":
					st.obj.extra_cache_dirs = PackedStringArray(
						[home + "/.cache/deltaplan_terrain/cog", home + "/.cache/deltaplan_parity"]
					)
	var last := [""]
	builder.progress.connect(
		func(stage: String, f: float) -> void:
			if stage != last[0]:
				last[0] = stage
				print("  стадия %s…" % stage)
			if f >= 1.0:
				print("  %s готово" % stage)
	)
	var t0 := Time.get_ticks_usec()
	var res: Dictionary = await builder.build(root, lat, lon)
	var key := String(res.key)
	print("ключ: %s" % key)
	print("ok: %s  error: %s" % [res.ok, res.error])
	print("missing: %s" % str(res.missing))
	print("стадии, с: %s" % JSON.stringify(builder.seconds))
	print("net_requests: %d" % builder.net_requests)
	var dir: String = cache.dir_for(key) if id == "" else "user://locations/" + id
	print("папка: %s" % ProjectSettings.globalize_path(dir))
	print("размер папки: %.1f МБ" % (cache.dir_size(dir) / 1048576.0))
	print("всего: %.1f с" % ((Time.get_ticks_usec() - t0) / 1e6))
	for l in builder.log_lines:
		print("  журнал: " + l)
	quit(0 if bool(res.ok) else 1)
