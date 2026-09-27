class_name ShrubScatter
extends Node3D
## Кустарник и одиночные деревья на лугах: MultiMesh по тайлам вокруг камеры
## (configs/vegetation.json → shrubs). Кусты (assets/models/shrubs/shrubs.glb,
## tools/blender/build_shrubs.py) — густо куртинами на классе «кустарник» Terrain.surface_at,
## реже на лугу у опушек (полоса edge_band_m от кромки леса Terrain.forest_at) и в ложбинах
## (вогнутость рельефа), изредка — поодиночке. Деревья (модели пород assets/models/trees, LOD2 —
## импостер-крест) — поодиночке и группами по 2–5 на лугах и полянах, чаще у кромки леса.
## Не ставятся в лес, воду, на поля, застройку, скалы, просеки (Terrain.set_clearings), у площадок
## и в коридоре разбега старта. Расстановка детерминирована хешем клетки, тайлы кешируются.
## Подключение: ShrubScatter.attach(terrain, camera) — нода "Shrubs" ребёнком Terrain.

const SHADER := preload("res://scripts/terrain/shrub_scatter.gdshader")
const TREE_SHADER := preload("res://scripts/terrain/tree_model.gdshader")
const LODS := 3
## кусты — только на лугу и в кустарнике
const OPEN: Array[int] = [SurfaceLayer.GRASS, SurfaceLayer.SHRUB]
## категории кустов: кустарник, опушка, ложбина, открытый луг
const CATS: PackedStringArray = ["shrubland", "edge", "hollow", "meadow"]

var camera: Camera3D
var terrain: Terrain
var material: ShaderMaterial
## материалы деревьев (tree_model.gdshader) — ветер им даёт TerrainWind
var tree_materials: Array[ShaderMaterial] = []

var _cfg: Dictionary = {}
var _tcfg: Dictionary = {}
var _n_var := 0
var _species: PackedStringArray = []
var _sp_weight := PackedFloat32Array()
var _sp_h := PackedVector2Array()
var _sp_model_h := PackedFloat32Array()
## _mmis[вариант * LODS + lod], дальше — деревья [n_var * LODS + порода * LODS + lod]
var _mmis: Array[MultiMeshInstance3D] = []
## Vector2i тайла → {xf: PackedFloat32Array (12), col (4), size, var: PackedInt32Array}
var _tiles: Dictionary = {}
var _ttiles: Dictionary = {}
## площадки: [Vector2 позиция, Vector2 направление разбега (ZERO у посадок), радиус, м]
var _sites: Array = []
var _clear: Array = []
var _key := ""
var _task := -1
var _buffers: Array = []
var _last_center := Vector2(INF, INF)
var _pending_center := Vector2.ZERO
var _ready_ok := false
var _first_done := false


## Поставить (или найти) кусты и одиночные деревья под terrain. camera — null: камера вьюпорта.
static func attach(t: Terrain, cam: Camera3D = null) -> ShrubScatter:
	var r := t.get_node_or_null("Shrubs") as ShrubScatter
	if r == null:
		r = ShrubScatter.new()
		r.name = "Shrubs"
		r.terrain = t
		t.add_child(r)
	if cam != null:
		r.camera = cam
	return r


func _ready() -> void:
	if terrain == null:
		terrain = get_parent() as Terrain
	setup(Config.get_config("vegetation").get("shrubs", {}))


## Загрузить модели и материалы. false — выключено или нет модели кустов.
func setup(cfg: Dictionary) -> bool:
	_cfg = cfg
	_tcfg = cfg.get("trees", {})
	if not bool(cfg.get("enabled", false)):
		return false
	var names: Array = cfg.get("variants", [])
	_n_var = names.size()
	var meshes := RockScatter.load_meshes(String(cfg.get("model_path", "")), names)
	if meshes.is_empty() or _n_var == 0:
		push_warning("ShrubScatter: нет модели кустов %s" % cfg.get("model_path", ""))
		return false
	material = _make_material()
	var shadows := bool(cfg.get("cast_shadows", true))
	for v in _n_var:
		for lod in LODS:
			_add_mmi("%s_LOD%d" % [names[v], lod], meshes[v * LODS + lod], shadows and lod == 0)
	for m in _mmis:
		m.material_override = material
	if bool(_tcfg.get("enabled", false)):
		_setup_trees()
	_ready_ok = true
	return true


func _add_mmi(nm: String, mesh: Mesh, shadow: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if shadow
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(mmi)
	_mmis.append(mmi)


func _setup_trees() -> void:
	var sp: Dictionary = _tcfg.get("species", {})
	var shadows := bool(_tcfg.get("cast_shadows", true))
	for k: String in sp.keys():
		var s: Dictionary = sp[k]
		var lods := TerrainTreeModels._load_lods(String(s.get("model", "")))
		if lods.is_empty():
			push_warning("ShrubScatter: нет модели дерева %s" % k)
			continue
		var mh := lods[0].get_aabb().end.y
		var cache := {}
		for lod in LODS:
			_add_mmi("%s_LOD%d" % [k, lod], _tree_mesh(lods[lod], mh, cache), shadows and lod < 2)
		_species.append(k)
		_sp_weight.append(float(s.get("weight", 1.0)))
		var hr: Array = s.get("height_m", [10.0, 18.0])
		_sp_h.append(Vector2(float(hr[0]), float(hr[1])))
		_sp_model_h.append(mh)


## Копия меша дерева с материалами tree_model.gdshader (как у TerrainTreeModels: качание).
func _tree_mesh(src: Mesh, height: float, cache: Dictionary) -> Mesh:
	var mesh := src.duplicate() as Mesh
	for s in mesh.get_surface_count():
		var std := mesh.surface_get_material(s) as BaseMaterial3D
		if std == null:
			continue
		if not cache.has(std.resource_name):
			var m := ShaderMaterial.new()
			m.shader = TREE_SHADER
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
			m.set_shader_parameter("albedo_color", std.albedo_color)
			m.set_shader_parameter(
				"alpha_clip", std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			)
			m.set_shader_parameter("alpha_threshold", std.alpha_scissor_threshold)
			m.set_shader_parameter("roughness_value", std.roughness)
			m.set_shader_parameter("model_height", height)
			m.set_shader_parameter("sway_top_m", float(_tcfg.get("sway_top_m", 0.5)))
			m.set_shader_parameter("sway_hz", float(_tcfg.get("sway_hz", 0.25)))
			cache[std.resource_name] = m
			tree_materials.append(m)
		mesh.surface_set_material(s, cache[std.resource_name])
	return mesh


func _make_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	return m


## Всего кустов и деревьев в MultiMesh'ах сейчас: [кусты, деревья].
func instance_counts() -> Vector2i:
	var out := Vector2i.ZERO
	for b in _mmis.size():
		var n := _mmis[b].multimesh.instance_count
		if b < _n_var * LODS:
			out.x += n
		else:
			out.y += n
	return out


func _process(_delta: float) -> void:
	if not _ready_ok or terrain == null or terrain.layers.is_empty():
		return
	_link_wind()
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply()
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	var agl := p.y - terrain.height_at(p.x, p.z)
	var show := agl < float(_cfg.get("max_agl_m", 1200.0))
	if visible != show:
		visible = show
	if not show:
		return
	_check_key()
	var c := Vector2(p.x, p.z)
	if c.distance_to(_last_center) < float(_cfg.get("rebuild_step_m", 30.0)):
		return
	_pending_center = c
	if not _first_done:
		# первый раз — ближние тайлы (в потоке, без остановки кадра), полный радиус — следом
		_first_done = true
		_task = WorkerThreadPool.add_task(
			_build.bind(c, float(_cfg.get("first_radius_m", 250.0))), false, "shrubs"
		)
		return
	_last_center = c
	_task = WorkerThreadPool.add_task(_build.bind(c), false, "shrubs")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## TerrainWind пересобирает список материалов при смене локации — вернуть туда свои.
func _link_wind() -> void:
	var w := terrain.wind
	if w == null or w.materials.has(material):
		return
	var list: Array = [material]
	list.append_array(tree_materials)
	w.add_materials(list)


## Сменилась локация или просеки — сбросить кеш тайлов.
func _check_key() -> void:
	var cl: Array = terrain._clearings
	var k := (
		"%s|%d|%d"
		% [
			terrain.location_id,
			terrain.layers[0].get_instance_id(),
			(cl[0] as Image).get_instance_id() if cl.size() == 3 else 0
		]
	)
	if k == _key:
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_buffers = []
	_key = k
	_tiles.clear()
	_ttiles.clear()
	_clear = cl
	_sites.clear()
	for s in terrain.get_start_sites():
		var sp: Vector3 = s.position
		var hd := TerrainGeo.heading_vector(float(s.get("heading_deg", 0.0)))
		_sites.append(
			[
				Vector2(sp.x, sp.z),
				Vector2(hd.x, hd.z).normalized(),
				float(_cfg.get("keep_off_start_m", 15.0))
			]
		)
	for s in terrain.get_landing_sites():
		var sp: Vector3 = s.position
		_sites.append(
			[Vector2(sp.x, sp.z), Vector2.ZERO, float(_cfg.get("keep_off_landing_m", 60.0))]
		)
	_last_center = Vector2(INF, INF)
	_first_done = false


## Рабочий поток: достроить тайлы вокруг c, собрать буферы MultiMesh.
func _build(c: Vector2, limit: float = INF) -> void:
	var radius := minf(float(_cfg.get("radius_m", 650.0)), limit)
	var keys := _tile_keys(c, radius, float(_cfg.get("tile_m", 96.0)), _tiles)
	for k in keys:
		if not _tiles.has(k):
			_tiles[k] = build_tile(k.x, k.y)
	var tkeys: Array[Vector2i] = []
	var tr := minf(float(_tcfg.get("radius_m", 1600.0)), limit * 2.0)
	if not _species.is_empty():
		tkeys = _tile_keys(c, tr, float(_tcfg.get("tile_m", 192.0)), _ttiles)
		for k in tkeys:
			if not _ttiles.has(k):
				_ttiles[k] = build_tree_tile(k.x, k.y)
	var bufs: Array[PackedFloat32Array] = []
	bufs.resize(_mmis.size())
	_assemble(bufs, c, keys, _tiles, radius, _cfg, 0, true)
	if not tkeys.is_empty():
		_assemble(bufs, c, tkeys, _ttiles, tr, _tcfg, _n_var * LODS, false)
	_buffers = bufs


## Тайлы в радиусе (ближние первыми); дальние из кеша выбросить.
static func _tile_keys(
	c: Vector2, radius: float, tile: float, cache: Dictionary
) -> Array[Vector2i]:
	var t0 := Vector2i(floori((c.x - radius) / tile), floori((c.y - radius) / tile))
	var t1 := Vector2i(floori((c.x + radius) / tile), floori((c.y + radius) / tile))
	var keys: Array[Vector2i] = []
	for tz in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var tc := (Vector2(tx, tz) + Vector2(0.5, 0.5)) * tile
			if tc.distance_to(c) <= radius + tile * 0.75:
				keys.append(Vector2i(tx, tz))
	keys.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return (
				Vector2(a).distance_squared_to(c / tile) < Vector2(b).distance_squared_to(c / tile)
			)
	)
	for k in cache.keys():
		if ((Vector2(k) + Vector2(0.5, 0.5)) * tile).distance_to(c) > radius * 1.5:
			cache.erase(k)
	return keys


func _assemble(
	bufs: Array[PackedFloat32Array],
	c: Vector2,
	keys: Array[Vector2i],
	tiles: Dictionary,
	radius: float,
	cfg: Dictionary,
	base: int,
	by_size: bool
) -> void:
	var lod_m: Array = cfg.get("lod_m", [35.0, 110.0])
	var l0 := float(lod_m[0])
	var l1 := float(lod_m[1])
	var view_k := float(cfg.get("view_per_m", 1e9))
	var budget := int(cfg.get("max_instances", 30000))
	for k in keys:
		var t: Dictionary = tiles[k]
		var xf: PackedFloat32Array = t.xf
		var col: PackedFloat32Array = t.col
		var sz: PackedFloat32Array = t.size
		var vv: PackedInt32Array = t["var"]
		for i in vv.size():
			var d := Vector2(xf[i * 12 + 3], xf[i * 12 + 11]).distance_to(c)
			var s := sz[i] if by_size else 1.0
			if d > clampf(s * view_k, 80.0, radius):
				continue
			var ls := sqrt(clampf(s, 0.5, 3.0))
			var lod := 0 if d < l0 * ls else (1 if d < l1 * ls else 2)
			var b := base + vv[i] * LODS + lod
			bufs[b].append_array(xf.slice(i * 12, i * 12 + 12))
			bufs[b].append_array(col.slice(i * 4, i * 4 + 4))
			budget -= 1
			if budget <= 0:
				return


func _apply() -> void:
	if _buffers.is_empty():
		return
	var tl: HeightLayer = terrain.layers[terrain.layers.size() - 1]
	var r := maxf(float(_cfg.get("radius_m", 650.0)), float(_tcfg.get("radius_m", 0.0)))
	var aabb := AABB(
		Vector3(_pending_center.x - r, tl.min_h - 50.0, _pending_center.y - r),
		Vector3(2.0 * r, tl.max_h - tl.min_h + 100.0, 2.0 * r)
	)
	for b in _mmis.size():
		var buf: PackedFloat32Array = _buffers[b]
		var mm := _mmis[b].multimesh
		mm.instance_count = buf.size() / 16
		if buf.size() > 0:
			mm.buffer = buf
		_mmis[b].custom_aabb = aabb
	_buffers = []


# ---------------- расстановка (без сцены — для тестов) ----------------


static func _new_out() -> Dictionary:
	return {
		"xf": PackedFloat32Array(),
		"col": PackedFloat32Array(),
		"size": PackedFloat32Array(),
		"var": PackedInt32Array()
	}


## Кусты тайла (tx, tz) размера tile_m: {xf, col, size, var}. Детерминированно.
func build_tile(tx: int, tz: int) -> Dictionary:
	var out := _new_out()
	var tile := float(_cfg.get("tile_m", 96.0))
	var step := float(_cfg.get("sample_m", 8.0))
	var n := maxi(int(round(tile / step)), 1)
	step = tile / n
	for j in n:
		for i in n:
			_sample(tx * n + i, tz * n + j, step, out)
	return out


## Близость кромки леса 0..1 (1 — у самой кромки, 0 — дальше band): по 8 направлениям на 3 кольцах.
func edge_near(x: float, z: float, band: float) -> float:
	for s in 3:
		var d := band * (s + 1) / 3.0
		for k in 8:
			var dir: Vector2 = TreePlacer.RING8[k]
			if terrain.forest_at(x + dir.x * d, z + dir.y * d) > 0.5:
				return 1.0 - float(s) / 3.0
	return 0.0


func _sample(ix: int, iz: int, step: float, out: Dictionary) -> void:
	var x := (ix + 0.5) * step
	var z := (iz + 0.5) * step
	var cls := terrain.surface_at(x, z)
	if not cls in OPEN:
		return
	var area := step * step
	var e := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var ck := 0 if cls == SurfaceLayer.SHRUB else 3
	e[ck] = _dens(CATS[ck]) * area * clump_at(x, z, _cfg.get(CATS[ck], {}))
	if cls == SurfaceLayer.GRASS:
		var edge := edge_near(x, z, float(_cfg.get("edge_band_m", 45.0)))
		e[1] = _dens("edge") * area * edge
		var k := float(_cfg.get("hollow_scale_m", 30.0))
		var h := terrain.height_at(x, z)
		var conc := (
			(
				terrain.height_at(x + k, z)
				+ terrain.height_at(x - k, z)
				+ terrain.height_at(x, z + k)
				+ terrain.height_at(x, z - k)
				- 4.0 * h
			)
			/ (4.0 * k)
		)
		var hk := float(_cfg.get("hollow_concave_k", 0.03))
		e[2] = _dens("hollow") * area * smoothstep(0.2, 1.0, conc / hk)
	for ci in CATS.size():
		if e[ci] <= 0.0:
			continue
		var cnt := int(e[ci] + RockScatter.hash01(ix, iz, 200 + ci))
		for r in cnt:
			_place_shrub(ix, iz, step, ci, r, out)


## Куртины: 1 в гуще (доля площади cover), floor — между ними. Шум двух масштабов.
func clump_at(x: float, z: float, cat: Dictionary) -> float:
	var cover := float(cat.get("cover", 0.5))
	var p := Vector2(x, z) / float(_cfg.get("clump_m", 32.0))
	var nz := 0.6 * RockScatter.vnoise(p) + 0.4 * RockScatter.vnoise(p * 3.5 + Vector2(5.2, 1.7))
	# порог по доле площади: шум ~ нормальный, среднее 0,5, σ ≈ 0,165 (логит-приближение квантиля)
	var q := clampf(1.0 - cover, 0.01, 0.99)
	var th := 0.5 + 0.165 * log(q / (1.0 - q)) / 1.702
	var cl := smoothstep(th - 0.03, th + 0.03, nz)
	return lerpf(float(cat.get("floor", 0.1)), 1.0, cl)


func _dens(cat: String) -> float:
	return float((_cfg.get(cat, {}) as Dictionary).get("density", 0.0))


func _place_shrub(ix: int, iz: int, step: float, ci: int, r: int, out: Dictionary) -> void:
	var s0 := 3000 + ci * 64 + r * 8
	var px := (ix + RockScatter.hash01(ix, iz, s0)) * step
	var pz := (iz + RockScatter.hash01(ix, iz, s0 + 1)) * step
	var cat: Dictionary = _cfg.get(CATS[ci], {})
	var sr: Array = cat.get("size_m", [0.5, 1.5])
	var u := RockScatter.hash01(ix, iz, s0 + 2)
	var size := lerpf(float(sr[0]), float(sr[1]), pow(u, 1.5))
	if not is_free(px, pz, size * 0.6):
		return
	var v := _pick(cat.get("weights", []), RockScatter.hash01(ix, iz, s0 + 3), _n_var)
	var nn := terrain.normal_at(px, pz)
	var up := Vector3.UP.lerp(nn, 0.4).normalized()
	var yaw := RockScatter.hash01(ix, iz, s0 + 4) * TAU
	var j1 := RockScatter.hash01(ix, iz, s0 + 5)
	var b := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, yaw)
	var w := size * (0.85 + 0.4 * j1)
	b = b.scaled_local(Vector3(w, size, w * (1.1 - 0.2 * j1)))
	var slope := sqrt(maxf(1.0 - nn.y * nn.y, 0.0))
	var y := terrain.height_at(px, pz) - size * (float(_cfg.get("sink", 0.08)) + 0.4 * slope)
	_emit(out, b, Vector3(px, y, pz), size, v, _shrub_color(v, ix, iz, s0))


func _shrub_color(v: int, ix: int, iz: int, s0: int) -> Color:
	var cols: Array = _cfg.get("colors", [])
	var c: Array = cols[v] if v < cols.size() else [0.1, 0.14, 0.05]
	var tv := float(_cfg.get("tint_var", 0.15))
	var br := 1.0 + tv * (2.0 * RockScatter.hash01(ix, iz, s0 + 6) - 1.0)
	var yl := 0.1 * (2.0 * RockScatter.hash01(ix, iz, s0 + 7) - 1.0)
	return Color(
		float(c[0]) * br * (1.0 + yl), float(c[1]) * br, float(c[2]) * br * (1.0 - yl), 1.0
	)


static func _pick(weights: Array, u: float, n: int) -> int:
	var tot := 0.0
	for i in mini(weights.size(), n):
		tot += float(weights[i])
	if tot <= 0.0:
		return int(u * n) % n
	var acc := 0.0
	for i in mini(weights.size(), n):
		acc += float(weights[i]) / tot
		if u < acc:
			return i
	return mini(weights.size(), n) - 1


static func _emit(out: Dictionary, b: Basis, p: Vector3, size: float, v: int, col: Color) -> void:
	out.xf.append_array(
		PackedFloat32Array(
			[b.x.x, b.y.x, b.z.x, p.x, b.x.y, b.y.y, b.z.y, p.y, b.x.z, b.y.z, b.z.z, p.z]
		)
	)
	out.col.append_array(PackedFloat32Array([col.r, col.g, col.b, 1.0]))
	out.size.append(size)
	out["var"].append(v)


## Деревья тайла (tx, tz) размера trees.tile_m: группы по клеткам cell_m. Детерминированно.
func build_tree_tile(tx: int, tz: int) -> Dictionary:
	var out := _new_out()
	if _species.is_empty():
		return out
	var tile := float(_tcfg.get("tile_m", 192.0))
	var cell := float(_tcfg.get("cell_m", 48.0))
	var n := maxi(int(round(tile / cell)), 1)
	cell = tile / n
	for j in n:
		for i in n:
			_tree_cell(tx * n + i, tz * n + j, cell, out)
	return out


func _tree_cell(ix: int, iz: int, cell: float, out: Dictionary) -> void:
	var cx := (ix + 0.2 + 0.6 * RockScatter.hash01(ix, iz, 500)) * cell
	var cz := (iz + 0.2 + 0.6 * RockScatter.hash01(ix, iz, 501)) * cell
	if not terrain.surface_at(cx, cz) in OPEN:
		return
	var ch := float(_tcfg.get("group_chance", 0.02))
	var ech := float(_tcfg.get("edge_group_chance", 0.3))
	var edge := edge_near(cx, cz, float(_tcfg.get("edge_band_m", 90.0)))
	if RockScatter.hash01(ix, iz, 502) >= lerpf(ch, maxf(ech, ch), edge):
		return
	var gs: Array = _tcfg.get("group_size", [1, 5])
	var u := RockScatter.hash01(ix, iz, 503)
	var cnt := int(float(gs[0]) + (float(gs[1]) - float(gs[0]) + 0.999) * u * u)
	var sp0 := _pick(Array(_sp_weight), RockScatter.hash01(ix, iz, 504), _species.size())
	var gr := float(_tcfg.get("group_radius_m", 12.0))
	var crown := float(_tcfg.get("crown_m", 3.5))
	var keep := float(_tcfg.get("keep_off_forest", 0.3))
	for r in cnt:
		var s0 := 600 + r * 8
		var a := RockScatter.hash01(ix, iz, s0) * TAU
		var dd := gr * sqrt(RockScatter.hash01(ix, iz, s0 + 1)) if r > 0 else 0.0
		var px := cx + cos(a) * dd
		var pz := cz + sin(a) * dd
		if terrain.forest_at(px, pz) > keep or not terrain.surface_at(px, pz) in OPEN:
			continue
		if not is_free(px, pz, crown):
			continue
		var sp := sp0
		if RockScatter.hash01(ix, iz, s0 + 2) < 0.3:
			sp = _pick(Array(_sp_weight), RockScatter.hash01(ix, iz, s0 + 3), _species.size())
		var hr := _sp_h[sp]
		var h := lerpf(hr.x, hr.y, RockScatter.hash01(ix, iz, s0 + 4))
		var sc := h / maxf(_sp_model_h[sp], 0.1)
		var b := Basis(Vector3.UP, RockScatter.hash01(ix, iz, s0 + 5) * TAU).scaled(
			Vector3.ONE * sc
		)
		var y := terrain.height_at(px, pz) - 0.3
		var tv := float(_tcfg.get("tint_var", 0.12))
		var br := 1.0 + tv * (2.0 * RockScatter.hash01(ix, iz, s0 + 6) - 1.0)
		_emit(out, b, Vector3(px, y, pz), h, sp, Color(br, br, br * 0.97))


## Можно ли ставить радиуса rad в (x, z): не у площадки, не в коридоре разбега, не на просеке,
## на лугу или в кустарнике.
func is_free(x: float, z: float, rad: float) -> bool:
	var q := Vector2(x, z)
	var run: Array = _cfg.get("start_run_m", [55.0, 12.0])
	for s: Array in _sites:
		var d: Vector2 = q - s[0]
		var keep: float = s[2] + rad
		if d.length_squared() < keep * keep:
			return false
		var dir: Vector2 = s[1]
		if dir != Vector2.ZERO:
			var along := d.dot(dir)
			if (
				along > -5.0 - rad
				and along < float(run[0]) + rad
				and absf(d.cross(dir)) < float(run[1]) + rad
			):
				return false
	var offs: Array[Vector2] = [
		Vector2.ZERO, Vector2(rad, 0), Vector2(-rad, 0), Vector2(0, rad), Vector2(0, -rad)
	]
	for o in offs:
		if _cleared(x + o.x, z + o.y):
			return false
	return terrain.surface_at(x, z) in OPEN


func _cleared(x: float, z: float) -> bool:
	if _clear.size() != 3:
		return false
	var img: Image = _clear[0]
	var org: Vector2 = _clear[1]
	var cell := float(_clear[2])
	var i := floori((x - org.x) / cell)
	var j := floori((z - org.y) / cell)
	if i < 0 or j < 0 or i >= img.get_width() or j >= img.get_height():
		return false
	return img.get_pixel(i, j).r > 0.3
