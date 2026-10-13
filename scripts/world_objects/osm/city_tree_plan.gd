class_name CityTreePlan
extends RefCounted
## Расстановка деревьев города и сёл (configs/world_objects.json → city_trees), без нод и GPU:
##  - улицы: ряд деревьев по обе стороны дорог классов street.classes внутри города (маска — как у OsmCityGround:
##    доля площади под домами по клеткам, сглаженная), на отступе ширина/2 + offset_m, шаг ~spacing_m с пропусками;
##    не на дома, не на другие дороги и реки (перекрёстки), не в тоннелях и на мостах;
##  - дворы: в городе по клеткам yard.cell_m редкие группы 1–3 дерева, где нет домов и дорог;
##  - кроны: в лесных (WorldCover) клетках города на местах крон рельефа (клетка crown.cell_m, центр со сдвигом, как
##    canopy_nearest в terrain.gdshader) — по дереву-модели; рельеф там крон на земле не рисует (маска city_mask());
##    не на дома и дороги (рельеф в городе кроны гасит целиком, где модели нет — просто земля);
##  - сады: у малых жилых домов (частный сектор, сёла; в т. ч. процедурные дома посёлков) 1–4 дерева рядом.
## Всё детерминировано: хеш (RockScatter.hash01) от целых координат и индекса дороги/дома, не от порядка вызовов.
## Дерево принадлежит тайлу tile_m по своему положению (улицы, дворы) или по центру дома (сады).
## Деревья визуальные: препятствиями не регистрируются (как одиночные деревья ShrubScatter).
## Тайл: {xf: 12 float на дерево, col: 4, size: высота м, var: индекс (порода * variants + вариант)}.

const CELL := 48.0
## Типы O3 (BuildingStyle.TYPE_NAMES), у которых бывает сад.
const GARDEN_TYPES: PackedStringArray = ["yes", "house", "detached", "farm", "hut", "cabin", "terrace"]

var cfg: Dictionary = {}
var height_fn: Callable
## (x, z) -> доля леса 0..1 (Terrain.forest_at); не задан — деревьев на местах крон нет
var forest_fn: Callable
var prepared := false
var species: PackedStringArray = []
var sp_weight := PackedFloat32Array()
var variants := 4
## высота модели (м) по индексу (порода * variants + вариант); задаёт CityTrees после загрузки моделей
var model_height := PackedFloat32Array()
var stats: Dictionary = {}

var _tile := 192.0
var _dm := 1.0
# отрезки линий (дороги и реки)
var _sax := PackedFloat32Array()
var _saz := PackedFloat32Array()
var _sbx := PackedFloat32Array()
var _sbz := PackedFloat32Array()
var _sroad := PackedInt32Array()
var _ss0 := PackedFloat32Array()
var _sw := PackedFloat32Array()
var _sstreet := PackedByteArray()
var _sgrid := {}
# дома
var _hx := PackedFloat32Array()
var _hz := PackedFloat32Array()
var _hhw := PackedFloat32Array()
var _hhl := PackedFloat32Array()
var _hca := PackedFloat32Array()
var _hsa := PackedFloat32Array()
var _hgrid := {}
var _garden := {}
# маска города
var _cov := PackedFloat32Array()
var _cnx := 0
var _cnz := 0
var _cx0 := 0.0
var _cz0 := 0.0
var _ccell := 200.0
var _cov_min := 0.12
var _roads_src: Array = []
var _rivers_src: Array = []
var _osm_houses: Array = []
var _mask_src: Array = []
var _extra_houses: Array = []
var _roads_cfg: Dictionary = {}
var _cg_cfg: Dictionary = {}
var _style_cell := 200.0


## c — блок city_trees; roads_cfg — roads.classes (ширины); cg — city_ground (порог маски);
## osm_houses — OsmData.buildings (маска города + дома), extra_houses — процедурные дома посёлков (только сады).
func setup(
	c: Dictionary, roads: Array, rivers: Array, osm_houses: Array, extra_houses: Array,
	roads_cfg: Dictionary, cg: Dictionary, style_cell: float, hfn: Callable,
	ffn: Callable = Callable()
) -> void:
	forest_fn = ffn
	cfg = c
	_roads_src = roads
	_rivers_src = rivers
	_osm_houses = osm_houses
	_mask_src = osm_houses
	_extra_houses = extra_houses
	_roads_cfg = roads_cfg
	_cg_cfg = cg
	_style_cell = style_cell
	height_fn = hfn
	_tile = float(c.get("tile_m", 192.0))
	_dm = float(c.get("density_mult", 1.0))
	variants = maxi(int(c.get("variants", 4)), 1)
	var sp: Dictionary = c.get("species", {})
	for k: String in sp.keys():
		if k.begins_with("_"):
			continue
		species.append(k)
		sp_weight.append(float((sp[k] as Dictionary).get("weight", 1.0)))
	model_height.resize(maxi(species.size() * variants, 1))
	model_height.fill(10.0)


## Тяжёлая часть, один раз (рабочий поток): отрезки, дома, сетки, маска города.
func prepare() -> void:
	if prepared:
		return
	var t0 := Time.get_ticks_usec()
	_prepare_lines()
	_prepare_houses()
	_prepare_mask()
	stats["segments"] = _sroad.size()
	stats["houses"] = _hx.size()
	stats["prepare_s"] = (Time.get_ticks_usec() - t0) / 1.0e6
	prepared = true


func _prepare_lines() -> void:
	var sc: Dictionary = cfg.get("street", {})
	var classes: Array = sc.get("classes", [])
	var cls: Dictionary = _roads_cfg.get("classes", {})
	var river_w := float(cfg.get("river_avoid_w_m", 8.0))
	var all: Array = []
	for r: Dictionary in _roads_src:
		if bool(r.get("tunnel", false)):
			continue
		var t := String(r.get("t", ""))
		var w := float(r.get("w", 0.0))
		if w <= 0.0:
			w = float((cls.get(t, [4.0]) as Array)[0])
		all.append([r.p, w, t in classes and not bool(r.get("bridge", false))])
	for r: Dictionary in _rivers_src:
		all.append([r.p, river_w, false])
	for ri in all.size():
		var item: Array = all[ri]
		var pts: PackedVector2Array = item[0]
		var s := 0.0
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var len := a.distance_to(b)
			if len < 0.01:
				continue
			var id := _sroad.size()
			_sax.append(a.x)
			_saz.append(a.y)
			_sbx.append(b.x)
			_sbz.append(b.y)
			_sroad.append(ri)
			_ss0.append(s)
			_sw.append(item[1])
			_sstreet.append(1 if item[2] else 0)
			s += len
			var n := int(len / 16.0) + 2
			var last := Vector2i(1 << 30, 1 << 30)
			for q in n:
				var p := a.lerp(b, float(q) / (n - 1))
				var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
				if key == last:
					continue
				last = key
				if not _sgrid.has(key):
					_sgrid[key] = []
				_sgrid[key].append(id)
	_roads_src = []
	_rivers_src = []


func _prepare_houses() -> void:
	var tc := {}
	for pass_i in 2:
		var src: Array = _osm_houses if pass_i == 0 else _extra_houses
		var procedural := pass_i == 1
		for b: Array in src:
			var w: float = b[2]
			var l: float = b[3]
			var ang := deg_to_rad(float(b[4]))
			var ca := cos(ang)
			var sa := sin(ang)
			var id := _hx.size()
			var hw := w * 0.5
			var hl := l * 0.5
			_hx.append(b[0])
			_hz.append(b[1])
			_hhw.append(hw)
			_hhl.append(hl)
			_hca.append(ca)
			_hsa.append(sa)
			var ex := absf(ca) * hw + absf(sa) * hl
			var ez := absf(sa) * hw + absf(ca) * hl
			var x: float = b[0]
			var z: float = b[1]
			for cx in range(floori((x - ex) / CELL), floori((x + ex) / CELL) + 1):
				for cz in range(floori((z - ez) / CELL), floori((z + ez) / CELL) + 1):
					var key := Vector2i(cx, cz)
					if not _hgrid.has(key):
						_hgrid[key] = []
					_hgrid[key].append(id)
			if _is_garden_house(b, procedural):
				var tk := Vector2i(floori(x / _tile), floori(z / _tile))
				if not _garden.has(tk):
					_garden[tk] = []
				_garden[tk].append(id)
				tc[0] = int(tc.get(0, 0)) + 1
	stats["garden_houses"] = int(tc.get(0, 0))
	_osm_houses = []
	_extra_houses = []


func _is_garden_house(b: Array, procedural: bool) -> bool:
	if procedural or b.size() < 8:
		return true
	var gc: Dictionary = cfg.get("garden", {})
	var a := float(b[2]) * float(b[3])
	if a < float(gc.get("min_area_m2", 24.0)) or a > float(gc.get("max_area_m2", 260.0)):
		return false
	if float(b[5]) > float(gc.get("max_wall_m", 7.5)):
		return false
	var code := int(b[7])
	if code < 0 or code >= BuildingStyle.TYPE_NAMES.size():
		return false
	var nm := BuildingStyle.TYPE_NAMES[code]
	if nm == "yes":
		return a <= float(gc.get("yes_max_area_m2", 160.0))
	return nm in GARDEN_TYPES


func _prepare_mask() -> void:
	# маска — по домам OSM (процедурные посёлки — не город)
	_cov_min = float(_cg_cfg.get("coverage_min", 0.12))
	var cell := _style_cell
	_ccell = cell
	if _mask_src.size() < int(cfg.get("city", {}).get("min_houses", 50)):
		return
	var grid := OsmCityGround._coverage(_mask_src, cell)
	if grid.is_empty():
		return
	var f: PackedFloat32Array = grid.cov
	var iters := maxi(1, roundi(float(_cg_cfg.get("fade_m", 250.0)) / cell))
	for i in iters:
		f = OsmCityGround._blur(f, grid.nx, grid.nz)
	_cov = f
	_cnx = grid.nx
	_cnz = grid.nz
	_cx0 = grid.x0
	_cz0 = grid.z0
	_mask_src = []


## Сила городской застройки в точке 0..1 (0 — не город).
func city_at(x: float, z: float) -> float:
	if _cov.is_empty():
		return 0.0
	var d := OsmCityGround._sample(_cov, _cnx, _cnz, (x - _cx0) / _ccell, (z - _cz0) / _ccell)
	return smoothstep(_cov_min * 0.6, _cov_min * 1.4, d)


## В точке дом (с запасом margin, м)?
func near_house(x: float, z: float, margin: float) -> bool:
	var ids = _hgrid.get(Vector2i(floori(x / CELL), floori(z / CELL)))
	if ids == null:
		return false
	for id: int in ids:
		var dx := x - _hx[id]
		var dz := z - _hz[id]
		var lx := dx * _hca[id] + dz * _hsa[id]
		var lz := -dx * _hsa[id] + dz * _hca[id]
		if absf(lx) < _hhw[id] + margin and absf(lz) < _hhl[id] + margin:
			return true
	return false


## В точке дорога или река (полуширина + margin, м)?
func near_road(x: float, z: float, margin: float) -> bool:
	var cx := floori(x / CELL)
	var cz := floori(z / CELL)
	var p := Vector2(x, z)
	for i in range(cx - 1, cx + 2):
		for j in range(cz - 1, cz + 2):
			var ids = _sgrid.get(Vector2i(i, j))
			if ids == null:
				continue
			for id: int in ids:
				var a := Vector2(_sax[id], _saz[id])
				var ab := Vector2(_sbx[id], _sbz[id]) - a
				var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				var lim := _sw[id] * 0.5 + margin
				if p.distance_squared_to(a + ab * t) < lim * lim:
					return true
	return false


func _free(x: float, z: float, house_margin: float, road_margin: float) -> bool:
	return not near_house(x, z, house_margin) and not near_road(x, z, road_margin)


## Деревья тайла (tx, tz). Нужен prepare().
func build_tile(tx: int, tz: int) -> Dictionary:
	var out := {
		"xf": PackedFloat32Array(),
		"col": PackedFloat32Array(),
		"size": PackedFloat32Array(),
		"var": PackedInt32Array(),
		"street": 0,
		"yard": 0,
		"garden": 0,
		"crown": 0
	}
	if species.is_empty():
		return out
	if bool(cfg.get("street", {}).get("enabled", true)):
		_street_tile(tx, tz, out)
	if bool(cfg.get("yard", {}).get("enabled", true)):
		_yard_tile(tx, tz, out)
	if bool(cfg.get("garden", {}).get("enabled", true)):
		_garden_tile(tx, tz, out)
	if forest_fn.is_valid() and bool(cfg.get("crown", {}).get("enabled", true)):
		_crown_tile(tx, tz, out)
	return out


func _street_tile(tx: int, tz: int, out: Dictionary) -> void:
	var sc: Dictionary = cfg.street
	var x0 := tx * _tile
	var z0 := tz * _tile
	var spacing := float(sc.get("spacing_m", 9.5))
	var jit := float(sc.get("jitter_m", 5.0))
	var gap := 1.0 - (1.0 - float(sc.get("gap_chance", 0.25))) * minf(_dm, 1.0)
	var off: Array = sc.get("offset_m", [2.0, 4.0])
	var hr: Array = sc.get("height_m", [8.0, 14.0])
	var margin := float(off[1]) + 8.0
	var seen := {}
	for cx in range(floori((x0 - margin) / CELL), floori((x0 + _tile + margin) / CELL) + 1):
		for cz in range(floori((z0 - margin) / CELL), floori((z0 + _tile + margin) / CELL) + 1):
			var ids = _sgrid.get(Vector2i(cx, cz))
			if ids == null:
				continue
			for id: int in ids:
				if seen.has(id) or _sstreet[id] == 0:
					continue
				seen[id] = true
				_street_segment(id, x0, z0, spacing, jit, gap, off, hr, out)


func _street_segment(
	id: int, x0: float, z0: float, spacing: float, jit: float, gap: float, off: Array,
	hr: Array, out: Dictionary
) -> void:
	var a := Vector2(_sax[id], _saz[id])
	var ab := Vector2(_sbx[id], _sbz[id]) - a
	var len := ab.length()
	var dir := ab / len
	var nrm := Vector2(-dir.y, dir.x)
	var ri := _sroad[id]
	var s0 := _ss0[id]
	var k0 := ceili((s0 - jit * 0.5) / spacing)
	var k1 := floori((s0 + len + jit * 0.5) / spacing)
	for k in range(k0, k1 + 1):
		var s := k * spacing + (RockScatter.hash01(ri, k, 11) - 0.5) * jit
		if s < s0 or s >= s0 + len:
			continue
		var on := a + dir * (s - s0)
		for side in 2:
			var salt := k * 2 + side
			if RockScatter.hash01(ri, salt, 12) < gap:
				continue
			var d := lerpf(float(off[0]), float(off[1]), RockScatter.hash01(ri, salt, 13))
			var p := on + nrm * ((_sw[id] * 0.5 + d) * (1.0 if side == 0 else -1.0))
			if p.x < x0 or p.x >= x0 + _tile or p.y < z0 or p.y >= z0 + _tile:
				continue
			if RockScatter.hash01(ri, salt, 14) >= city_at(p.x, p.y):
				continue
			if not _free(p.x, p.y, 1.5, 1.5):
				continue
			_emit(out, p.x, p.y, ri, salt, 20, hr, "street")


func _yard_tile(tx: int, tz: int, out: Dictionary) -> void:
	var yc: Dictionary = cfg.yard
	var cell := float(yc.get("cell_m", 30.0))
	var chance := float(yc.get("chance", 0.12)) * _dm
	var cnt: Array = yc.get("count", [1, 3])
	var spread := float(yc.get("spread_m", 5.0))
	var hr: Array = yc.get("height_m", [6.0, 12.0])
	var n := maxi(int(round(_tile / cell)), 1)
	cell = _tile / n
	for j in n:
		for i in n:
			var ix := tx * n + i
			var iz := tz * n + j
			if RockScatter.hash01(ix, iz, 31) >= chance:
				continue
			var cx := (ix + 0.15 + 0.7 * RockScatter.hash01(ix, iz, 32)) * cell
			var cz := (iz + 0.15 + 0.7 * RockScatter.hash01(ix, iz, 33)) * cell
			if RockScatter.hash01(ix, iz, 34) >= city_at(cx, cz):
				continue
			var m := int(float(cnt[0]) + (float(cnt[1]) - float(cnt[0]) + 0.999) * RockScatter.hash01(ix, iz, 35))
			for r in m:
				var a := RockScatter.hash01(ix, iz, 40 + r * 4) * TAU
				var dd := spread * sqrt(RockScatter.hash01(ix, iz, 41 + r * 4)) if r > 0 else 0.0
				var px := cx + cos(a) * dd
				var pz := cz + sin(a) * dd
				if not _free(px, pz, 2.5, 3.0):
					continue
				_emit(out, px, pz, ix, iz, 60 + r * 8, hr, "yard")


func _garden_tile(tx: int, tz: int, out: Dictionary) -> void:
	var ids = _garden.get(Vector2i(tx, tz))
	if ids == null:
		return
	var gc: Dictionary = cfg.garden
	var chance := float(gc.get("chance", 0.85)) * minf(_dm, 1.0)
	var cnt: Array = gc.get("count", [1, 4])
	var ring: Array = gc.get("ring_m", [2.5, 8.0])
	var hr: Array = gc.get("height_m", [4.0, 7.0])
	for id: int in ids:
		var ix := int(_hx[id])
		var iz := int(_hz[id])
		if RockScatter.hash01(ix, iz, 71) >= chance:
			continue
		var u := RockScatter.hash01(ix, iz, 72)
		var m := int(float(cnt[0]) + (float(cnt[1]) - float(cnt[0]) + 0.999) * u * u)
		var rad := Vector2(_hhw[id], _hhl[id]).length()
		for r in m:
			var a := RockScatter.hash01(ix, iz, 80 + r * 4) * TAU
			var dd := rad + lerpf(float(ring[0]), float(ring[1]), RockScatter.hash01(ix, iz, 81 + r * 4))
			var px := _hx[id] + cos(a) * dd
			var pz := _hz[id] + sin(a) * dd
			if not _free(px, pz, 1.5, 2.0):
				continue
			_emit(out, px, pz, ix, iz, 100 + r * 8, hr, "garden")


## Деревья на местах крон: клетка c, центр (c + 0,5 + (h − 0,5)·0,7)·cell, как в terrain.gdshader (canopy_nearest);
## хеш целочисленный (RockScatter.hash01) — расстановка не зависит от порядка и float-шума GPU. Клетка целиком
## внутри тайла (центр не выходит за её пределы), поэтому тайл владеет своими клетками.
func _crown_tile(tx: int, tz: int, out: Dictionary) -> void:
	var cc: Dictionary = cfg.crown
	var cell := float(cc.get("cell_m", 6.0))
	var hr: Array = cc.get("height_m", [7.0, 12.0])
	var keep := float(cc.get("keep", 1.0))
	var n := int(round(_tile / cell))
	for j in n:
		for i in n:
			var cx := tx * n + i
			var cz := tz * n + j
			var px := (cx + 0.5 + (RockScatter.hash01(cx, cz, 301) - 0.5) * 0.7) * cell
			var pz := (cz + 0.5 + (RockScatter.hash01(cx, cz, 302) - 0.5) * 0.7) * cell
			if city_at(px, pz) < 0.5:
				continue
			if RockScatter.hash01(cx, cz, 303) >= keep:
				continue
			if float(forest_fn.call(px, pz)) < 0.5:
				continue
			if not _free(px, pz, 2.0, 1.5):
				continue
			_emit(out, px, pz, cx, cz, 310, hr, "crown")


## Маска города для рельефа (гашение крон на земле): {image: L8 (node = city_at·255), origin: центр пикселя (0, 0),
## cell: шаг, м}. Нужен prepare(); пусто — это не город.
func city_mask() -> Dictionary:
	if _cov.is_empty():
		return {}
	var data := PackedByteArray()
	data.resize(_cnx * _cnz)
	for j in _cnz:
		for i in _cnx:
			var v := city_at(_cx0 + (i + 0.5) * _ccell, _cz0 + (j + 0.5) * _ccell)
			data[j * _cnx + i] = int(round(v * 255.0))
	return {
		"image": Image.create_from_data(_cnx, _cnz, false, Image.FORMAT_L8, data),
		"origin": Vector2(_cx0 + 0.5 * _ccell, _cz0 + 0.5 * _ccell),
		"cell": _ccell
	}


func _emit(out: Dictionary, px: float, pz: float, ia: int, ib: int, salt: int, hr: Array, kind: String) -> void:
	var sp := 0
	if species.size() > 1:
		var tot := 0.0
		for w in sp_weight:
			tot += w
		var u := RockScatter.hash01(ia, ib, salt) * tot
		for i in species.size():
			u -= sp_weight[i]
			if u <= 0.0:
				sp = i
				break
	var v := mini(int(RockScatter.hash01(ia, ib, salt + 1) * variants), variants - 1)
	var vi := sp * variants + v
	var h := lerpf(float(hr[0]), float(hr[1]), RockScatter.hash01(ia, ib, salt + 2))
	var sc := h / maxf(model_height[vi], 0.1)
	var b := Basis(Vector3.UP, RockScatter.hash01(ia, ib, salt + 3) * TAU).scaled(Vector3.ONE * sc)
	var y := float(height_fn.call(px, pz)) - 0.2
	var tv := float(cfg.get("tint_var", 0.12))
	var br := 1.0 + tv * (2.0 * RockScatter.hash01(ia, ib, salt + 4) - 1.0)
	out.xf.append_array(
		PackedFloat32Array(
			[b.x.x, b.y.x, b.z.x, px, b.x.y, b.y.y, b.z.y, y, b.x.z, b.y.z, b.z.z, pz]
		)
	)
	out.col.append_array(PackedFloat32Array([br, br, br * 0.97, 1.0]))
	out.size.append(h)
	out["var"].append(vi)
	out[kind] = int(out[kind]) + 1
