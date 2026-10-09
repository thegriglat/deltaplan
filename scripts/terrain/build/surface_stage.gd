class_name SurfaceStage
extends RefCounted
## Стадия покрова места (OA-К3, docs/contracts/osm-any.md): порт tools/terrain/fetch_landcover.py.
## Из ESA WorldCover 10 м (COG, HTTP range) считает для слоёв ctx.layers:
##   <id>_surface.png — класс игры в каждом узле сетки слоя (мода по k×k подвыборкам клетки,
##                      уровень COG и k — spec.surface.layers[id]);
##   detail_detail10.png (LA8) — L: доля леса в клетке 10 м (k×k подвыборок уровня 0, без моды),
##                      A = 0 (воду заполняет OsmStage);
##   surface.json — описание слоёв (water_fraction = 0).
## Классы: configs/world.json → surface.worldcover.classes. Тайлы COG кешируются в
## surface.runtime.cache_dir (имена файлов — как у WorldCoverLoader и tools/terrain/cog.py).

## Радиус Земли, м (тот же, что в fetch_dem.py и TerrainGeo).
const EARTH_R_M := 6371008.8
## Сколько байт начала файла читать как заголовок COG.
const HEADER_BYTES := 65536
const N_CLASSES := 9
## Строк результата на одну задачу пула потоков.
const BAND_ROWS := 32
const ATTRIBUTION := (
	"© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) "
	+ "processed by ESA WorldCover consortium; CC-BY 4.0"
)

## Кеш блоков COG. Пусто — surface.runtime.cache_dir из world.json.
var cache_dir: String = ""
## Дополнительные кеши только для чтения (папки с подпапками «<файл>.tif/», как у tools/terrain/cog.py).
var extra_cache_dirs: PackedStringArray = PackedStringArray()
## Шаблон адреса COG с {tile}. Пусто — surface.worldcover.url_template. Может быть локальным путём.
var url_template: String = ""
## Параллельных запросов.
var max_parallel: int = 4

var _wc: Dictionary = {}
var _lut := PackedByteArray()
var _cogs: Dictionary = {}
var _raw: Dictionary = {}
var _requests: Array[HTTPRequest] = []
var _ua := ""
var _timeout := 30.0


func run(ctx: LocationBuildContext) -> Error:
	_cogs.clear()
	_raw.clear()
	_load_cfg()
	if ctx.layers.is_empty():
		ctx.log_line("surface: нет слоёв сетки (ctx.layers)")
		return ERR_INVALID_PARAMETER
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	var scfg: Dictionary = ctx.spec.get("surface", {}).get("layers", {})
	var d10: Dictionary = Config.get_config("world").get("surface", {}).get("detail10", {})
	var work: Array = []
	for id in ctx.layers:
		if scfg.has(id):
			work.append(String(id))
	var out := {
		"_doc": "Собрано SurfaceStage (scripts/terrain/build/surface_stage.gd) — не править руками.",
		"source": "ESA WorldCover 10 m 2021 v200",
		"layers": [],
		"attribution": [ATTRIBUTION],
	}
	var step_i := 0
	for id: String in work:
		var info: Dictionary = ctx.layers[id]
		var lcfg: Dictionary = scfg[id]
		var w := int(info.width)
		var h := int(info.height)
		var spacing := float(info.spacing_m)
		var ox := float(info.origin_x_m)
		var oz := float(info.origin_z_m)
		var has10 := (d10.get("layers", []) as Array).has(id)
		var nsteps := float(work.size()) * (2.0 if has10 else 1.0)

		var res := await _classes(ctx, lcfg, w, h, spacing, ox, oz)
		if res.err != OK:
			return res.err
		var cls: PackedByteArray = res.data
		var name := "%s_surface.png" % id
		if not _save(ctx, name, w, h, Image.FORMAT_L8, cls):
			return ERR_FILE_CANT_WRITE
		var frac := {}
		for c in N_CLASSES:
			frac[str(c)] = snappedf(float(res.counts[c]) / float(w * h), 0.0001)
		var entry := {
			"id": id,
			"file": name,
			"width": w,
			"height": h,
			"spacing_m": spacing,
			"origin_x_m": ox,
			"origin_z_m": oz,
			"class_fraction": frac,
		}
		step_i += 1
		ctx.report("surface", step_i / nsteps)
		if ctx.cancelled:
			return ERR_SKIP

		if has10:
			var r10 := await _detail10(ctx, d10, w, h, spacing, ox, oz)
			if r10.err != OK:
				return r10.err
			var name10 := "%s_detail10.png" % id
			if not _save(ctx, name10, r10.w, r10.h, Image.FORMAT_LA8, r10.data):
				return ERR_FILE_CANT_WRITE
			entry["detail10"] = {
				"file": name10,
				"width": r10.w,
				"height": r10.h,
				"spacing_m": float(d10.cell_m),
				"origin_x_m": ox,
				"origin_z_m": oz,
				"channels": "L — доля леса (0..255, WorldCover), A — доля воды (0..255, OSM; заполняет OsmStage)",
				"forest_fraction": snappedf(r10.forest_fraction, 0.0001),
				"water_fraction": 0.0,
			}
			step_i += 1
			ctx.report("surface", step_i / nsteps)
		(out.layers as Array).append(entry)
		if ctx.cancelled:
			return ERR_SKIP
	var f := FileAccess.open(ctx.dir.path_join("surface.json"), FileAccess.WRITE)
	if f == null:
		ctx.log_line("surface: не записать surface.json")
		return ERR_FILE_CANT_WRITE
	f.store_string(JSON.stringify(out, "  ") + "\n")
	f.close()
	ctx.report("surface", 1.0)
	return OK


# ---------------------------------------------------------------------------------------------
# Расчёты слоёв
# ---------------------------------------------------------------------------------------------


## Класс в узлах сетки слоя: мода по k×k подвыборкам. → {err, data, counts}.
func _classes(
	ctx: LocationBuildContext, lcfg: Dictionary, w: int, h: int, step: float, ox: float, oz: float
) -> Dictionary:
	var k := int(lcfg.subsamples)
	if k < 1 or k > 7:
		ctx.log_line("surface: subsamples %d вне 1..7" % k)
		return {"err": ERR_INVALID_PARAMETER}
	var prep := await _prepare(ctx, int(lcfg.level), k, step, w, h, ox, oz)
	if prep.err != OK:
		return {"err": prep.err}
	var pw := PackedInt64Array()
	pw.resize(256)
	for code in 256:
		pw[code] = 1 << (6 * _lut[code])
	var job := {
		"mos": prep.mos,
		"cp": prep.col_px,
		"rb": prep.row_base,
		"pw": pw,
		"w": w,
		"h": h,
		"k": k,
		"bands": [],
	}
	var nb := (h + BAND_ROWS - 1) / BAND_ROWS
	(job.bands as Array).resize(nb)
	await _run_group(_band_classes.bind(job), nb)
	var data := PackedByteArray()
	var counts := PackedInt64Array()
	counts.resize(N_CLASSES)
	counts.fill(0)
	for b: Dictionary in job.bands:
		data.append_array(b.data)
		for c in N_CLASSES:
			counts[c] += b.counts[c]
	return {"err": OK, "data": data, "counts": counts}


## Маска 10 м: доля леса в клетке (k×k подвыборок уровня 0, без моды), LA8 с A = 0.
func _detail10(
	ctx: LocationBuildContext,
	dcfg: Dictionary,
	w_l: int,
	h_l: int,
	spacing: float,
	ox: float,
	oz: float
) -> Dictionary:
	var cell := float(dcfg.cell_m)
	var k := int(dcfg.subsamples)
	if k < 1 or k > 15:
		ctx.log_line("surface: detail10.subsamples %d вне 1..15" % k)
		return {"err": ERR_INVALID_PARAMETER}
	var w := roundi((w_l - 1) * spacing / cell) + 1
	var h := roundi((h_l - 1) * spacing / cell) + 1
	var prep := await _prepare(ctx, 0, k, cell, w, h, ox, oz)
	if prep.err != OK:
		return {"err": prep.err}
	var fl := PackedByteArray()
	fl.resize(256)
	for code in 256:
		fl[code] = 1 if _lut[code] == 1 else 0
	# значение L по числу лесных подвыборок (округление к чётному, как np.round)
	var rt := PackedByteArray()
	rt.resize(k * k + 1)
	for n in k * k + 1:
		rt[n] = int(roundf_even(n * (255.0 / (k * k))))
	var job := {
		"mos": prep.mos,
		"cp": prep.col_px,
		"rb": prep.row_base,
		"fl": fl,
		"rt": rt,
		"w": w,
		"h": h,
		"k": k,
		"bands": [],
	}
	var nb := (h + BAND_ROWS - 1) / BAND_ROWS
	(job.bands as Array).resize(nb)
	await _run_group(_band_forest.bind(job), nb)
	var data := PackedByteArray()
	var forest := 0
	for b: Dictionary in job.bands:
		data.append_array(b.data)
		forest += int(b.forest)
	return {
		"err": OK,
		"data": data,
		"w": w,
		"h": h,
		"forest_fraction": float(forest) / float(w * h)
	}


static func roundf_even(x: float) -> float:
	var f := floorf(x)
	var d := x - f
	if absf(d - 0.5) < 1e-9:
		return f if int(f) % 2 == 0 else f + 1.0
	return roundf(x)


## Полоса строк результата (рабочий поток): класс по моде.
func _band_classes(bi: int, job: Dictionary) -> void:
	var mos: PackedByteArray = job.mos
	var cp: PackedInt32Array = job.cp
	var rb: PackedInt32Array = job.rb
	var pw: PackedInt64Array = job.pw
	var w: int = job.w
	var k: int = job.k
	var j0 := bi * BAND_ROWS
	var j1 := mini(int(job.h), j0 + BAND_ROWS)
	var out := PackedByteArray()
	out.resize((j1 - j0) * w)
	var counts := PackedInt64Array()
	counts.resize(N_CLASSES)
	counts.fill(0)
	var o := 0
	for j in range(j0, j1):
		for i in w:
			var acc := 0
			for a in k:
				var base := rb[j * k + a]
				for b in k:
					acc += pw[mos[base + cp[i * k + b]]]
			var bc := 0
			var bn := (acc & 63) >> 1  # «нет данных» проигрывает при равенстве
			for c in range(1, N_CLASSES):
				var n := (acc >> (6 * c)) & 63
				if n > bn:
					bn = n
					bc = c
			out[o] = bc
			o += 1
			counts[bc] += 1
	(job.bands as Array)[bi] = {"data": out, "counts": counts}


## Полоса маски леса (рабочий поток): LA8, L — доля леса, A = 0.
func _band_forest(bi: int, job: Dictionary) -> void:
	var mos: PackedByteArray = job.mos
	var cp: PackedInt32Array = job.cp
	var rb: PackedInt32Array = job.rb
	var fl: PackedByteArray = job.fl
	var rt: PackedByteArray = job.rt
	var w: int = job.w
	var k: int = job.k
	var j0 := bi * BAND_ROWS
	var j1 := mini(int(job.h), j0 + BAND_ROWS)
	var out := PackedByteArray()
	out.resize((j1 - j0) * w * 2)
	out.fill(0)
	var forest := 0
	var o := 0
	for j in range(j0, j1):
		for i in w:
			var n := 0
			for a in k:
				var base := rb[j * k + a]
				for b in k:
					n += fl[mos[base + cp[i * k + b]]]
			var r := rt[n]
			out[o] = r
			o += 2
			if r >= 128:
				forest += 1
	(job.bands as Array)[bi] = {"data": out, "forest": forest}


func _run_group(c: Callable, n: int) -> void:
	var id := WorkerThreadPool.add_group_task(c, n, -1, true)
	while not WorkerThreadPool.is_group_task_completed(id):
		await _next_frame()
	WorkerThreadPool.wait_for_group_task_completion(id)


func _run_thread(c: Callable) -> void:
	var id := WorkerThreadPool.add_task(c, true)
	while not WorkerThreadPool.is_task_completed(id):
		await _next_frame()
	WorkerThreadPool.wait_for_task_completion(id)


var _tree: SceneTree


func _next_frame() -> void:
	if _tree != null:
		await _tree.process_frame
	else:
		OS.delay_msec(2)


func _empty_prep(w: int, h: int, k: int) -> Dictionary:
	var cp := PackedInt32Array()
	cp.resize(w * k)
	cp.fill(0)
	var rb := PackedInt32Array()
	rb.resize(h * k)
	rb.fill(0)
	return {"err": OK, "mos": PackedByteArray([0]), "col_px": cp, "row_base": rb}


# ---------------------------------------------------------------------------------------------
# Подготовка: файлы WorldCover, тайлы, мозаика
# ---------------------------------------------------------------------------------------------


## Для сетки w×h (шаг step от (ox, oz), k×k подвыборок на клетку) собрать мозаику кодов класса
## нужного окна пикселей уровня level и индексы столбцов/строк подвыборок в ней.
## → {err, mos, col_px, row_base}. Образец для всех файлов — единая глобальная сетка пикселей
## (файлы WorldCover 3°×3° лежат на целой сетке градусов).
func _prepare(
	ctx: LocationBuildContext, level: int, k: int, step: float, w: int, h: int, ox: float, oz: float
) -> Dictionary:
	if ctx.host != null and ctx.host.is_inside_tree():
		_tree = ctx.host.get_tree()
	var m_lat := EARTH_R_M * PI / 180.0
	var m_lon := m_lat * cos(deg_to_rad(ctx.center_lat))
	var offs := PackedFloat64Array()
	for q in k:
		offs.append((q + 0.5) / k - 0.5)
	# градусы подвыборок по осям
	var lat := PackedFloat64Array()
	lat.resize(h * k)
	for j in h:
		var z := oz + j * step
		for a in k:
			lat[j * k + a] = ctx.center_lat - (z + offs[a] * step) / m_lat
	var lon := PackedFloat64Array()
	lon.resize(w * k)
	for i in w:
		var x := ox + i * step
		for b in k:
			lon[i * k + b] = ctx.center_lon + (x + offs[b] * step) / m_lon
	# угол файла 3°×3° для каждой подвыборки
	var la3 := PackedInt32Array()
	la3.resize(lat.size())
	var la_set := {}
	for n in lat.size():
		la3[n] = int(floor(lat[n] / 3.0) * 3)
		la_set[la3[n]] = true
	var lo3 := PackedInt32Array()
	lo3.resize(lon.size())
	var lo_set := {}
	for n in lon.size():
		lo3[n] = int(floor(lon[n] / 3.0) * 3)
		lo_set[lo3[n]] = true
	# заголовки файлов
	var files := {}  # Vector2i(la, lo) → CogReader | null
	var first: CogReader = null
	for la: int in la_set:
		for lo: int in lo_set:
			var url := _url(la, lo)
			var r: Array = await _open(ctx, url)
			if r[0] != OK:
				return {"err": r[0]}
			files[Vector2i(la, lo)] = r[1]
			if r[1] != null and first == null:
				first = r[1]
			if ctx.cancelled:
				return {"err": ERR_SKIP}
	var empty := _empty_prep(w, h, k)
	if first == null or level >= first.levels.size():
		if first != null:
			ctx.log_line("surface: у файла WorldCover нет уровня %d" % level)
			return {"err": ERR_INVALID_DATA}
		return empty  # нет ни одного файла (океан): всё «нет данных»
	var lv0: Dictionary = first.levels[level]
	var fw := int(lv0.width)
	var fh := int(lv0.height)
	var kf := float(first.levels[0].width) / float(fw)
	var pix_x := first.pixel_deg.x * kf
	var pix_y := first.pixel_deg.y * kf
	# начало файла по осям: из любого существующего файла этой широты/долготы, иначе номинал
	var org_lon := {}
	var org_lat := {}
	for key: Vector2i in files:
		var c: CogReader = files[key]
		if c != null:
			org_lat[key.x] = c.origin_lat
			org_lon[key.y] = c.origin_lon
	var lo_min := 1 << 30
	for lo: int in lo_set:
		lo_min = mini(lo_min, lo)
	var la_max := -(1 << 30)
	for la: int in la_set:
		la_max = maxi(la_max, la)
	# глобальные пиксели подвыборок
	var colg := PackedInt32Array()
	colg.resize(lon.size())
	var g0 := 1 << 30
	var g1 := -1
	for n in lon.size():
		var olon: float = org_lon.get(lo3[n], float(lo3[n]))
		var px := int(floor((lon[n] - olon) / pix_x))
		if px < 0 or px >= fw:
			colg[n] = -1
			continue
		var g := ((lo3[n] - lo_min) / 3) * fw + px
		colg[n] = g
		g0 = mini(g0, g)
		g1 = maxi(g1, g)
	var rowg := PackedInt32Array()
	rowg.resize(lat.size())
	var r0 := 1 << 30
	var r1 := -1
	for n in lat.size():
		var olat: float = org_lat.get(la3[n], float(la3[n] + 3))
		var py := int(floor((olat - lat[n]) / pix_y))
		if py < 0 or py >= fh:
			rowg[n] = -1
			continue
		var g := ((la_max - la3[n]) / 3) * fh + py
		rowg[n] = g
		r0 = mini(r0, g)
		r1 = maxi(r1, g)
	if g1 < 0 or r1 < 0:
		return empty
	g1 += 1
	r1 += 1
	var mw := g1 - g0
	var mh := r1 - r0
	var mw1 := mw + 1
	# индексы в мозаике
	var cp := PackedInt32Array()
	cp.resize(colg.size())
	for n in colg.size():
		cp[n] = (colg[n] - g0) if colg[n] >= 0 else mw
	var rb := PackedInt32Array()
	rb.resize(rowg.size())
	for n in rowg.size():
		rb[n] = ((rowg[n] - r0) if rowg[n] >= 0 else mh) * mw1
	# тайлы, нужные каждому файлу
	var plan: Array = []  # {url, cog, a, b, tiles:[Vector2i]}
	for key: Vector2i in files:
		var c: CogReader = files[key]
		if c == null:
			continue
		var b := (key.y - lo_min) / 3
		var a := (la_max - key.x) / 3
		var gx0 := maxi(g0, b * fw)
		var gx1 := mini(g1, b * fw + fw)
		var gy0 := maxi(r0, a * fh)
		var gy1 := mini(r1, a * fh + fh)
		if gx0 >= gx1 or gy0 >= gy1:
			continue
		var lv: Dictionary = c.levels[level]
		var tw := int(lv.tile_w)
		var th := int(lv.tile_h)
		var tiles: Array[Vector2i] = []
		for ty in range((gy0 - a * fh) / th, (gy1 - 1 - a * fh) / th + 1):
			for tx in range((gx0 - b * fw) / tw, (gx1 - 1 - b * fw) / tw + 1):
				tiles.append(Vector2i(tx, ty))
		plan.append(
			{
				"url": _url(key.x, key.y),
				"cog": c,
				"a": a,
				"b": b,
				"tiles": tiles,
				"raw": {},
			}
		)
	for p: Dictionary in plan:
		var err := await _fetch_tiles(ctx, p.url, p.cog, level, p.tiles, p.raw)
		if err != OK:
			return {"err": err}
		if ctx.cancelled:
			return {"err": ERR_SKIP}
	# мозаика (рабочий поток)
	var mjob := {
		"plan": plan,
		"level": level,
		"fw": fw,
		"fh": fh,
		"g0": g0,
		"g1": g1,
		"r0": r0,
		"r1": r1,
		"mos": PackedByteArray(),
		"ok": true,
	}
	await _run_thread(_build_mosaic.bind(mjob))
	if not mjob.ok:
		ctx.log_line("surface: не удалось распаковать тайл WorldCover")
		return {"err": ERR_FILE_CORRUPT}
	return {"err": OK, "mos": mjob.mos, "col_px": cp, "row_base": rb}


## Мозаика кодов окна [g0, g1) × [r0, r1) глобальных пикселей (рабочий поток).
## Размер (mh + 1) × (mw + 1): последний столбец и последняя строка — нули («нет данных»).
func _build_mosaic(job: Dictionary) -> void:
	var plan: Array = job.plan
	var level: int = job.level
	var fw: int = job.fw
	var fh: int = job.fh
	var g0: int = job.g0
	var g1: int = job.g1
	var r0: int = job.r0
	var r1: int = job.r1
	var mw := g1 - g0
	var mh := r1 - r0
	var zero := PackedByteArray()
	zero.resize(maxi(mw + 1, 1))
	zero.fill(0)
	var by_ab := {}  # файлы по (a, b)
	for p: Dictionary in plan:
		by_ab[Vector2i(p.a, p.b)] = p
		p["dec"] = {}
	var b_lo := g0 / fw
	var b_hi := (g1 - 1) / fw
	var mos := PackedByteArray()
	mos.resize(0)
	for r in range(r0, r1):
		var a := r / fh
		var y := r - a * fh
		var row := PackedByteArray()
		for b in range(b_lo, b_hi + 1):
			var gx0 := maxi(g0, b * fw)
			var gx1 := mini(g1, b * fw + fw)
			if gx0 >= gx1:
				continue
			var p: Variant = by_ab.get(Vector2i(a, b))
			if p == null:
				row.append_array(zero.slice(0, gx1 - gx0))
				continue
			var cog: CogReader = p.cog
			var lv: Dictionary = cog.levels[level]
			var tw := int(lv.tile_w)
			var th := int(lv.tile_h)
			var ty := y / th
			var yy := y - ty * th
			var x := gx0 - b * fw
			var xe := gx1 - b * fw
			while x < xe:
				var tx := x / tw
				var xa := x - tx * tw
				var xb := mini(tw, xe - tx * tw)
				var key := Vector2i(tx, ty)
				var dec: Dictionary = p.dec
				if not dec.has(key):
					var d := cog.decode_tile(level, (p.raw as Dictionary).get(key, PackedByteArray()))
					if d.size() != tw * th:
						job.ok = false
						return
					dec[key] = d
				var t: PackedByteArray = dec[key]
				row.append_array(t.slice(yy * tw + xa, yy * tw + xb))
				x = (tx + 1) * tw
		row.append(0)
		mos.append_array(row)
	mos.append_array(zero.slice(0, mw + 1))
	job.mos = mos


# ---------------------------------------------------------------------------------------------
# Источник: заголовки и тайлы COG
# ---------------------------------------------------------------------------------------------


func _load_cfg() -> void:
	var surf: Dictionary = Config.get_config("world").get("surface", {})
	_wc = surf.get("worldcover", {})
	var rt: Dictionary = surf.get("runtime", {})
	if cache_dir == "":
		cache_dir = String(rt.get("cache_dir", "user://terrain_cache/worldcover"))
	if url_template == "":
		url_template = String(_wc.get("url_template", ""))
	_timeout = float(rt.get("timeout_s", 30.0))
	var rtt: Dictionary = Config.get_config("world").get("runtime_terrain", {})
	_ua = String(rtt.get("user_agent", "deltaplan-sim"))
	_lut.resize(256)
	_lut.fill(0)
	var classes: Dictionary = _wc.get("classes", {})
	for code in classes:
		_lut[int(code)] = int(classes[code])


func _url(la: int, lo: int) -> String:
	return url_template.format({"tile": WorldCoverLoader.tile_name(la, lo)})


## Заголовок COG файла. → [Error, CogReader | null] (null при OK — файла нет, океан).
func _open(ctx: LocationBuildContext, url: String) -> Array:
	if _cogs.has(url):
		return [OK, _cogs[url]]
	var r: Array = await _get_block(ctx, url, "header.bin", 0, HEADER_BYTES, true)
	if r[0] != OK:
		return [r[0], null]
	var cog: CogReader = null
	if not (r[1] as PackedByteArray).is_empty():
		cog = CogReader.parse(r[1])
		if not cog.is_valid():
			ctx.log_line("surface: %s — %s" % [url.get_file(), cog.error])
			return [ERR_FILE_CORRUPT, null]
	_cogs[url] = cog
	return [OK, cog]


## Скачать (или взять из кеша) сырые тайлы уровня level. raw: Vector2i → PackedByteArray.
func _fetch_tiles(
	ctx: LocationBuildContext,
	url: String,
	cog: CogReader,
	level: int,
	tiles: Array[Vector2i],
	raw: Dictionary
) -> Error:
	var lv: Dictionary = cog.levels[level]
	var state := {"err": OK, "left": tiles.size()}
	var queue: Array[Vector2i] = tiles.duplicate()
	var workers := maxi(1, mini(max_parallel, queue.size()))
	for q in workers:
		_tile_worker(ctx, url, cog, level, lv, queue, raw, state)
	while int(state.left) > 0 and int(state.err) == OK and not ctx.cancelled:
		await _next_frame()
	return state.err


func _tile_worker(
	ctx: LocationBuildContext,
	url: String,
	cog: CogReader,
	level: int,
	lv: Dictionary,
	queue: Array[Vector2i],
	raw: Dictionary,
	state: Dictionary
) -> void:
	while not queue.is_empty() and int(state.err) == OK and not ctx.cancelled:
		var t: Vector2i = queue.pop_back()
		var idx := cog.tile_index(level, t.x, t.y)
		var off := int(lv.offsets[idx])
		var cnt := int(lv.counts[idx])
		var data := PackedByteArray()
		if cnt > 0:
			var r: Array = await _get_block(ctx, url, "L%d_%d_%d.bin" % [level, t.x, t.y], off, cnt, false)
			if r[0] != OK:
				state.err = r[0]
				return
			data = r[1]
		raw[t] = data
		state.left = int(state.left) - 1


## Блок [start, start + size) файла url. → [Error, PackedByteArray]. Для заголовка пустой массив
## при OK — файла нет. Порядок: кеш, дополнительные кеши, локальный файл, сеть.
func _get_block(
	ctx: LocationBuildContext, url: String, name: String, start: int, size: int, is_header: bool
) -> Array:
	var base := url.get_file()
	var path := cache_dir.path_join(base.get_basename()).path_join(name)
	if FileAccess.file_exists(path):
		var d := FileAccess.get_file_as_bytes(path)
		if is_header or d.size() == size:
			return [OK, d]
	if is_header and FileAccess.file_exists(path.get_base_dir().path_join("header.none")):
		return [OK, PackedByteArray()]
	for dir in extra_cache_dirs:
		var p := dir.path_join(base).path_join(name)
		if FileAccess.file_exists(p):
			var d := FileAccess.get_file_as_bytes(p)
			if is_header or d.size() == size:
				return [OK, d]
	if not url.begins_with("http"):
		return _read_local(ctx, url, start, size, is_header)
	if ctx.offline:
		ctx.log_line("surface: нет в кеше (offline): %s %s" % [base, name])
		return [ERR_UNAVAILABLE, PackedByteArray()]
	if ctx.host == null:
		ctx.log_line("surface: нет узла host для HTTP")
		return [ERR_UNCONFIGURED, PackedByteArray()]
	var req := HTTPRequest.new()
	req.timeout = _timeout
	req.use_threads = true
	ctx.host.add_child(req)
	_requests.append(req)
	var headers := PackedStringArray(
		["User-Agent: " + _ua, "Range: bytes=%d-%d" % [start, start + size - 1]]
	)
	var code := 0
	var body := PackedByteArray()
	var ok := false
	for attempt in 3:
		ctx.net_requests += 1
		if req.request(url, headers) != OK:
			break
		var res: Array = await req.request_completed
		code = int(res[1])
		if int(res[0]) == HTTPRequest.RESULT_SUCCESS and (code == 206 or code == 200):
			body = res[3]
			ok = true
			break
		if code == 403 or code == 404:
			break
	_requests.erase(req)
	req.queue_free()
	if not ok:
		if is_header and (code == 403 or code == 404):  # файла нет (океан)
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var fn := FileAccess.open(path.get_base_dir().path_join("header.none"), FileAccess.WRITE)
			if fn != null:
				fn.close()
			return [OK, PackedByteArray()]
		ctx.log_line("surface: %s %s → HTTP %d" % [base, name, code])
		return [ERR_CANT_CONNECT, PackedByteArray()]
	if code == 200:
		body = body.slice(start, start + size)  # сервер отдал весь файл
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(body)
		f.close()
	return [OK, body]


func _read_local(
	ctx: LocationBuildContext, path: String, start: int, size: int, is_header: bool
) -> Array:
	if not FileAccess.file_exists(path):
		if is_header:
			return [OK, PackedByteArray()]
		ctx.log_line("surface: нет файла %s" % path)
		return [ERR_FILE_NOT_FOUND, PackedByteArray()]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [ERR_FILE_CANT_OPEN, PackedByteArray()]
	f.seek(start)
	var d := f.get_buffer(size)
	f.close()
	return [OK, d]


func _save(ctx: LocationBuildContext, name: String, w: int, h: int, fmt: int, data: PackedByteArray) -> bool:
	var img := Image.create_from_data(w, h, false, fmt, data)
	if img == null or img.save_png(ctx.dir.path_join(name)) != OK:
		ctx.log_line("surface: не записать %s" % name)
		return false
	return true
