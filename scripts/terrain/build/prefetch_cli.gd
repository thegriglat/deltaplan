class_name PrefetchCli
extends RefCounted
## Опция --prefetch=lat,lon[;lat,lon…] у игры: собрать данные места в user://locations без полёта
## (тот же LocationBuilder, что в игре и в tools/terrain/build_location.gd). Печатает ход по
## стадиям, ключ/путь, итог. Код выхода 0 — все места полные, иначе 1 (2 — разбор аргументов).

## Разбор значения флага: "53.2,58.5;47,11" → [[53.2, 58.5], [47.0, 11.0]]. Ошибки — в errors.
static func parse_points(value: String, errors: PackedStringArray) -> Array:
	var out: Array = []
	for part in value.split(";", false):
		var p := part.strip_edges().split(",")
		if p.size() != 2 or not p[0].strip_edges().is_valid_float() or not p[1].strip_edges().is_valid_float():
			errors.append("не разобрано: «%s» (нужно широта,долгота)" % part)
			continue
		var lat := p[0].strip_edges().to_float()
		var lon := p[1].strip_edges().to_float()
		if absf(lat) > 90.0 or absf(lon) > 180.0:
			errors.append("вне диапазона: «%s»" % part)
			continue
		out.append([lat, lon])
	return out


## Собрать все точки по очереди. Возвращает код выхода.
static func run(host: Node, points: Array, offline: bool, errors: PackedStringArray = PackedStringArray()) -> int:
	for e in errors:
		print("prefetch: " + e)
	if points.is_empty():
		print("prefetch: нет точек. Пример: --prefetch=53.23797,58.51595[;lat,lon…] [--offline]")
		return 2
	var code := 0 if errors.is_empty() else 1
	var t_all := Time.get_ticks_usec()
	for i in points.size():
		var lat: float = points[i][0]
		var lon: float = points[i][1]
		print("prefetch [%d/%d] точка %.5f, %.5f%s" % [i + 1, points.size(), lat, lon, " (offline)" if offline else ""])
		var builtin := Locations.builtin_at(lat, lon)
		if builtin != "":
			print("  точка внутри встроенного места «%s»: игра возьмёт встроенное, кеш всё равно собираю" % builtin)
		if not await _one(host, lat, lon, offline):
			code = 1
	print("prefetch: всего %.1f с, код выхода %d" % [(Time.get_ticks_usec() - t_all) / 1e6, code])
	return code


static func _one(host: Node, lat: float, lon: float, offline: bool) -> bool:
	var builder := LocationBuilder.new()
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
	var res: Dictionary = await builder.build(host, lat, lon)
	var key := String(res.key)
	var dir := LocationCache.dir_for(key)
	var complete := LocationCache.is_complete(key)
	var missing: Array = res.get("missing", [])
	if not bool(res.ok):
		var b := LocationCache.read_build(dir)
		missing = b.get("missing", missing)
	print("  ключ: %s" % key)
	print("  путь: %s" % ProjectSettings.globalize_path(dir))
	print("  стадии, с: %s" % JSON.stringify(builder.seconds))
	print("  сетевых запросов: %d" % builder.net_requests)
	for l in builder.log_lines:
		print("  журнал: " + l)
	print("  итог: %s%s, ошибка: %s, размер %.1f МБ, %.1f с" % [
		"complete" if complete else "incomplete", "" if missing.is_empty() else " (missing: %s)" % ", ".join(PackedStringArray(missing)),
		res.error if String(res.error) != "" else "нет", LocationCache.dir_size(dir) / 1048576.0,
		(Time.get_ticks_usec() - t0) / 1e6])
	return complete
