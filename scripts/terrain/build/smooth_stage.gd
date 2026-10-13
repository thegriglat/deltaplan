class_name SmoothStage
extends RefCounted
## Стадия сглаживания высот места (MLK-К1, docs/contracts/mountain-look.md): сглаживание DSM — только
## под кронами и крышами. h = r + w·(G_σ(r) − r): r — сырая выборка Copernicus (DemStage пишет её в
## <слой>_raw.webp), G_σ — гаусс σ = smooth_sigma_cells, w ∈ [0, 1] — вес «кроны/крыши» в узле:
## максимум по классам smooth_mask_classes (лес — канал L маски detail10, застройка — built10; без этих
## файлов — класс карты поверхности в узле), размытый гауссом smooth_mask_sigma_m (не меньше 2 клеток).
## Идёт после SurfaceStage (нужны покров и маска 10 м) и до OsmTilesStage; перезаписывает <слой>.webp,
## вклеивает новые высоты в более грубые слои (_patch_from_finer), обновляет meta.json, удаляет _raw.
## Нет покрова (офлайн, стадия surface отказала) — ERR_UNAVAILABLE: слой остаётся как собрал DemStage
## (w = 1 везде, поведение как до модуля), _raw остаётся — следующая сборка дособерёт стадию.

const DEFAULT_CLASSES := [1, 7]
const DEFAULT_MASK_SIGMA_M := 50.0
## Минимум σ маски, клеток слоя.
const MIN_MASK_SIGMA_CELLS := 2.0
## Шаг квантования маски (значения 0..1 после размытия).
const MASK_Q := 1024.0

var _dem: DemStage


func _init() -> void:
	_dem = DemStage.new()
	_dem._tree = Engine.get_main_loop() as SceneTree


func run(ctx: LocationBuildContext) -> Error:
	if ctx.layers.is_empty():
		ctx.log_line("smooth: нет слоёв сетки (ctx.layers)")
		return ERR_INVALID_PARAMETER
	var cfgs := {}
	for lc: Dictionary in ctx.spec.get("dem", {}).get("layers", []):
		cfgs[String(lc.id)] = lc
	var scfg: Dictionary = ctx.spec.get("surface", {}).get("layers", {})
	var sjson: Dictionary = {}
	var sp := ctx.dir.path_join("surface.json")
	if FileAccess.file_exists(sp):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(sp))
		if parsed is Dictionary:
			sjson = parsed
	var order: Array = ctx.layers.keys()
	var dirty := {}
	var unavailable := false
	var done := 0
	for idx in order.size():
		var id: String = order[idx]
		var info: Dictionary = ctx.layers[id]
		var raw_path := ctx.dir.path_join(String(info.get("raw_file", "")))
		if String(info.get("raw_file", "")) == "" or not FileAccess.file_exists(raw_path):
			continue
		var lc: Dictionary = cfgs.get(id, {})
		var sigma := float(lc.get("smooth_sigma_cells", info.get("smooth_sigma_cells", 0.0)))
		var n := int(info.width)
		var q := float(lc.get("quantize_per_m", 32))
		if not scfg.has(id):
			# покров для слоя не задуман: w = 1 (сглаживание везде), как собрал DemStage
			_drop_raw(ctx, info)
			dirty[id] = true
			continue
		var cov := _load_cover(ctx, sjson, id)
		if cov.is_empty():
			ctx.log_line("smooth: нет покрова слоя %s — сглаживание везде (w = 1)" % id)
			unavailable = true
			continue
		var rinfo := info.duplicate()
		rinfo["height_min_m"] = float(info.raw_height_min_m)
		var rl := HeightLayer.load_from_file(raw_path, rinfo)
		if rl == null:
			ctx.log_line("smooth: не прочитан %s" % raw_path)
			unavailable = true
			continue
		var classes: Array = lc.get("smooth_mask_classes", info.get("smooth_mask_classes", DEFAULT_CLASSES))
		var msig := float(lc.get("smooth_mask_sigma_m", info.get("smooth_mask_sigma_m", DEFAULT_MASK_SIGMA_M)))
		var w := await weight(n, float(info.spacing_m), float(info.origin_x_m), float(info.origin_z_m), classes,
				cov.surf, cov.forest, cov.built, msig)
		if ctx.cancelled:
			return ERR_SKIP
		var h := await apply(rl.heights, w, n, sigma, q)
		ctx.heights[id] = h
		_set_range(info, h)
		_drop_raw(ctx, info)
		dirty[id] = true
		# более грубые слои берут высоты из этого
		for k in range(idx + 1, order.size()):
			var cid: String = order[k]
			var ch: PackedFloat32Array = ctx.heights[cid]
			_dem._patch_from_finer(ch, ctx.layers[cid], h, info)
			_set_range(ctx.layers[cid], ch)
			dirty[cid] = true
		done += 1
		ctx.report("smooth", float(done) / order.size())
	for id: String in dirty:
		var info: Dictionary = ctx.layers[id]
		var err := _dem._write_layer(ctx.dir.path_join(String(info.file)), ctx.heights[id], info)
		if err != OK:
			ctx.log_line("smooth: не записан %s" % info.file)
			return err
	if not dirty.is_empty() and not _write_meta(ctx):
		return ERR_CANT_CREATE
	ctx.report("smooth", 1.0)
	return ERR_UNAVAILABLE if unavailable else OK


## Вес «кроны/крыши» w в узлах сетки n×n шага spacing (м): максимум по классам, размытый гауссом.
## surf — карта поверхности слоя (класс игры на узел, n·n байт); forest, built — маски 10 м
## {data: байты одного канала, n, spacing, ox, oz} либо {} (тогда берётся класс карты поверхности).
func weight(n: int, spacing: float, ox: float, oz: float, classes: Array, surf: PackedByteArray,
		forest: Dictionary, built: Dictionary, mask_sigma_m: float) -> PackedFloat32Array:
	var rows: Array = []
	rows.resize(n)
	var cs := {"n": n, "spacing": spacing, "ox": ox, "oz": oz, "classes": classes, "surf": surf,
			"forest": forest, "built": built}
	await _dem._group(_mask_row.bind(cs, rows), n)
	var m := DemStage._concat64(rows)
	var sig := maxf(mask_sigma_m / spacing, MIN_MASK_SIGMA_CELLS)
	var blurred := await _dem._finish(m, n, sig, MASK_Q)
	for k in blurred.size():
		blurred[k] = clampf(blurred[k], 0.0, 1.0)
	return blurred


## h = r + w·(G_σ(r) − r), квантование 1/q м.
func apply(r: PackedFloat32Array, w: PackedFloat32Array, n: int, sigma: float, q: float) -> PackedFloat32Array:
	var r64 := PackedFloat64Array()
	r64.resize(r.size())
	for k in r.size():
		r64[k] = r[k]
	var g := await _dem._finish(r64, n, sigma, q)
	var out := PackedFloat32Array()
	out.resize(r.size())
	for k in r.size():
		var wk := w[k] if not w.is_empty() else 1.0
		out[k] = roundf((r[k] + wk * (g[k] - r[k])) * q) / q
	return out


## Строка j: сырой вес по классам в узлах (рабочий поток).
func _mask_row(j: int, cs: Dictionary, out: Array) -> void:
	var n := int(cs.n)
	var step := float(cs.spacing)
	var z := float(cs.oz) + j * step
	var classes: Array = cs.classes
	var surf: PackedByteArray = cs.surf
	var row := PackedFloat64Array()
	row.resize(n)
	var forest: Dictionary = cs.forest
	var built: Dictionary = cs.built
	var use_forest := classes.has(1) and not forest.is_empty()
	var use_built := classes.has(7) and not built.is_empty()
	var rest: Array = []
	for cv in classes:
		var c := int(cv)
		if not ((c == 1 and use_forest) or (c == 7 and use_built)):
			rest.append(c)
	for i in n:
		var x := float(cs.ox) + i * step
		var v := 0.0
		if use_forest:
			v = _bilinear(forest, x, z)
		if use_built:
			v = maxf(v, _bilinear(built, x, z))
		if not rest.is_empty() and rest.has(int(surf[j * n + i])):
			v = 1.0
		row[i] = v
	out[j] = row


## Билинейная выборка одноканальной маски 10 м (0..255 → 0..1) в точке (x, z) м.
static func _bilinear(m: Dictionary, x: float, z: float) -> float:
	var mw := int(m.n)
	var s := float(m.spacing)
	var fx := clampf((x - float(m.ox)) / s, 0.0, mw - 1.000001)
	var fz := clampf((z - float(m.oz)) / s, 0.0, mw - 1.000001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - x0
	var tz := fz - z0
	var d: PackedByteArray = m.data
	var b := z0 * mw + x0
	return ((d[b] * (1.0 - tx) + d[b + 1] * tx) * (1.0 - tz) + (d[b + mw] * (1.0 - tx) + d[b + mw + 1] * tx) * tz) / 255.0


## Покров слоя из файлов, собранных SurfaceStage: {surf, forest, built} или {} (карты поверхности нет).
func _load_cover(ctx: LocationBuildContext, sjson: Dictionary, id: String) -> Dictionary:
	var entry: Dictionary = {}
	for e: Dictionary in sjson.get("layers", []):
		if String(e.get("id", "")) == id:
			entry = e
	if entry.is_empty():
		return {}
	var n := int(entry.width)
	var simg := Image.load_from_file(ctx.dir.path_join(String(entry.file)))
	if simg == null or simg.get_width() != n or simg.get_height() != int(entry.height):
		return {}
	if simg.get_format() != Image.FORMAT_L8:
		simg.convert(Image.FORMAT_L8)
	var out := {"surf": simg.get_data(), "forest": {}, "built": {}}
	var d10: Dictionary = entry.get("detail10", {})
	if not d10.is_empty():
		var img := Image.load_from_file(ctx.dir.path_join(String(d10.file)))
		if img != null and img.get_width() == int(d10.width):
			img.convert(Image.FORMAT_LA8)
			var raw := img.get_data()
			var l := PackedByteArray()
			l.resize(raw.size() / 2)
			for k in l.size():
				l[k] = raw[k * 2]
			out.forest = {"data": l, "n": int(d10.width), "spacing": float(d10.spacing_m),
					"ox": float(d10.origin_x_m), "oz": float(d10.origin_z_m)}
	var b10: Dictionary = entry.get("built10", {})
	if not b10.is_empty() and d10.has("width"):
		var bimg := Image.load_from_file(ctx.dir.path_join(String(b10.file)))
		if bimg != null and bimg.get_width() == int(d10.width):
			bimg.convert(Image.FORMAT_L8)
			out.built = {"data": bimg.get_data(), "n": int(d10.width), "spacing": float(d10.spacing_m),
					"ox": float(d10.origin_x_m), "oz": float(d10.origin_z_m)}
	return out


static func _set_range(info: Dictionary, h: PackedFloat32Array) -> void:
	var mm := DemStage._min_max(h)
	info["min_height_m"] = mm.x
	info["max_height_m"] = mm.y
	info["height_min_m"] = mm.x


static func _drop_raw(ctx: LocationBuildContext, info: Dictionary) -> void:
	DirAccess.remove_absolute(ctx.dir.path_join(String(info.get("raw_file", ""))))
	info.erase("raw_file")
	info.erase("raw_height_min_m")


## meta.json: записи слоёв из ctx.layers (мин/макс высот, без _raw).
func _write_meta(ctx: LocationBuildContext) -> bool:
	var path := ctx.dir.path_join("meta.json")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not meta is Dictionary:
		return false
	var layers: Array = meta.get("layers", [])
	for k in layers.size():
		var id := String(layers[k].id)
		if ctx.layers.has(id):
			layers[k] = ctx.layers[id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(meta, "  ") + "\n")
	f.close()
	return true
