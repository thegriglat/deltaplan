class_name OsmTilesStage
extends RefCounted
## Стадия сборки места «тайлы OSM» (контракт O9, OA-К3; последняя стадия LocationBuilder): тайлы 3x3
## мировой сетки 20 км (O1) вокруг центра места — из кеша user://osm_tiles/v1/<j>/<i>.dpt или по сети
## (HttpLog, до max_parallel запросов, общее ожидание ≤ timeout_s). 200 → файл (атомарно), 404 → метка
## <i>.none (пустой тайл), всё остальное (таймаут, сеть, 5xx, битый файл) — тайл missing, стадия возвращает
## ERR_UNAVAILABLE (место missing: ["osm_tiles"], следующий запуск догружает только её).
## В папку места пишет osm_tiles.json {"tiles": [[j, i, "ok"|"none"|"missing"], …]}.
## Счётчик экрана загрузки «OSM: N/M» — ctx.plan/tick; пропуск (таймаут/ошибка) — counter(…, −1, M).
## base_url (конфиг или DELTAPLAN_OSM_TILES_URL) пуст → missing сразу, без сети; локальный каталог
## (путь или file://…) читается напрямую (нет файла = 404).

const STAGE := "osm_tiles"
const ENV_URL := "DELTAPLAN_OSM_TILES_URL"

## Подмена HTTP (тесты, как RasterTileLoader): (url, headers) -> [result, code, headers, body].
var http_hook: Callable = Callable()
## Правки конфига osm_tiles поверх configs/osm_tiles.json (тесты).
var cfg_override: Dictionary = {}

## Корень кеша тайлов вместо конфига (только тесты); пусто — configs/osm_tiles.json → cache_dir.
static var cache_root_override: String = ""


static func cache_root() -> String:
	if cache_root_override != "":
		return cache_root_override
	return String(Config.get_config("osm_tiles").get("cache_dir", "user://osm_tiles/v1"))


static func tile_path(j: int, i: int) -> String:
	return cache_root().path_join("%d/%d.dpt" % [j, i])


static func none_path(j: int, i: int) -> String:
	return cache_root().path_join("%d/%d.none" % [j, i])


func run(ctx: LocationBuildContext) -> Error:
	var cfg: Dictionary = Config.get_config("osm_tiles").duplicate(true)
	cfg.merge(cfg_override, true)
	if not bool(cfg.get("enabled", true)):
		_write_listing(ctx, [])
		return OK
	var base := OS.get_environment(ENV_URL)
	if base == "":
		base = String(cfg.get("base_url", ""))
	if base == "":
		ctx.log_line("OsmTilesStage: base_url пуст — слой OSM пропущен")
		return ERR_UNAVAILABLE
	var tiles := OsmGrid.neighbors(ctx.center_lat, ctx.center_lon)
	var total := tiles.size()
	var state := {}  # Vector2i → "ok"|"none"|"missing"
	ctx.plan(STAGE, total)
	ctx.report(STAGE, 0.0)
	var pending: Array[Vector2i] = []
	for t in tiles:
		if FileAccess.file_exists(tile_path(t.x, t.y)):
			state[t] = "ok"
			ctx.tick(STAGE)
		elif FileAccess.file_exists(none_path(t.x, t.y)):
			state[t] = "none"
			ctx.tick(STAGE)
		else:
			pending.append(t)
	if not pending.is_empty():
		if ctx.offline:
			ctx.log_line("OsmTilesStage: офлайн, нет в кеше тайлов: %d" % pending.size())
			for t in pending:
				state[t] = "missing"
		elif _is_url(base):
			await _fetch_http(ctx, base, cfg, pending, state)
		else:
			_read_local(ctx, base, pending, state)
	var listing: Array = []
	var bad := 0
	for t in tiles:
		var s: String = state.get(t, "missing")
		listing.append([t.x, t.y, s])
		if s == "missing":
			bad += 1
	_write_listing(ctx, listing)
	ctx.report(STAGE, 1.0)
	if bad > 0:
		ctx.counter.emit(STAGE, -1, total)  # экран загрузки: «OSM: пропущено»
		ctx.log_line("OsmTilesStage: тайлов не получено %d из %d" % [bad, total])
		return ERR_UNAVAILABLE
	return OK


static func _is_url(base: String) -> bool:
	return base.begins_with("http://") or base.begins_with("https://")


static func _write_listing(ctx: LocationBuildContext, listing: Array) -> void:
	var f := FileAccess.open(ctx.dir.path_join("osm_tiles.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"tiles": listing}) + "\n")
		f.close()


## Локальный каталог: <корень>/v1/<j>/<i>.dpt; нет файла — пустой тайл.
func _read_local(ctx: LocationBuildContext, base: String, pending: Array[Vector2i], state: Dictionary) -> void:
	var root := base.trim_prefix("file://")
	for t in pending:
		var p := root.path_join("v1/%d/%d.dpt" % [t.x, t.y])
		if not FileAccess.file_exists(p):
			state[t] = "none"  # каталог — не пишем метку в общий кеш (иначе при переходе на сервер тайл навсегда пустой)
		else:
			state[t] = _store_body(ctx, t, FileAccess.get_file_as_bytes(p))
		if state[t] != "missing":
			ctx.tick(STAGE)


func _fetch_http(ctx: LocationBuildContext, base: String, cfg: Dictionary, pending: Array[Vector2i],
		state: Dictionary) -> void:
	var timeout_s := float(cfg.get("timeout_s", 5.0))
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var job := {"queue": pending.duplicate(), "finished": 0, "abandoned": false, "track": []}
	var workers := clampi(int(cfg.get("max_parallel", 9)), 1, pending.size())
	for _w in workers:
		_worker(ctx, base.trim_suffix("/"), timeout_s, deadline, job, state)
	var loop := Engine.get_main_loop() as SceneTree
	while int(job.finished) < pending.size() and Time.get_ticks_msec() < deadline:
		if ctx.cancelled:
			break
		await loop.process_frame
	if int(job.finished) < pending.size():
		job.abandoned = true
		for req: Variant in job.track:
			if is_instance_valid(req):
				(req as HTTPRequest).cancel_request()
				(req as HTTPRequest).queue_free()
		ctx.log_line("OsmTilesStage: таймаут %.1f с, не дошло %d" % [timeout_s, pending.size() - int(job.finished)])
	for t in pending:
		if not state.has(t):
			state[t] = "missing"


## Один «рабочий»: берёт тайлы из очереди, пока она не пуста и ожидание не вышло.
func _worker(ctx: LocationBuildContext, base: String, timeout_s: float, deadline: int, job: Dictionary,
		state: Dictionary) -> void:
	var headers := PackedStringArray(["User-Agent: " + RasterTileLoader.expand_user_agent(
		String(Config.value("world", "runtime_terrain.user_agent", "deltaplan/{version}")))])
	while not (job.queue as Array).is_empty() and not job.abandoned:
		var t: Vector2i = (job.queue as Array).pop_front()
		var url := "%s/v1/%d/%d.dpt" % [base, t.x, t.y]
		ctx.net_requests += 1
		var res: Array
		if http_hook.is_valid():
			res = await http_hook.call(url, headers)
		else:
			res = await HttpLog.fetch(ctx.host, url, headers, "osm tile %d/%d" % [t.x, t.y],
				HTTPClient.METHOD_GET, "", timeout_s, job.track)
		if job.abandoned:
			return  # ответ пришёл после общего таймаута — тайл уже missing
		var s := "missing"
		if int(res[0]) == HTTPRequest.RESULT_SUCCESS:
			var code := int(res[1])
			if code == 200:
				s = _store_body(ctx, t, res[3])
			elif code == 404:
				s = _store_none(t)
			else:
				ctx.log_line("OsmTilesStage: тайл %d/%d — HTTP %d" % [t.x, t.y, code])
		else:
			ctx.log_line("OsmTilesStage: тайл %d/%d — сеть, result=%d" % [t.x, t.y, int(res[0])])
		state[t] = s
		job.finished += 1
		if s != "missing":
			ctx.tick(STAGE)


## Тело 200: заголовок и кадр zstd проверяются, файл пишется атомарно. "ok" или "missing" (битый).
func _store_body(ctx: LocationBuildContext, t: Vector2i, body: PackedByteArray) -> String:
	var h := OsmTileReader.read_header(body)
	if h.is_empty() or body.slice(OsmTileReader.HEADER_LEN).decompress(
			int(h.raw_len), FileAccess.COMPRESSION_ZSTD).size() != int(h.raw_len):
		ctx.log_line("OsmTilesStage: тайл %d/%d — битый файл" % [t.x, t.y])
		return "missing"
	var path := tile_path(t.x, t.y)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		ctx.log_line("OsmTilesStage: не открыть кеш %s" % path)
		return "missing"
	f.store_buffer(body)
	f.close()
	if DirAccess.rename_absolute(path + ".tmp", path) != OK:
		DirAccess.remove_absolute(path + ".tmp")
		return "missing"
	return "ok"


func _store_none(t: Vector2i) -> String:
	var path := none_path(t.x, t.y)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "missing"
	f.close()
	return "none"
