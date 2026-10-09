extends SceneTree
## Сборка места для точки в user://locations (как в игре, OA-К4):
##   godot --headless --path . -s res://tools/terrain/build_location.gd -- --lat 47.05 --lon 11.0 [--offline]
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
		i += 1
	if is_nan(lat) or is_nan(lon):
		print("Использование: -- --lat <градусы> --lon <градусы> [--offline]")
		quit(2)
		return
	var cache: GDScript = load("res://scripts/terrain/build/location_cache.gd")
	var builder: Object = (load("res://scripts/terrain/build/location_builder.gd") as GDScript).new()
	builder.offline = offline
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
	var dir: String = cache.dir_for(key)
	print("папка: %s" % ProjectSettings.globalize_path(dir))
	print("размер папки: %.1f МБ" % (cache.dir_size(dir) / 1048576.0))
	print("всего: %.1f с" % ((Time.get_ticks_usec() - t0) / 1e6))
	for l in builder.log_lines:
		print("  журнал: " + l)
	quit(0 if bool(res.ok) else 1)
