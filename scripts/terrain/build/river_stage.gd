class_name RiverStage
extends RefCounted
## Стадия рек по рельефу (OA-К3): порт tools/terrain/rivers.py — priority-flood по слою-источнику,
## водосбор, ширина ~ k·√площадь, привязка русла к дну долины в детальном слое, растеризация.
## compute() — чистое ядро без контекста; run() считает его вне главного потока и пишет <id>_water.webp.

const _DR: Array[int] = [-1, 1, 0, 0, -1, -1, 1, 1]
const _DC: Array[int] = [0, 0, -1, 1, -1, 1, -1, 1]


static func compute(heights: Dictionary, layers: Dictionary, cfg: Dictionary) -> Dictionary:
	var out := {}
	if layers.is_empty():
		return out
	var ids: Array = layers.keys()
	var src_id: String = String(cfg.get("source_layer", ids[ids.size() - 1]))
	if not layers.has(src_id):
		src_id = String(ids[ids.size() - 1])
	var fine_id: String = "detail" if layers.has("detail") else String(ids[0])
	var segs := river_segments(heights[src_id], layers[src_id], cfg, heights.get(fine_id), layers[fine_id])
	# маски слоёв независимы — растеризуем параллельно
	var masks := {}
	var tasks: Array = []
	for id in ids:
		var sid: String = String(id)
		var t := WorkerThreadPool.add_task(func() -> void:
			var m := rasterize(segs, layers[sid])
			masks[sid] = m)
		tasks.append(t)
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	for id in ids:
		var info: Dictionary = layers[id]
		out[String(id)] = Image.create_from_data(int(info.width), int(info.height), false, Image.FORMAT_L8, masks[String(id)])
	return out


## Priority-flood (Barnes 2014) с эпсилон-заполнением впадин. Возвращает {parent: PackedInt32Array
## (−1 — сток за край), order: PackedInt32Array (от стоков вверх по течению)}. Порядок как в rivers.py:
## ключ кучи (высота, индекс).
static func flow_tree(h: PackedFloat32Array, cols: int, rows: int) -> Dictionary:
	var n := cols * rows
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var visited := PackedByteArray()
	visited.resize(n)
	var order := PackedInt32Array()
	order.resize(n)
	var hk := PackedFloat64Array()
	hk.resize(n)
	var hi := PackedInt32Array()
	hi.resize(n)
	var size := 0
	# граничные клетки: вставка в кучу обычным push (результат тот же, что у heapify: порядок полный)
	var border := PackedInt32Array()
	for r in rows:
		for c in [0, cols - 1]:
			border.append(r * cols + c)
	for c in cols:
		for r in [0, rows - 1]:
			border.append(r * cols + c)
	for i in border:
		if visited[i] == 0:
			visited[i] = 1
			var key: float = h[i]
			var pos := size
			size += 1
			while pos > 0:
				var par := (pos - 1) >> 1
				var pk := hk[par]
				if pk < key or (pk == key and hi[par] < i):
					break
				hk[pos] = pk
				hi[pos] = hi[par]
				pos = par
			hk[pos] = key
			hi[pos] = i
	var k := 0
	var dr := _DR
	var dc := _DC
	while size > 0:
		var e := hk[0]
		var i := hi[0]
		# pop: последний элемент просеиваем вниз от корня
		size -= 1
		if size > 0:
			var lk := hk[size]
			var li := hi[size]
			var pos := 0
			while true:
				var ch := 2 * pos + 1
				if ch >= size:
					break
				var ck := hk[ch]
				var ci := hi[ch]
				var rch := ch + 1
				if rch < size:
					var rk := hk[rch]
					if rk < ck or (rk == ck and hi[rch] < ci):
						ch = rch
						ck = rk
						ci = hi[rch]
				if lk < ck or (lk == ck and li < ci):
					break
				hk[pos] = ck
				hi[pos] = ci
				pos = ch
			hk[pos] = lk
			hi[pos] = li
		order[k] = i
		k += 1
		var r := i / cols
		var c := i - r * cols
		for d in 8:
			var rr := r + dr[d]
			var cc := c + dc[d]
			if rr < 0 or rr >= rows or cc < 0 or cc >= cols:
				continue
			var j := rr * cols + cc
			if visited[j] != 0:
				continue
			visited[j] = 1
			parent[j] = i
			var hj: float = h[j]
			var key2 := hj if hj > e else e + 1e-3
			var p2 := size
			size += 1
			while p2 > 0:
				var par2 := (p2 - 1) >> 1
				var pk2 := hk[par2]
				if pk2 < key2 or (pk2 == key2 and hi[par2] < j):
					break
				hk[p2] = pk2
				hi[p2] = hi[par2]
				p2 = par2
			hk[p2] = key2
			hi[p2] = j
	order.resize(k)
	return {"parent": parent, "order": order}


static func accumulate(parent: PackedInt32Array, order: PackedInt32Array, cell_area: float) -> PackedFloat64Array:
	var acc := PackedFloat64Array()
	acc.resize(parent.size())
	acc.fill(cell_area)
	for q in range(order.size() - 1, -1, -1):
		var i := order[q]
		var p := parent[i]
		if p >= 0:
			acc[p] += acc[i]
	return acc


## Сдвинуть точку в самую низкую клетку детального слоя в радиусе (если точка внутри слоя).
## Возвращает Vector2(x, z). Первая из равных (построчно) — как np.argmin.
static func snap_to_valley(x: float, z: float, fine_h: PackedFloat32Array, fine: Dictionary, radius_m: float) -> Vector2:
	var s: float = fine.spacing_m
	var fw := int(fine.width)
	var fh := int(fine.height)
	var i := (x - float(fine.origin_x_m)) / s
	var j := (z - float(fine.origin_z_m)) / s
	if i < 0.0 or j < 0.0 or i > fw - 1 or j > fh - 1:
		return Vector2(x, z)
	var rad := int(ceil(radius_m / s))
	var i0 := maxi(0, int(i) - rad)
	var i1 := mini(fw - 1, int(i) + rad)
	var j0 := maxi(0, int(j) - rad)
	var j1 := mini(fh - 1, int(j) + rad)
	var best := INF
	var bi := i0
	var bj := j0
	for jj in range(j0, j1 + 1):
		var base := jj * fw
		for ii in range(i0, i1 + 1):
			var v := fine_h[base + ii]
			if v < best:
				best = v
				bi = ii
				bj = jj
	return Vector2(float(fine.origin_x_m) + bi * s, float(fine.origin_z_m) + bj * s)


## Отрезки русел, плоский массив по 5 чисел: x0, z0, x1, z1, ширина_м.
static func river_segments(h: PackedFloat32Array, info: Dictionary, cfg: Dictionary,
		fine_h = null, fine: Dictionary = {}) -> PackedFloat64Array:
	var step: float = info.spacing_m
	var cols := int(info.width)
	var rows := int(info.height)
	var ft := flow_tree(h, cols, rows)
	var parent: PackedInt32Array = ft.parent
	var acc := accumulate(parent, ft.order, (step / 1000.0) * (step / 1000.0))
	var min_area := float(cfg.min_area_km2)
	var snap_r := float(cfg.snap_radius_m)
	var wk := float(cfg.width_k)
	var wmin := float(cfg.min_width_m)
	var wmax := float(cfg.max_width_m)
	var ox: float = info.origin_x_m
	var oz: float = info.origin_z_m
	var pos := {}
	var segs := PackedFloat64Array()
	for i in acc.size():
		if acc[i] < min_area:
			continue
		var p := parent[i]
		if p < 0:
			continue
		var w := clampf(wk * sqrt(acc[i]), wmin, wmax)
		var a: Vector2
		if pos.has(i):
			a = pos[i]
		else:
			var r := i / cols
			a = Vector2(ox + (i - r * cols) * step, oz + r * step)
			if fine_h != null:
				a = snap_to_valley(a.x, a.y, fine_h, fine, snap_r)
			pos[i] = a
		var b: Vector2
		if pos.has(p):
			b = pos[p]
		else:
			var r2 := p / cols
			b = Vector2(ox + (p - r2 * cols) * step, oz + r2 * step)
			if fine_h != null:
				b = snap_to_valley(b.x, b.y, fine_h, fine, snap_r)
			pos[p] = b
		segs.append_array(PackedFloat64Array([a.x, a.y, b.x, b.y, w]))
	return segs


## Маска воды 0..255 на сетке слоя (сглаженный край ~1 клетка). Возвращает L8-байты width×height.
static func rasterize(segs: PackedFloat64Array, info: Dictionary) -> PackedByteArray:
	var s: float = info.spacing_m
	var w := int(info.width)
	var hgt := int(info.height)
	var mask := PackedFloat32Array()
	mask.resize(w * hgt)
	var ox: float = info.origin_x_m
	var oz: float = info.origin_z_m
	for q in range(0, segs.size(), 5):
		var x0 := segs[q]
		var z0 := segs[q + 1]
		var x1 := segs[q + 2]
		var z1 := segs[q + 3]
		var width := segs[q + 4]
		var r := width / 2.0
		var i0 := maxi(int(floor((minf(x0, x1) - r - s - ox) / s)), 0)
		var i1 := mini(int(ceil((maxf(x0, x1) + r + s - ox) / s)), w - 1)
		var j0 := maxi(int(floor((minf(z0, z1) - r - s - oz) / s)), 0)
		var j1 := mini(int(ceil((maxf(z0, z1) + r + s - oz) / s)), hgt - 1)
		if i0 > i1 or j0 > j1:
			continue
		var dx := x1 - x0
		var dz := z1 - z0
		var l2 := dx * dx + dz * dz
		var kw := minf(1.0, width / s)
		for j in range(j0, j1 + 1):
			var zz := oz + j * s
			var base := j * w
			for i in range(i0, i1 + 1):
				var xx := ox + i * s
				var t := 0.0
				if l2 > 0.0:
					t = clampf(((xx - x0) * dx + (zz - z0) * dz) / l2, 0.0, 1.0)
				var ex := xx - (x0 + t * dx)
				var ez := zz - (z0 + t * dz)
				var cov := clampf((r - sqrt(ex * ex + ez * ez)) / s + 0.5, 0.0, 1.0) * kw
				if cov > mask[base + i]:
					mask[base + i] = cov
	var bytes := PackedByteArray()
	bytes.resize(w * hgt)
	for n in mask.size():
		var m := mask[n]
		if m > 0.0:
			bytes[n] = int(m * 255.0)
	return bytes


## Стадия: читает ctx.heights/ctx.layers/ctx.spec.rivers, пишет <id>_water.webp в ctx.dir.
func run(ctx: LocationBuildContext) -> Error:
	var cfg: Dictionary = ctx.spec.get("rivers", {})
	if cfg.is_empty():
		return OK  # места без рек — масок нет
	if ctx.heights.is_empty() or ctx.layers.is_empty():
		ctx.log_line("RiverStage: нет высот (нужна стадия рельефа)")
		return ERR_UNCONFIGURED
	if ctx.cancelled:
		return ERR_SKIP
	ctx.report("rivers", 0.0)
	var box := {}
	var heights := ctx.heights
	var layers := ctx.layers
	var task := WorkerThreadPool.add_task(func() -> void:
		box["images"] = compute(heights, layers, cfg))
	var tree: SceneTree = ctx.host.get_tree() if ctx.host != null and ctx.host.is_inside_tree() else null
	if tree != null:
		while not WorkerThreadPool.is_task_completed(task):
			await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if ctx.cancelled:
		return ERR_SKIP
	var images: Dictionary = box.get("images", {})
	for id in images:
		var img: Image = images[id]
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
		var err := img.save_webp("%s/%s_water.webp" % [ctx.dir, id], false)
		if err != OK:
			ctx.log_line("RiverStage: не записан %s_water.webp (%d)" % [id, err])
			return err
		ctx.layers[id]["water_file"] = "%s_water.webp" % id
	ctx.report("rivers", 1.0)
	return OK
