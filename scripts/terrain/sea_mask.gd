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

	# вода и компоненты (union-find, 8-связность; корень — наименьший индекс клетки)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	for y in h:
		var row := y * w
		var cur := -1
		for x in w:
			var i := row + x
			var c := classes[i]
			if not (c == SURFACE_CLASS_WATER or (c == 0 and heights[i] <= NEAR0_M)):
				cur = -1
				continue
			if cur < 0:
				cur = i
			parent[i] = cur
			if y > 0:
				# предыдущая строка уже сведена к корням: parent[u] — корень компоненты соседа
				var u := i - w
				var r := parent[u]
				if r >= 0 and r != cur:
					cur = _merge(parent, cur, r)
				if x > 0:
					r = parent[u - 1]
					if r >= 0 and r != cur:
						cur = _merge(parent, cur, r)
				if x < w - 1:
					r = parent[u + 1]
					if r >= 0 and r != cur:
						cur = _merge(parent, cur, r)
				parent[i] = cur
		if y < h - 1:
			for x in w:
				var i := row + x
				if parent[i] >= 0:
					parent[i] = _find(parent, i)
	# корни, размеры, касание края
	var root := PackedInt32Array()
	root.resize(n)
	var cnt := PackedInt32Array()
	cnt.resize(n)
	var edge := PackedByteArray()
	edge.resize(n)
	for i in n:
		if parent[i] < 0:
			root[i] = -1
			continue
		var r := _find(parent, i)
		root[i] = r
		cnt[r] += 1
		var x := i % w
		var y := i / w
		if x == 0 or y == 0 or x == w - 1 or y == h - 1:
			edge[r] = 1
	# кандидаты: достаточно большие и касающиеся края; медиана и верхний процентиль
	var slot := {}  # корень → индекс кандидата
	var cand_roots := PackedInt32Array()
	for r in n:
		if cnt[r] >= min_cells and edge[r] == 1 and cnt[r] > 0:
			slot[r] = cand_roots.size()
			cand_roots.append(r)
	if cand_roots.is_empty():
		return res
	var lists: Array[PackedFloat32Array] = []
	lists.resize(cand_roots.size())
	for k in cand_roots.size():
		var a := PackedFloat32Array()
		a.resize(cnt[cand_roots[k]])
		lists[k] = a
	var fill := PackedInt32Array()
	fill.resize(cand_roots.size())
	for i in n:
		var r := root[i]
		if r >= 0 and slot.has(r):
			var k: int = slot[r]
			lists[k][fill[k]] = heights[i]
			fill[k] += 1
	var is_sea := PackedByteArray()
	is_sea.resize(n)
	var comps := 0
	for k in cand_roots.size():
		var a := lists[k]
		a.sort()
		if _quantile(a, 0.5) <= med_max and _quantile(a, UPPER_Q) >= q99_min:
			is_sea[cand_roots[k]] = 1
			comps += 1
	if comps == 0:
		return res
	var sea_cells := 0
	for i in n:
		var r := root[i]
		if r >= 0 and is_sea[r] == 1:
			out[i] = 1
			sea_cells += 1
	res.sea_cells = sea_cells
	res.components = comps
	res.mask = _distance_values(out, w, h, cell_m)
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


## Точный EDT (Meijster/Felzenszwalb): по бинарной маске моря (1) — значения 1 + floor(d / STEP_M).
## Нет ни одной клетки не-моря — везде 255.
static func _distance_values(sea: PackedByteArray, w: int, h: int, cell_m: float) -> PackedByteArray:
	var n := w * h
	var out := PackedByteArray()
	out.resize(n)
	var g := PackedFloat64Array()  # квадрат вертикального расстояния до не-моря в столбце, клеток
	g.resize(n)
	var any_land := false
	for x in w:
		var d := BIG
		for y in h:  # сверху вниз
			var i := y * w + x
			if sea[i] == 0:
				d = 0.0
				any_land = true
			else:
				d += 1.0
			g[i] = d
		d = BIG
		for y in range(h - 1, -1, -1):  # снизу вверх
			var i := y * w + x
			if sea[i] == 0:
				d = 0.0
			else:
				d += 1.0
			if d < g[i]:
				g[i] = d
	if not any_land:
		out.fill(255)
		return out
	var v := PackedInt32Array()
	v.resize(w)
	var z := PackedFloat64Array()
	z.resize(w + 1)
	var f := PackedFloat64Array()
	f.resize(w)
	var scale := cell_m / STEP_M
	for y in h:
		var row := y * w
		for x in w:
			var gv := g[row + x]
			f[x] = gv * gv if gv < BIG * 0.5 else BIG
		var k := 0
		v[0] = 0
		z[0] = -BIG
		z[1] = BIG
		for q in range(1, w):
			var fq := f[q] + float(q * q)
			var s := 0.0
			while true:
				var vk := v[k]
				s = (fq - (f[vk] + float(vk * vk))) / float(2 * q - 2 * vk)
				if s <= z[k]:
					k -= 1
					if k < 0:
						break
				else:
					break
			if k < 0:
				k = 0
				v[0] = q
				z[0] = -BIG
				z[1] = BIG
			else:
				k += 1
				v[k] = q
				z[k] = s
				z[k + 1] = BIG
		k = 0
		for q in w:
			while z[k + 1] < float(q):
				k += 1
			if sea[row + q] == 0:
				continue
			var dx := float(q - v[k])
			var d2 := dx * dx + f[v[k]]
			var dist := sqrt(d2) * scale  # в шагах STEP_M
			out[row + q] = 255 if dist >= 254.0 else 1 + int(floor(dist))
	return out
