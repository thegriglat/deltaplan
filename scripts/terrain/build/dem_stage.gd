class_name DemStage
extends RefCounted
## Стадия рельефа сборки места (OA-К3, OA-1): порт tools/terrain/fetch_dem.py.
## Слои из ctx.spec.dem.layers: Copernicus GLO-30 (COG по HTTP range или локальный файл) и
## Terrarium (тайлы PNG), пересэмплирование на метрическую сетку вокруг центра (равнопромежуточная
## проекция, R = 6371008,8 м), гауссово сглаживание, квантование, вклейка детального слоя в грубый.
## Пишет <ctx.dir>/<слой>.f32.zst (float32 LE, zstd) и meta.json; заполняет ctx.heights/ctx.layers.
## Реки (<слой>_water.png) — RiverStage; в meta.json только имя файла water_file.
## Сеть: User-Agent из runtime_terrain, кеш в user://terrain_cache, ctx.net_requests += 1 на запрос;
## ctx.offline — только локальные файлы и кеш (иначе ERR_UNAVAILABLE).
## Необязательный ctx.spec.dem_sources (проверки без сети, паритет): copernicus_dir — папка с
## <имя>.tif, terrarium_dir — папка z/x/y.png (только чтение), terrarium_cache_dir — куда писать
## скачанные тайлы Terrarium вместо user://terrain_cache/terrarium.

const EARTH_R_M := 6371008.8
const HEADER_BYTES := 65536
const TILE_PX := 256
const COP_NAME := "Copernicus_DSM_COG_10_%s%02d_00_%s%03d_00_DEM"
const COP_URL := "https://copernicus-dem-30m.s3.amazonaws.com/%s/%s.tif"
const ATTRIBUTION := {
	"copernicus":
	(
		"Copernicus DEM GLO-30: produced using Copernicus WorldDEM-30 "
		+ "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 "
		+ "provided under COPERNICUS by the European Union and ESA"
	),
	"terrarium":
	(
		"Terrain Tiles (Mapzen/AWS Open Data): SRTM, GMTED2010, ETOPO1 и др.; "
		+ "см. https://github.com/tilezen/joerd/blob/master/docs/attribution.md"
	),
}

var _ctx: LocationBuildContext
var _rt: Dictionary = {}
var _src: Dictionary = {}
var _err: Error = OK
var _tree: SceneTree


func run(ctx: LocationBuildContext) -> Error:
	_ctx = ctx
	_err = OK
	_tree = Engine.get_main_loop() as SceneTree
	_rt = Config.get_config("world").get("runtime_terrain", {})
	_src = ctx.spec.get("dem_sources", {})
	var layer_cfgs: Array = ctx.spec.get("dem", {}).get("layers", [])
	if layer_cfgs.is_empty():
		ctx.log_line("DemStage: в конфиге места нет dem.layers")
		return ERR_INVALID_PARAMETER
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	ctx.heights = {}
	ctx.layers = {}
	var built: Array[Dictionary] = []  # {h: PackedFloat32Array, info}
	var meta := {
		"location": ctx.key,
		"center_lat": ctx.center_lat,
		"center_lon": ctx.center_lon,
		"earth_radius_m": EARTH_R_M,
		"layers": [],
		"attribution": [],
	}
	for k in layer_cfgs.size():
		if ctx.cancelled:
			return ERR_SKIP
		var lc: Dictionary = layer_cfgs[k]
		var base := float(k) / layer_cfgs.size()
		var span := 1.0 / layer_cfgs.size()
		var g := _grid(lc)
		var src := String(lc.source)
		var h64: PackedFloat64Array
		if src == "copernicus":
			h64 = await _sample_copernicus(g, base, span * 0.8)
		elif src == "terrarium":
			h64 = await _sample_terrarium(g, int(lc.zoom), base, span * 0.8)
		else:
			ctx.log_line("DemStage: неизвестный источник %s" % src)
			return ERR_INVALID_PARAMETER
		if _err != OK:
			return _err
		if ctx.cancelled:
			return ERR_SKIP
		var sigma := float(lc.get("smooth_sigma_cells", 0.0))
		var q := float(lc.get("quantize_per_m", 32))
		var h := await _finish(h64, int(g.n), sigma, q)
		ctx.report("dem", base + span * 0.9)
		var info := {
			"id": String(lc.id),
			"file": "%s.f32.zst" % lc.id,
			"width": int(g.n),
			"height": int(g.n),
			"spacing_m": float(g.step),
			"origin_x_m": -float(g.half),
			"origin_z_m": -float(g.half),
			"source": src,
			"water_file": "%s_water.png" % lc.id,
		}
		# Там, где есть более детальный слой, грубый берёт высоты из него (узлы сеток выровнены).
		for b in built:
			_patch_from_finer(h, info, b.h, b.info)
		var mm := _min_max(h)
		info["min_height_m"] = mm.x
		info["max_height_m"] = mm.y
		built.append({"h": h, "info": info})
		ctx.heights[info.id] = h
		ctx.layers[info.id] = info
		(meta.layers as Array).append(info)
		if not (meta.attribution as Array).has(ATTRIBUTION[src]):
			(meta.attribution as Array).append(ATTRIBUTION[src])
		var werr := _write_layer(ctx.dir.path_join(String(info.file)), h)
		if werr != OK:
			ctx.log_line("DemStage: не записан %s" % info.file)
			return werr
	var f := FileAccess.open(ctx.dir.path_join("meta.json"), FileAccess.WRITE)
	if f == null:
		ctx.log_line("DemStage: не записан meta.json")
		return ERR_CANT_CREATE
	f.store_string(JSON.stringify(meta, "  ") + "\n")
	f.close()
	ctx.report("dem", 1.0)
	return OK


# ---------- сетка и проекция ----------


## Узлы слоя: n, step, half и широта каждой строки / долгота каждого столбца (проекция fetch_dem.py).
func _grid(lc: Dictionary) -> Dictionary:
	var step := float(lc.spacing_m)
	var n := int(round(float(lc.size_km) * 1000.0 / step)) + 1
	var half := (n - 1) * step / 2.0
	var m_lat := EARTH_R_M * PI / 180.0
	var m_lon := m_lat * cos(deg_to_rad(_ctx.center_lat))
	var lats := PackedFloat64Array()
	var lons := PackedFloat64Array()
	lats.resize(n)
	lons.resize(n)
	for k in n:
		var c := -half + k * step
		lats[k] = _ctx.center_lat - c / m_lat
		lons[k] = _ctx.center_lon + c / m_lon
	return {"n": n, "step": step, "half": half, "lats": lats, "lons": lons}


## Параллельный запуск fn(индекс, …) для индексов 0..count-1; главный поток не блокируется.
func _group(fn: Callable, count: int) -> void:
	var tid := WorkerThreadPool.add_group_task(fn, count, -1, true, "dem_stage")
	while not WorkerThreadPool.is_group_task_completed(tid):
		if _tree != null:
			await _tree.process_frame
		else:
			OS.delay_msec(5)
	WorkerThreadPool.wait_for_group_task_completion(tid)


## Объединяет построчные массивы в один плоский.
static func _concat64(rows: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for r: PackedFloat64Array in rows:
		out.append_array(r)
	return out


# ---------- Copernicus ----------


func _sample_copernicus(g: Dictionary, prog0: float, prog_span: float) -> PackedFloat64Array:
	var n := int(g.n)
	var lats: PackedFloat64Array = g.lats
	var lons: PackedFloat64Array = g.lons
	var la_rows := PackedInt32Array()
	var lo_cols := PackedInt32Array()
	la_rows.resize(n)
	lo_cols.resize(n)
	for k in n:
		la_rows[k] = floori(lats[k])
		lo_cols[k] = floori(lons[k])
	# Сегменты одинаковой долготы по столбцам, одинаковой широты по строкам.
	var segs: Array = []  # [c0, c1, lo]
	var rsegs: Array = []  # [r0, r1, la]
	for k in n:
		if segs.is_empty() or int(segs[-1][2]) != lo_cols[k]:
			segs.append([k, k, lo_cols[k]])
		else:
			segs[-1][1] = k
		if rsegs.is_empty() or int(rsegs[-1][2]) != la_rows[k]:
			rsegs.append([k, k, la_rows[k]])
		else:
			rsegs[-1][1] = k
	# Файлы 1°×1°: заголовки.
	var files: Dictionary = {}  # Vector2i(la, lo) → описание
	for rs in rsegs:
		for cs in segs:
			var fkey := Vector2i(int(rs[2]), int(cs[2]))
			var fd := await _open_cop(fkey.x, fkey.y)
			if _err != OK:
				return PackedFloat64Array()
			fd["rseg"] = rs
			fd["cseg"] = cs
			files[fkey] = fd
	# Нужные блоки каждого файла.
	var jobs: Array = []  # {key, tx, ty}
	for fkey: Vector2i in files:
		var fd: Dictionary = files[fkey]
		if fd.nodata:
			continue
		var cog: CogReader = fd.cog
		var lv: Dictionary = cog.levels[0]
		var cols := int(lv.width)
		var rows := int(lv.height)
		var rs: Array = fd.rseg
		var cs: Array = fd.cseg
		var fy0 := (fkey.x + 1 - lats[int(rs[0])]) * rows
		var fy1 := (fkey.x + 1 - lats[int(rs[1])]) * rows
		var fx0 := (lons[int(cs[0])] - fkey.y) * cols
		var fx1 := (lons[int(cs[1])] - fkey.y) * cols
		var ymin := clampi(floori(minf(fy0, fy1)), 0, rows - 1)
		var ymax := clampi(floori(maxf(fy0, fy1)) + 1, 0, rows - 1)
		var xmin := clampi(floori(minf(fx0, fx1)), 0, cols - 1)
		var xmax := clampi(floori(maxf(fx0, fx1)) + 1, 0, cols - 1)
		var tw := int(lv.tile_w)
		var th := int(lv.tile_h)
		fd["tx0"] = xmin / tw
		fd["ty0"] = ymin / th
		fd["tx1"] = xmax / tw
		fd["ty1"] = ymax / th
		for ty in range(int(fd.ty0), int(fd.ty1) + 1):
			for tx in range(int(fd.tx0), int(fd.tx1) + 1):
				jobs.append({"key": fkey, "tx": tx, "ty": ty})
	# Скачать/прочитать блоки.
	var queue := jobs.duplicate()
	var state := {"left": jobs.size()}
	var workers := mini(int(_rt.get("max_parallel_requests", 8)), jobs.size())
	for w in workers:
		_cop_worker(files, queue, state)
	while int(state.left) > 0 and _err == OK and not _ctx.cancelled:
		await _tree.process_frame
	if _err != OK:
		return PackedFloat64Array()
	if _ctx.cancelled:
		return PackedFloat64Array()
	_ctx.report("dem", prog0 + prog_span * 0.4)
	# Распаковка блоков (предиктор 3 — тяжёлый цикл) параллельно.
	var decoded: Array = []
	decoded.resize(jobs.size())
	await _group(_decode_cop.bind(jobs, files, decoded), jobs.size())
	_ctx.report("dem", prog0 + prog_span * 0.7)
	# Мозаики блоков каждого файла.
	for fkey: Vector2i in files:
		var fd: Dictionary = files[fkey]
		if fd.nodata:
			continue
		var lv: Dictionary = (fd.cog as CogReader).levels[0]
		var tw := int(lv.tile_w)
		var th := int(lv.tile_h)
		var mw := (int(fd.tx1) - int(fd.tx0) + 1) * tw
		var mh := (int(fd.ty1) - int(fd.ty0) + 1) * th
		var mos := Image.create_empty(mw, mh, false, Image.FORMAT_RF)
		for k in jobs.size():
			var jb: Dictionary = jobs[k]
			if jb.key != fkey:
				continue
			var img := Image.create_from_data(tw, th, false, Image.FORMAT_RF, (decoded[k] as PackedFloat32Array).to_byte_array())
			mos.blit_rect(img, Rect2i(0, 0, tw, th), Vector2i((int(jb.tx) - int(fd.tx0)) * tw, (int(jb.ty) - int(fd.ty0)) * th))
		fd["mos"] = mos.get_data().to_float32_array()
		fd["mw"] = mw
		fd["mx0"] = int(fd.tx0) * tw
		fd["my0"] = int(fd.ty0) * th
		fd["cols"] = int(lv.width)
		fd["rows"] = int(lv.height)
	var cs := {"n": n, "lats": lats, "lons": lons, "la_rows": la_rows, "segs": segs, "files": files}
	var rows_out: Array = []
	rows_out.resize(n)
	await _group(_cop_row.bind(cs, rows_out), n)
	return _concat64(rows_out)


## Заголовок COG тайла 1°×1° (или null-запись nodata — тайла нет, море). Ошибка — в _err.
func _open_cop(la: int, lo: int) -> Dictionary:
	var name := COP_NAME % ["N" if la >= 0 else "S", absi(la), "E" if lo >= 0 else "W", absi(lo)]
	var fd := {"name": name, "url": COP_URL % [name, name], "nodata": false, "local": ""}
	var local_dir := String(_src.get("copernicus_dir", ""))
	if local_dir != "" and FileAccess.file_exists(local_dir.path_join(name + ".tif")):
		fd.local = local_dir.path_join(name + ".tif")
	var size := HEADER_BYTES
	for attempt in 3:
		var head := await _cop_bytes(fd, 0, size, "header.bin" if size == HEADER_BYTES else "header_%d.bin" % size)
		if _err != OK:
			return fd
		if head.is_empty():  # 404/403: тайла нет
			fd.nodata = true
			return fd
		var cog := CogReader.parse(head)
		if cog.error == "need_more" and attempt < 2:
			size *= 4
			continue
		if not cog.is_valid() or not bool(cog.levels[0].float32):
			_ctx.log_line("DemStage: %s — %s" % [name, cog.error if cog.error != "" else "не float32"])
			_err = ERR_FILE_CORRUPT
			return fd
		fd["cog"] = cog
		return fd
	_err = ERR_FILE_CORRUPT
	return fd


func _cop_worker(files: Dictionary, queue: Array, state: Dictionary) -> void:
	while not queue.is_empty() and _err == OK and not _ctx.cancelled:
		var jb: Dictionary = queue.pop_back()
		var fd: Dictionary = files[jb.key]
		var cog: CogReader = fd.cog
		var idx := cog.tile_index(0, int(jb.tx), int(jb.ty))
		var off := int(cog.levels[0].offsets[idx])
		var cnt := int(cog.levels[0].counts[idx])
		var raw := PackedByteArray()
		if cnt > 0:
			raw = await _cop_bytes(fd, off, cnt, "L0_%d_%d.bin" % [jb.tx, jb.ty])
			if _err != OK:
				return
			if raw.is_empty():
				_err = ERR_FILE_CORRUPT
				_ctx.log_line("DemStage: пустой блок %s" % fd.name)
				return
		jb["raw"] = raw
		state.left = int(state.left) - 1


func _decode_cop(k: int, jobs: Array, files: Dictionary, out: Array) -> void:
	var jb: Dictionary = jobs[k]
	var cog: CogReader = (files[jb.key] as Dictionary).cog
	out[k] = cog.decode_tile_f32(0, jb.raw)


## Строка j: билинейная выборка (рабочий поток). Пишет PackedFloat64Array в out[j].
func _cop_row(j: int, cs: Dictionary, out: Array) -> void:
	var n := int(cs.n)
	var lat: float = cs.lats[j]
	var lons: PackedFloat64Array = cs.lons
	var la: int = cs.la_rows[j]
	var row := PackedFloat64Array()
	row.resize(n)
	for seg: Array in cs.segs:
		var fd: Dictionary = cs.files[Vector2i(la, int(seg[2]))]
		if fd.nodata:
			continue
		var cols := int(fd.cols)
		var rows := int(fd.rows)
		var mos: PackedFloat32Array = fd.mos
		var mw := int(fd.mw)
		var mx0 := int(fd.mx0)
		var fy := clampf((la + 1 - lat) * rows, 0.0, rows - 0.000001)
		var y0 := int(fy)
		var ty := fy - y0
		var r0 := (y0 - int(fd.my0)) * mw
		var r1 := (mini(y0 + 1, rows - 1) - int(fd.my0)) * mw
		var lo := float(seg[2])
		var cmax := cols - 0.000001
		for i in range(int(seg[0]), int(seg[1]) + 1):
			var fx := clampf((lons[i] - lo) * cols, 0.0, cmax)
			var x0 := int(fx)
			var tx := fx - x0
			var x1 := mini(x0 + 1, cols - 1) - mx0
			x0 -= mx0
			row[i] = (mos[r0 + x0] * (1.0 - tx) + mos[r0 + x1] * tx) * (1.0 - ty) + (mos[r1 + x0] * (1.0 - tx) + mos[r1 + x1] * tx) * ty
	out[j] = row


## Байты [start, start+size) файла Copernicus: локальный файл, кеш или range-запрос.
## Пусто без ошибки — тайла нет (404/403). Ошибка сети/офлайн — в _err.
func _cop_bytes(fd: Dictionary, start: int, size: int, cache_name: String) -> PackedByteArray:
	if String(fd.local) != "":
		var f := FileAccess.open(String(fd.local), FileAccess.READ)
		if f == null:
			_err = ERR_FILE_CANT_READ
			return PackedByteArray()
		f.seek(start)
		return f.get_buffer(size)
	var dir := String(_rt.get("cache_dir", "user://terrain_cache")).path_join("copernicus").path_join(String(fd.name))
	if FileAccess.file_exists(dir.path_join("nodata")):
		return PackedByteArray()
	var path := dir.path_join(cache_name)
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_bytes(path)
	if _ctx.offline:
		_ctx.log_line("DemStage: офлайн, нет в кеше %s/%s" % [fd.name, cache_name])
		_err = ERR_UNAVAILABLE
		return PackedByteArray()
	var res := await _http(String(fd.url), PackedStringArray(["Range: bytes=%d-%d" % [start, start + size - 1]]))
	if _err != OK:
		return PackedByteArray()
	var code := int(res.code)
	DirAccess.make_dir_recursive_absolute(dir)
	if code == 403 or code == 404:
		var nf := FileAccess.open(dir.path_join("nodata"), FileAccess.WRITE)
		if nf != null:
			nf.store_string("0")
			nf.close()
		return PackedByteArray()
	if code != 200 and code != 206:
		_ctx.log_line("DemStage: %s → HTTP %d" % [fd.name, code])
		_err = ERR_CONNECTION_ERROR
		return PackedByteArray()
	var data: PackedByteArray = res.body
	if code == 200:
		data = data.slice(start, start + size)
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out != null:
		out.store_buffer(data)
		out.close()
	return data


# ---------- Terrarium ----------


func _sample_terrarium(g: Dictionary, z: int, prog0: float, prog_span: float) -> PackedFloat64Array:
	var n := int(g.n)
	var world := float(TILE_PX << z)
	var lats: PackedFloat64Array = g.lats
	var lons: PackedFloat64Array = g.lons
	var gxs := PackedFloat64Array()
	var gys := PackedFloat64Array()
	gxs.resize(n)
	gys.resize(n)
	for k in n:
		gxs[k] = (lons[k] + 180.0) / 360.0 * world - 0.5
		var lat_r := deg_to_rad(lats[k])
		gys[k] = (1.0 - log(tan(lat_r) + 1.0 / cos(lat_r)) / PI) / 2.0 * world - 0.5
	var gx_min := minf(gxs[0], gxs[n - 1])
	var gx_max := maxf(gxs[0], gxs[n - 1])
	var gy_min := minf(gys[0], gys[n - 1])
	var gy_max := maxf(gys[0], gys[n - 1])
	var tx0 := floori(gx_min / TILE_PX)
	var ty0 := floori(gy_min / TILE_PX)
	var tx1 := floori((floori(gx_max) + 1) / float(TILE_PX))
	var ty1 := floori((floori(gy_max) + 1) / float(TILE_PX))
	var tiles: Array[Vector2i] = []
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			tiles.append(Vector2i(tx, ty))
	var pngs := {}
	var queue := tiles.duplicate()
	var state := {"left": tiles.size()}
	var workers := mini(int(_rt.get("max_parallel_requests", 8)), tiles.size())
	for w in workers:
		_tr_worker(z, queue, pngs, state)
	while int(state.left) > 0 and _err == OK and not _ctx.cancelled:
		await _tree.process_frame
	if _err != OK or _ctx.cancelled:
		return PackedFloat64Array()
	_ctx.report("dem", prog0 + prog_span * 0.4)
	var decoded: Array = []
	decoded.resize(tiles.size())
	await _group(_decode_tr.bind(tiles, pngs, decoded), tiles.size())
	if _err != OK:
		return PackedFloat64Array()
	var mw := (tx1 - tx0 + 1) * TILE_PX
	var mh := (ty1 - ty0 + 1) * TILE_PX
	var mos := Image.create_empty(mw, mh, false, Image.FORMAT_RF)
	for k in tiles.size():
		var img := Image.create_from_data(TILE_PX, TILE_PX, false, Image.FORMAT_RF, (decoded[k] as PackedFloat32Array).to_byte_array())
		mos.blit_rect(img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i((tiles[k].x - tx0) * TILE_PX, (tiles[k].y - ty0) * TILE_PX))
	var ts := {
		"n": n,
		"gxs": gxs,
		"gys": gys,
		"mos": mos.get_data().to_float32_array(),
		"mw": mw,
		"mh": mh,
		"ox": tx0 * TILE_PX,
		"oy": ty0 * TILE_PX,
	}
	var rows_out: Array = []
	rows_out.resize(n)
	await _group(_tr_row.bind(ts, rows_out), n)
	return _concat64(rows_out)


func _tr_worker(z: int, queue: Array, pngs: Dictionary, state: Dictionary) -> void:
	while not queue.is_empty() and _err == OK and not _ctx.cancelled:
		var t: Vector2i = queue.pop_back()
		var data := await _tr_bytes(z, t.x, t.y)
		if _err != OK:
			return
		pngs[t] = data
		state.left = int(state.left) - 1


func _decode_tr(k: int, tiles: Array[Vector2i], pngs: Dictionary, out: Array) -> void:
	var img := Image.new()
	var res := PackedFloat32Array()
	if img.load_png_from_buffer(pngs[tiles[k]]) != OK or img.get_width() != TILE_PX or img.get_height() != TILE_PX:
		out[k] = res
		_err = ERR_FILE_CORRUPT
		return
	img.convert(Image.FORMAT_RGB8)
	var b := img.get_data()
	var cnt := TILE_PX * TILE_PX
	res.resize(cnt)
	for p in cnt:
		var q := p * 3
		res[p] = b[q] * 256.0 + b[q + 1] + b[q + 2] / 256.0 - 32768.0
	out[k] = res


func _tr_row(j: int, ts: Dictionary, out: Array) -> void:
	var n := int(ts.n)
	var mos: PackedFloat32Array = ts.mos
	var mw := int(ts.mw)
	var gxs: PackedFloat64Array = ts.gxs
	var ox := float(ts.ox)
	var fy := clampf(float(ts.gys[j]) - float(ts.oy), 0.0, int(ts.mh) - 1.000001)
	var y0 := int(fy)
	var ty := fy - y0
	var r0 := y0 * mw
	var r1 := r0 + mw
	var xmax := mw - 1.000001
	var row := PackedFloat64Array()
	row.resize(n)
	for i in n:
		var fx := clampf(gxs[i] - ox, 0.0, xmax)
		var x0 := int(fx)
		var tx := fx - x0
		row[i] = (mos[r0 + x0] * (1.0 - tx) + mos[r0 + x0 + 1] * tx) * (1.0 - ty) + (mos[r1 + x0] * (1.0 - tx) + mos[r1 + x0 + 1] * tx) * ty
	out[j] = row


## PNG тайла Terrarium: локальная папка (только чтение), кеш или сеть. Ошибка — в _err.
func _tr_bytes(z: int, x: int, y: int) -> PackedByteArray:
	var n := 1 << z
	x = posmod(x, n)
	y = clampi(y, 0, n - 1)
	var rel := "%d/%d/%d.png" % [z, x, y]
	var local_dir := String(_src.get("terrarium_dir", ""))
	if local_dir != "" and FileAccess.file_exists(local_dir.path_join(rel)):
		return FileAccess.get_file_as_bytes(local_dir.path_join(rel))
	var cache_dir := String(_src.get("terrarium_cache_dir", ""))
	if cache_dir == "":
		cache_dir = String(_rt.get("cache_dir", "user://terrain_cache")).path_join("terrarium")
	var path := cache_dir.path_join(rel)
	if FileAccess.file_exists(path):
		var cached := FileAccess.get_file_as_bytes(path)
		if not cached.is_empty():
			return cached
	if _ctx.offline:
		_ctx.log_line("DemStage: офлайн, нет тайла Terrarium %s" % rel)
		_err = ERR_UNAVAILABLE
		return PackedByteArray()
	var url := String(_rt.get("url_template", "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png")).format({"z": z, "x": x, "y": y})
	var res := await _http(url, PackedStringArray())
	if _err != OK:
		return PackedByteArray()
	if int(res.code) != 200:
		_ctx.log_line("DemStage: тайл Terrarium %s → HTTP %d" % [rel, int(res.code)])
		_err = ERR_CONNECTION_ERROR
		return PackedByteArray()
	var data: PackedByteArray = res.body
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out != null:
		out.store_buffer(data)
		out.close()
	return data


# ---------- сеть ----------


## GET под ctx.host: {code, body}. Сбой соединения после двух попыток — _err = ERR_CONNECTION_ERROR.
func _http(url: String, extra: PackedStringArray) -> Dictionary:
	var host: Node = _ctx.host
	if host == null or not host.is_inside_tree():
		_ctx.log_line("DemStage: нет узла для HTTPRequest")
		_err = ERR_UNCONFIGURED
		return {}
	var ua := RasterTileLoader.expand_user_agent(String(_rt.get("user_agent", "deltaplan/{version}")))
	var headers := PackedStringArray(["User-Agent: " + ua])
	headers.append_array(extra)
	for attempt in 2:
		var req := HTTPRequest.new()
		req.timeout = float(_rt.get("timeout_s", 30.0))
		req.use_threads = true
		host.add_child(req)
		_ctx.net_requests += 1
		if req.request(url, headers) != OK:
			req.queue_free()
			continue
		var res: Array = await req.request_completed
		req.queue_free()
		if int(res[0]) == HTTPRequest.RESULT_SUCCESS:
			return {"code": int(res[1]), "body": res[3]}
		if _ctx.cancelled:
			break
	_ctx.log_line("DemStage: нет ответа %s" % url)
	_err = ERR_CONNECTION_ERROR
	return {}


# ---------- обработка слоя ----------


## Сглаживание (σ в клетках), квантование до 1/q м, float32. Рабочие потоки по строкам.
func _finish(h64: PackedFloat64Array, n: int, sigma: float, q: float) -> PackedFloat32Array:
	var src := h64
	if sigma > 0.0:
		var r := maxi(1, ceili(sigma * 3.0))
		var k := PackedFloat64Array()
		var ksum := 0.0
		for t in 2 * r + 1:
			var v := exp(-0.5 * pow((t - r) / sigma, 2.0))
			k.append(v)
			ksum += v
		for t in k.size():
			k[t] /= ksum
		var tmp_rows: Array = []
		tmp_rows.resize(n)
		await _group(_blur_h.bind(src, n, k, r, tmp_rows), n)
		var tmp := _concat64(tmp_rows)
		var out_rows: Array = []
		out_rows.resize(n)
		await _group(_blur_v.bind(tmp, n, k, r, q, out_rows), n)
		return _concat32(out_rows)
	var rows: Array = []
	rows.resize(n)
	await _group(_quant_row.bind(src, n, q, rows), n)
	return _concat32(rows)


static func _concat32(rows: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for r: PackedFloat32Array in rows:
		out.append_array(r)
	return out


func _blur_h(j: int, a: PackedFloat64Array, n: int, k: PackedFloat64Array, r: int, out: Array) -> void:
	var p := PackedFloat64Array()
	p.resize(n + 2 * r)
	var base := j * n
	for i in r:
		p[i] = a[base]
		p[n + r + i] = a[base + n - 1]
	for i in n:
		p[r + i] = a[base + i]
	var row := PackedFloat64Array()
	row.resize(n)
	var taps := 2 * r + 1
	for i in n:
		var s := 0.0
		for t in taps:
			s += k[t] * p[i + t]
		row[i] = s
	out[j] = row


func _blur_v(j: int, a: PackedFloat64Array, n: int, k: PackedFloat64Array, r: int, q: float, out: Array) -> void:
	var taps := 2 * r + 1
	var bases := PackedInt32Array()
	for t in taps:
		bases.append(clampi(j + t - r, 0, n - 1) * n)
	var row := PackedFloat32Array()
	row.resize(n)
	for i in n:
		var s := 0.0
		for t in taps:
			s += k[t] * a[bases[t] + i]
		row[i] = roundf(s * q) / q
	out[j] = row


func _quant_row(j: int, a: PackedFloat64Array, n: int, q: float, out: Array) -> void:
	var row := PackedFloat32Array()
	row.resize(n)
	var base := j * n
	for i in n:
		row[i] = roundf(a[base + i] * q) / q
	out[j] = row


## Грубый слой берёт высоты из детального там, где он есть (билинейно, как patch_from_finer).
func _patch_from_finer(h: PackedFloat32Array, info: Dictionary, fh: PackedFloat32Array, fine: Dictionary) -> void:
	var step := float(info.spacing_m)
	var w := int(info.width)
	var ox := float(info.origin_x_m)
	var oz := float(info.origin_z_m)
	var fw := int(fine.width)
	var fhh := int(fine.height)
	var fstep := float(fine.spacing_m)
	var fox := float(fine.origin_x_m)
	var foz := float(fine.origin_z_m)
	var fx1 := fox + (fw - 1) * fstep
	var fz1 := foz + (fhh - 1) * fstep
	var cis: Array[int] = []
	var ris: Array[int] = []
	for i in w:
		var x := ox + i * step
		if x >= fox - 1e-6 and x <= fx1 + 1e-6:
			cis.append(i)
	for j in int(info.height):
		var z := oz + j * step
		if z >= foz - 1e-6 and z <= fz1 + 1e-6:
			ris.append(j)
	for j in ris:
		var fz := clampf((oz + j * step - foz) / fstep, 0.0, fhh - 1.000001)
		var z0 := int(fz)
		var tz := fz - z0
		for i in cis:
			var fx := clampf((ox + i * step - fox) / fstep, 0.0, fw - 1.000001)
			var x0 := int(fx)
			var tx := fx - x0
			var b := z0 * fw + x0
			h[j * w + i] = (fh[b] * (1.0 - tx) + fh[b + 1] * tx) * (1.0 - tz) + (fh[b + fw] * (1.0 - tx) + fh[b + fw + 1] * tx) * tz


static func _min_max(h: PackedFloat32Array) -> Vector2:
	var lo := h[0]
	var hi := h[0]
	for v in h:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return Vector2(lo, hi)


func _write_layer(path: String, h: PackedFloat32Array) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(h.to_byte_array().compress(FileAccess.COMPRESSION_ZSTD))
	f.close()
	return OK
