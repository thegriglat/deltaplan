class_name SeaMask
extends RefCounted
## Маска моря на сетке far (контракт S2, docs/contracts/sea-ships.md; признак — исследование SEA-1,
## tools/research/sea_mask/README.md, эталон sea_mask.py/sealib.py).
## Вода far: класс 6, либо класс 0 (нет покрова WorldCover — открытый океан) при h ≤ NEAR0_M.
## Компоненты воды 8-связные (края квадрата берегом не считаются). Компонента — море, если в ней
## ≥ min_cells клеток, медиана h ≤ median_max_m, она касается края квадрата и 99-й процентиль h ≥ q99_min_m.
## Результат: 0 — не море, иначе min(255, 1 + floor(d / 100 м)), d — евклидово расстояние между центрами
## клеток до ближайшей клетки не-моря внутри квадрата (края квадрата берегом не считаются).

const FILE := "far_sea.webp"
const SURFACE_CLASS_WATER := 6
## Класс 0 (нет покрова) считается водой, если высота не выше, м (константа признака SEA-1).
const NEAR0_M := 0.5
const UPPER_Q := 0.99
const DEFAULT_PARAMS := {"min_cells": 100, "median_max_m": 0.25, "q99_min_m": -1.0}
const BIG := 1.0e12
## Шаг значения маски, м.
const STEP_M := 100.0


## Параметры признака из configs/sea_ships.json → mask (нет конфига — значения по умолчанию).
static func params_from_config() -> Dictionary:
	var out := DEFAULT_PARAMS.duplicate()
	var cfg: Variant = Config.get_config("sea_ships").get("mask", {})
	if cfg is Dictionary:
		for k: String in DEFAULT_PARAMS:
			if (cfg as Dictionary).has(k):
				out[k] = cfg[k]
	return out


## Чистая функция: w·h байт, строки с севера на юг (как у слоя). Одинаковый вход — побайтно одинаковый выход.
static func compute(heights: PackedFloat32Array, classes: PackedByteArray, w: int, h: int, cell_m: float,
		params: Dictionary) -> PackedByteArray:
	return compute_info(heights, classes, w, h, cell_m, params).mask


## То же, что compute, и счётчики для sea.json: {"mask": PackedByteArray, "sea_cells": int, "components": int}.
static func compute_info(heights: PackedFloat32Array, classes: PackedByteArray, w: int, h: int, cell_m: float,
		params: Dictionary) -> Dictionary:
	var n := w * h
	var out := PackedByteArray()
	out.resize(n)
	var res := {"mask": out, "sea_cells": 0, "components": 0}
	if n == 0 or heights.size() != n or classes.size() != n:
		return res
	var p := DEFAULT_PARAMS.duplicate()
	p.merge(params, true)
	var min_cells := int(p.min_cells)
	var med_max := float(p.median_max_m)
	var q99_min := float(p.q99_min_m)

	var tm := Time.get_ticks_usec()
	var ms := {}
	# Серии воды по строкам (компоненты — по сериям, как label_runs эталона): s — начало, e — конец (не включая)
	var rs := PackedInt32Array()
	var re := PackedInt32Array()
	var rp := PackedInt32Array()  # родитель серии (union-find по сериям)
	var first := PackedInt32Array()  # индекс первой серии строки; first[h] — всего серий
	first.resize(h + 1)
	for y in h:
		first[y] = rs.size()
		var row := y * w
		var x := 0
		while x < w:
			var c := classes[row + x]
			if not (c == SURFACE_CLASS_WATER or (c == 0 and heights[row + x] <= NEAR0_M)):
				x += 1
				continue
			var s0 := x
			x += 1
			while x < w:
				c = classes[row + x]
				if not (c == SURFACE_CLASS_WATER or (c == 0 and heights[row + x] <= NEAR0_M)):
					break
				x += 1
			var id := rs.size()
			rs.append(s0)
			re.append(x)
			rp.append(id)
			if y > 0:
				# 8-связность: серии предыдущей строки, пересекающие [s0 - 1, x]
				var j := first[y - 1]
				var jend := first[y]
				while j < jend and re[j] < s0:
					j += 1
				while j < jend and rs[j] <= x:
					_merge(rp, id, j)
					j += 1
	first[h] = rs.size()
	var nr := rs.size()
	ms["runs"] = (Time.get_ticks_usec() - tm) / 1000
	tm = Time.get_ticks_usec()
	# размеры компонент и касание края
	var cnt := PackedInt32Array()
	cnt.resize(nr)
	var edge := PackedByteArray()
	edge.resize(nr)
	var rroot := PackedInt32Array()
	rroot.resize(nr)
	for y in h:
		for id in range(first[y], first[y + 1]):
			var r := _find(rp, id)
			rroot[id] = r
			cnt[r] += re[id] - rs[id]
			if y == 0 or y == h - 1 or rs[id] == 0 or re[id] == w:
				edge[r] = 1
	# кандидаты: достаточно большие и касающиеся края; медиана и верхний процентиль
	var slot := {}  # корень → индекс кандидата
	var lists: Array[PackedFloat32Array] = []
	var cand_roots := PackedInt32Array()
	for r in nr:
		if rroot[r] == r and cnt[r] >= min_cells and edge[r] == 1:
			slot[r] = cand_roots.size()
			cand_roots.append(r)
			lists.append(PackedFloat32Array())
	if cand_roots.is_empty():
		res["ms"] = ms
		return res
	for y in h:
		for id in range(first[y], first[y + 1]):
			var k: Variant = slot.get(rroot[id])
			if k != null:
				lists[k].append_array(heights.slice(y * w + rs[id], y * w + re[id]))
	var sea_slot := PackedByteArray()
	sea_slot.resize(cand_roots.size())
	var comps := 0
	for k in cand_roots.size():
		var a := lists[k]
		a.sort()
		if _quantile(a, 0.5) <= med_max and _quantile(a, UPPER_Q) >= q99_min:
			sea_slot[k] = 1
			comps += 1
	ms["stats"] = (Time.get_ticks_usec() - tm) / 1000
	tm = Time.get_ticks_usec()
	if comps == 0:
		res["ms"] = ms
		return res
	var sea_cells := 0
	for y in h:
		for id in range(first[y], first[y + 1]):
			var k: Variant = slot.get(rroot[id])
			if k != null and sea_slot[k] == 1:
				var base := y * w
				for x in range(rs[id], re[id]):
					out[base + x] = 255
				sea_cells += re[id] - rs[id]
	res.sea_cells = sea_cells
	res.components = comps
	ms["mark"] = (Time.get_ticks_usec() - tm) / 1000
	tm = Time.get_ticks_usec()
	_distance_values(out, w, h, cell_m)
	res.mask = out
	ms["edt"] = (Time.get_ticks_usec() - tm) / 1000
	res["ms"] = ms
	return res


## Маска места из папки: far_sea.webp, либо (нет файла, но есть far и far_surface) — счёт compute.
## {"image": Image L8, "origin": Vector2 (x, z узла (0,0), м места), "cell_m": float} или {}.
static func load_for(dir: String) -> Dictionary:
	if not FileAccess.file_exists(dir.path_join("meta.json")):
		return {}
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	if not (meta is Dictionary):
		return {}
	var info := {}
	for l: Dictionary in (meta as Dictionary).get("layers", []):
		if String(l.get("id", "")) == "far":
			info = l
	if info.is_empty():
		return {}
	var w := int(info.width)
	var h := int(info.height)
	var cell_m := float(info.spacing_m)
	var origin := Vector2(float(info.origin_x_m), float(info.origin_z_m))
	var data := PackedByteArray()
	var path := dir.path_join(FILE)
	if FileAccess.file_exists(path):
		data = read_l8(path, w, h)
	else:
		var hl := HeightLayer.load_from_file(dir.path_join(String(info.get("file", "far.webp"))), info)
		var cls := read_l8(dir.path_join("far_surface.webp"), w, h)
		if hl == null or cls.is_empty():
			return {}
		data = compute(hl.heights, cls, w, h, cell_m, params_from_config())
	if data.is_empty():
		return {}
	return {"image": Image.create_from_data(w, h, false, Image.FORMAT_L8, data), "origin": origin, "cell_m": cell_m}


## Серый растр (R = G = B) из WebP как байты L8 (канал R); пусто — нет файла или размер не тот.
static func read_l8(path: String, w: int, h: int) -> PackedByteArray:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		return PackedByteArray()
	if img.get_width() != w or img.get_height() != h:
		return PackedByteArray()
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_RGB8)
		var src := img.get_data()
		var out := PackedByteArray()
		out.resize(w * h)
		for i in w * h:
			out[i] = src[i * 3]
		return out
	return img.get_data()


## Серый растр L8 -> WebP lossless (RGB8, R = G = B), как у остальных растров места.
static func write_l8(path: String, w: int, h: int, data: PackedByteArray) -> bool:
	var img := Image.create_from_data(w, h, false, Image.FORMAT_L8, data)
	if img == null:
		return false
	img.convert(Image.FORMAT_RGB8)
	return img.save_webp(path, false) == OK


# ---------------------------------------------------------------------------------------------

static func _find(parent: PackedInt32Array, a: int) -> int:
	while parent[a] != a:
		parent[a] = parent[parent[a]]
		a = parent[a]
	return a


## Объединить компоненты с корнями (или клетками) a и b; возвращает общий корень — меньший индекс.
static func _merge(parent: PackedInt32Array, a: int, b: int) -> int:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra == rb:
		return ra
	if ra < rb:
		parent[rb] = ra
		return ra
	parent[ra] = rb
	return rb


## Квантиль q отсортированного массива, линейная интерполяция (как numpy.percentile по умолчанию).
static func _quantile(sorted: PackedFloat32Array, q: float) -> float:
	var pos := q * float(sorted.size() - 1)
	var lo := int(floor(pos))
	var hi := mini(lo + 1, sorted.size() - 1)
	return float(sorted[lo]) + (pos - float(lo)) * (float(sorted[hi]) - float(sorted[lo]))


## Точный EDT (Meijster/Felzenszwalb) с отсечкой: на входе sea — 0 (не море) и 255 (море); на месте море получает
## 1 + floor(d / STEP_M) там, где d < 254 шагов, иначе остаётся 255 (потолок значения). Нет ни одной клетки
## не-моря — везде 255. Вертикальные расстояния g обрезаны сверху (клетки с g ≥ cap не участвуют в огибающей парабол
## строки: от них расстояние ≥ потолка), поэтому дальше 254 шагов от берега строка не просматривается.
static func _distance_values(sea: PackedByteArray, w: int, h: int, cell_m: float) -> void:
	var scale := cell_m / STEP_M  # шагов маски в клетке
	var cap := int(ceil(254.0 / scale)) + 1  # клеток: g ≥ cap — дальше потолка
	# строки, где в пределах cap строк есть не-море: остальные целиком ≥ потолка (g = cap, не просматриваются)
	var near := PackedByteArray()
	near.resize(h)
	var land_row := PackedByteArray()
	land_row.resize(h)
	var pos := sea.find(0, 0)
	while pos >= 0:
		var ly := pos / w
		land_row[ly] = 1
		pos = sea.find(0, (ly + 1) * w)
	var last_land := -1000000
	for y in h:
		if land_row[y] == 1:
			last_land = y
		if y - last_land <= cap:
			near[y] = 1
	last_land = 1000000
	for y in range(h - 1, -1, -1):
		if land_row[y] == 1:
			last_land = y
		if last_land - y <= cap:
			near[y] = 1
	var g := PackedInt32Array()
	g.resize(w * h)
	g.fill(cap)
	for y in h:
		if near[y] == 0:
			continue
		var row := y * w
		if y == 0:
			for x in w:
				if sea[x] == 0:
					g[x] = 0
			continue
		for x in w:
			var i := row + x
			if sea[i] == 0:
				g[i] = 0
			else:
				g[i] = mini(cap, g[i - w] + 1)
	for y in range(h - 2, -1, -1):
		if near[y] == 0:
			continue
		var row := y * w
		for x in w:
			var i := row + x
			var below := g[i + w] + 1
			if below < g[i]:
				g[i] = below
	var v := PackedInt32Array()
	var z := PackedFloat64Array()
	var fq := PackedFloat64Array()
	var act := PackedInt32Array()
	for y in h:
		if near[y] == 0:
			continue
		var row := y * w
		act.clear()
		for x in w:
			if g[row + x] < cap:
				act.append(x)
		var na := act.size()
		if na == 0:
			continue
		# нижняя огибающая парабол f(x) = (x − q)² + g[q]² только по активным столбцам
		v.resize(na)
		z.resize(na + 1)
		fq.resize(na)
		var k := 0
		v[0] = act[0]
		fq[0] = float(g[row + act[0]]) * float(g[row + act[0]])
		z[0] = -BIG
		z[1] = BIG
		for j in range(1, na):
			var q := act[j]
			var gq := float(g[row + q])
			var f := gq * gq
			var s := 0.0
			while true:
				var vk := v[k]
				s = ((f + float(q * q)) - (fq[k] + float(vk * vk))) / float(2 * q - 2 * vk)
				if s <= z[k]:
					k -= 1
					if k < 0:
						break
				else:
					break
			if k < 0:
				k = 0
				v[0] = q
				fq[0] = f
				z[0] = -BIG
				z[1] = BIG
			else:
				k += 1
				v[k] = q
				fq[k] = f
				z[k] = s
				z[k + 1] = BIG
		var lo := maxi(0, act[0] - cap)
		var hi := mini(w - 1, act[na - 1] + cap)
		k = 0
		for q in range(lo, hi + 1):
			while z[k + 1] < float(q):
				k += 1
			if sea[row + q] == 0:
				continue
			var dx := float(q - v[k])
			var dist := sqrt(dx * dx + fq[k]) * scale  # в шагах STEP_M
			if dist < 254.0:
				sea[row + q] = 1 + int(floor(dist))
