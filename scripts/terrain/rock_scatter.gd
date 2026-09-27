class_name RockScatter
extends Node3D
## 3D-камни у земли: глыбы курумника, выходы коренной породы, камни на скалах и редкие одиночные
## камни в траве — MultiMesh вокруг камеры в радиусе rocks.radius_m (configs/world.json → rocks).
## Дальше камней нет — там шейдерные пятна породы terrain.gdshader.
## Где ставить — та же логика, что у пятен породы в terrain.gdshader (выпуклость в масштабе
## terrain_look.outcrop_scale_m, уклон outcrop_slope_deg, пятна outcrop_patch_m, доля курумника
## kurum_share), класс поверхности Terrain.surface_at (BARE — скалы; лес, вода, поля, застройка,
## снег — без камней), маска просек Terrain.set_clearings и площадки (keep_off_sites_m).
## Расстановка детерминирована: хеш клетки выборки (sample_m), тайлы tile_m кешируются.
## Модели — assets/models/rocks/rocks.glb (tools/blender/build_rocks.py), 3 LOD.
## Подключение: RockScatter.attach(terrain, camera) — нода "Rocks" ребёнком Terrain.

const SHADER := preload("res://scripts/terrain/rock_scatter.gdshader")
const LODS := 3
## категории камней: курумник, коренная порода, скалы, одиночные в траве
const CATS: PackedStringArray = ["kurum", "bedrock", "steep", "grass"]
const NO_ROCKS: Array[int] = [
	SurfaceLayer.FOREST,
	SurfaceLayer.WATER,
	SurfaceLayer.CROP,
	SurfaceLayer.BUILT,
	SurfaceLayer.SNOW
]

var camera: Camera3D
var terrain: Terrain
var material: ShaderMaterial

var _cfg: Dictionary = {}
var _look: Dictionary = {}
var _n_boulders := 0
var _n_stones := 0
## _mmis[вариант * LODS + lod]
var _mmis: Array[MultiMeshInstance3D] = []
## Vector2i тайла → {xf: PackedFloat32Array (12 на камень), col: PackedFloat32Array (4),
## size: PackedFloat32Array, var: PackedInt32Array}
var _tiles: Dictionary = {}
## площадки: [Vector2 позиция, Vector2 направление разбега (ZERO у посадок), радиус, м]
var _sites: Array = []
var _clear: Array = []
var _key := ""
var _task := -1
var _buffers: Array = []
var _last_center := Vector2(INF, INF)
var _pending_center := Vector2.ZERO
var _ready_ok := false


## Поставить (или найти) разброс камней под terrain. camera — null: камера вьюпорта.
static func attach(t: Terrain, cam: Camera3D = null) -> RockScatter:
	var r := t.get_node_or_null("Rocks") as RockScatter
	if r == null:
		r = RockScatter.new()
		r.name = "Rocks"
		r.terrain = t
		t.add_child(r)
	if cam != null:
		r.camera = cam
	return r


func _ready() -> void:
	if terrain == null:
		terrain = get_parent() as Terrain
	setup(Config.get_config("world").get("rocks", {}))


## Загрузить модели и материал. false — выключено или нет модели.
func setup(cfg: Dictionary) -> bool:
	_cfg = cfg
	_look = Config.get_config("world").get("terrain_look", {})
	if not bool(cfg.get("enabled", false)):
		return false
	var names: Array = cfg.get("boulders", []) + cfg.get("stones", [])
	_n_boulders = (cfg.get("boulders", []) as Array).size()
	_n_stones = (cfg.get("stones", []) as Array).size()
	var meshes := load_meshes(String(cfg.get("model_path", "")), names)
	if meshes.is_empty() or _n_boulders == 0 or _n_stones == 0:
		push_warning("RockScatter: нет модели камней %s" % cfg.get("model_path", ""))
		return false
	material = _make_material(cfg)
	var shadows := bool(cfg.get("cast_shadows", true))
	for v in names.size():
		for lod in LODS:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = meshes[v * LODS + lod]
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_LOD%d" % [names[v], lod]
			mmi.multimesh = mm
			mmi.material_override = material
			mmi.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if shadows and lod == 0
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(mmi)
			_mmis.append(mmi)
	_ready_ok = true
	return true


## Меши вариантов: [вариант * LODS + lod]; пусто — нет файла или ноды.
static func load_meshes(path: String, names: Array) -> Array[Mesh]:
	var out: Array[Mesh] = []
	if path == "" or not ResourceLoader.exists(path):
		return out
	var ps := load(path) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	for n in names:
		for lod in LODS:
			var mi := root.find_child("%s_LOD%d" % [n, lod], true, false) as MeshInstance3D
			if mi == null or mi.mesh == null:
				root.free()
				out.clear()
				return out
			out.append(mi.mesh)
	root.free()
	return out


func _make_material(cfg: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	var c: Array = cfg.get("color", [0.36, 0.34, 0.31])
	var lc: Array = cfg.get("lichen_color", [0.52, 0.53, 0.42])
	m.set_shader_parameter("base_color", Color(float(c[0]), float(c[1]), float(c[2])))
	m.set_shader_parameter("lichen_color", Color(float(lc[0]), float(lc[1]), float(lc[2])))
	m.set_shader_parameter("lichen_amount", float(cfg.get("lichen_amount", 0.35)))
	m.set_shader_parameter("tile_m", float(cfg.get("tex_tile_m", 2.5)))
	var tex := TerrainRenderer.load_texture(String(cfg.get("texture", "")))
	if tex != null:
		m.set_shader_parameter("rock_tex", tex)
		m.set_shader_parameter("use_tex", true)
		var avg := TerrainRenderer._average_color(tex)
		m.set_shader_parameter("tex_avg", Vector3(avg.r, avg.g, avg.b))
	var ntex := TerrainRenderer.load_texture(String(cfg.get("normal", "")))
	if ntex != null:
		m.set_shader_parameter("rock_normal", ntex)
		m.set_shader_parameter("use_normal", true)
	return m


## Всего камней в MultiMesh'ах сейчас (для тестов и отладки).
func instance_count() -> int:
	var n := 0
	for mmi in _mmis:
		n += mmi.multimesh.instance_count
	return n


func _process(_delta: float) -> void:
	if not _ready_ok or terrain == null or terrain.layers.is_empty():
		return
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
	var show := agl < float(_cfg.get("max_agl_m", 600.0))
	if visible != show:
		visible = show
	if not show:
		return
	_check_key()
	var c := Vector2(p.x, p.z)
	if c.distance_to(_last_center) < float(_cfg.get("rebuild_step_m", 20.0)):
		return
	_last_center = c
	_pending_center = c
	# всегда в рабочем потоке: синхронная первая сборка (радиус целиком) стоила кадр ~0,5–1 с
	# на загрузке нового места — камни появляются на кадр-другой позже
	_task = WorkerThreadPool.add_task(_build.bind(c), false, "rocks")


## Выход из дерева (смена сцены, выход из игры): дождаться фоновой сборки — она читает рельеф.
func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


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
	_key = k
	_tiles.clear()
	_clear = cl
	_sites.clear()
	for s in terrain.get_start_sites():
		var sp: Vector3 = s.position
		var hd := TerrainGeo.heading_vector(float(s.get("heading_deg", 0.0)))
		_sites.append([Vector2(sp.x, sp.z), Vector2(hd.x, hd.z).normalized(), _keep_start()])
	for s in terrain.get_landing_sites():
		var sp: Vector3 = s.position
		_sites.append(
			[Vector2(sp.x, sp.z), Vector2.ZERO, float(_cfg.get("keep_off_landing_m", 40.0))]
		)
	_last_center = Vector2(INF, INF)


## Рабочий поток: достроить тайлы вокруг c, собрать буферы MultiMesh (ближние тайлы первыми).
func _build(c: Vector2) -> void:
	var radius := float(_cfg.get("radius_m", 300.0))
	var tile := float(_cfg.get("tile_m", 48.0))
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
	for k in _tiles.keys():
		if ((Vector2(k) + Vector2(0.5, 0.5)) * tile).distance_to(c) > radius * 1.6:
			_tiles.erase(k)
	for k in keys:
		if not _tiles.has(k):
			_tiles[k] = build_tile(k.x, k.y)
	_buffers = _assemble(c, keys, radius)


func _assemble(c: Vector2, keys: Array[Vector2i], radius: float) -> Array:
	var nb := _mmis.size()
	var bufs: Array[PackedFloat32Array] = []
	bufs.resize(nb)
	var lod_m: Array = _cfg.get("lod_m", [40.0, 120.0])
	var l0 := float(lod_m[0])
	var l1 := float(lod_m[1])
	var view_k := float(_cfg.get("view_per_m", 110.0))
	var budget := int(_cfg.get("max_instances", 9000))
	for k in keys:
		var t: Dictionary = _tiles[k]
		var xf: PackedFloat32Array = t.xf
		var col: PackedFloat32Array = t.col
		var sz: PackedFloat32Array = t.size
		var vv: PackedInt32Array = t["var"]
		for i in vv.size():
			var d := Vector2(xf[i * 12 + 3], xf[i * 12 + 11]).distance_to(c)
			var s := sz[i]
			if d > clampf(s * view_k, 50.0, radius):
				continue
			var ls := sqrt(clampf(s, 0.5, 4.0))
			var lod := 0 if d < l0 * ls else (1 if d < l1 * ls else 2)
			var b := vv[i] * LODS + lod
			bufs[b].append_array(xf.slice(i * 12, i * 12 + 12))
			bufs[b].append_array(col.slice(i * 4, i * 4 + 4))
			budget -= 1
			if budget <= 0:
				return bufs
	return bufs


func _apply() -> void:
	if _buffers.is_empty():
		return
	var tl: HeightLayer = terrain.layers[terrain.layers.size() - 1]
	var r := float(_cfg.get("radius_m", 300.0))
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


## Камни тайла (tx, tz) размера tile_m: {xf, col, size, var} (см. _tiles). Детерминированно.
func build_tile(tx: int, tz: int) -> Dictionary:
	var out := {
		"xf": PackedFloat32Array(),
		"col": PackedFloat32Array(),
		"size": PackedFloat32Array(),
		"var": PackedInt32Array()
	}
	var tile := float(_cfg.get("tile_m", 48.0))
	var step := float(_cfg.get("sample_m", 6.0))
	var n := maxi(int(round(tile / step)), 1)
	step = tile / n
	for j in n:
		for i in n:
			var ix := tx * n + i
			var iz := tz * n + j
			_sample(ix, iz, step, out)
	return out


## Одна клетка выборки: классы, уклон, выпуклость — и камни в ней.
func _sample(ix: int, iz: int, step: float, out: Dictionary) -> void:
	var x := (ix + 0.5) * step
	var z := (iz + 0.5) * step
	var cls := terrain.surface_at(x, z)
	if cls in NO_ROCKS:
		return
	var n := terrain.normal_at(x, z)
	var slope := rad_to_deg(acos(clampf(n.y, 0.0, 1.0)))
	var h := terrain.height_at(x, z)
	var k := float(_look.get("outcrop_scale_m", 35.0))
	var convex := (
		-(
			terrain.height_at(x + k, z)
			+ terrain.height_at(x - k, z)
			+ terrain.height_at(x, z + k)
			+ terrain.height_at(x, z - k)
			- 4.0 * h
		)
		/ (4.0 * k)
	)
	var ck := float(_look.get("outcrop_convex_k", 0.035))
	var sd: Array = _look.get("outcrop_slope_deg", [25.0, 36.0])
	var cv := smoothstep(0.25, 1.0, convex / ck)
	var steep := smoothstep(float(sd[0]), float(sd[1]), slope)
	var drv := maxf(cv, steep)
	var kurum := 0.0
	if drv > 0.01:
		kurum = clampf(
			(
				smoothstep(
					0.35,
					0.65,
					(
						vnoise(Vector2(x, z) / 160.0 + Vector2(3.3, 1.1))
						+ float(_look.get("kurum_share", 0.5))
						- 0.5
					)
				)
				+ 0.35 * (steep - cv)
			),
			0.0,
			1.0
		)
	var area := step * step
	var bare := cls == SurfaceLayer.BARE
	for ci in CATS.size():
		var cat: Dictionary = _cfg.get(CATS[ci], {})
		var e := float(cat.get("density", 0.0)) * area
		match ci:
			0:
				e *= kurum if drv > 0.01 else 0.0
			1:
				e *= (1.0 - kurum) if drv > 0.01 else 0.0
			2:
				e *= 1.0 if bare else 0.0
			3:
				e *= 0.0 if bare else 1.0
		if e <= 0.0:
			continue
		var cnt := int(e + hash01(ix, iz, 100 + ci))
		for r in cnt:
			_place(ix, iz, step, ci, r, cat, drv, out)


func _place(
	ix: int, iz: int, step: float, ci: int, r: int, cat: Dictionary, drv: float, out: Dictionary
) -> void:
	var s0 := 1000 + ci * 64 + r * 8
	var px := (ix + hash01(ix, iz, s0)) * step
	var pz := (iz + hash01(ix, iz, s0 + 1)) * step
	var oc := outcrop_at(px, pz, drv)
	# курумник и коренная порода — только в пятнах породы (как в шейдере), трава — вне их
	if ci <= 1 and hash01(ix, iz, s0 + 2) >= oc:
		return
	if ci == 3 and oc > 0.05:
		return
	var sr: Array = cat.get("size_m", [0.5, 1.5])
	var u := hash01(ix, iz, s0 + 3)
	var size := lerpf(float(sr[0]), float(sr[1]), u * u)
	var stone := hash01(ix, iz, s0 + 4) < float(cat.get("stone_share", 0.3))
	var v: int
	if stone:
		v = _n_boulders + int(hash01(ix, iz, s0 + 5) * _n_stones) % _n_stones
		if ci != 3:
			size *= 0.45
	else:
		v = int(hash01(ix, iz, s0 + 5) * _n_boulders) % _n_boulders
	if not is_free(px, pz, size * 0.5):
		return
	var nn := terrain.normal_at(px, pz)
	var up := nn
	var tall := 1.0
	match ci:
		1:
			up = Vector3.UP.lerp(nn, 0.35).normalized()
			tall = 1.2 + 0.5 * hash01(ix, iz, s0 + 6)
		3:
			up = Vector3.UP.lerp(nn, 0.7).normalized()
	var yaw := hash01(ix, iz, s0 + 7) * TAU
	var j1 := hash01(ix, iz, s0 + 6)
	var b := Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, yaw)
	b = b.scaled_local(
		Vector3(size * (0.85 + 0.3 * j1), size * tall * (0.8 + 0.4 * u), size * (1.15 - 0.3 * j1))
	)
	var y := (
		terrain.height_at(px, pz)
		- size * (float(_cfg.get("sink", 0.12)) + 0.5 * sqrt(maxf(1.0 - nn.y * nn.y, 0.0)))
	)
	out.xf.append_array(
		PackedFloat32Array(
			[b.x.x, b.y.x, b.z.x, px, b.x.y, b.y.y, b.z.y, y, b.x.z, b.y.z, b.z.z, pz]
		)
	)
	var tv := float(_cfg.get("tint_var", 0.18))
	var br := 1.0 + tv * (2.0 * hash01(ix, iz, s0 + 8) - 1.0)
	var och := 0.08 * (2.0 * hash01(ix, iz, s0 + 9) - 1.0)
	out.col.append_array(PackedFloat32Array([br * (1.0 + och), br, br * (1.0 - och), 1.0]))
	out.size.append(size)
	out["var"].append(v)


## Сила пятна породы в точке (как outcrop в terrain.gdshader, вблизи — с дроблением 3–10 м).
func outcrop_at(x: float, z: float, drv: float) -> float:
	if drv <= 0.01:
		return 0.0
	var patch := float(_look.get("outcrop_patch_m", 45.0))
	var p := Vector2(x, z)
	var brk := vnoise(p / (patch * 0.18))
	brk = brk * 0.6 + vnoise(p / (patch * 0.06) + Vector2(3.7, 0.4)) * 0.4
	var pn := fbm2(p / patch + Vector2(12.7, 3.1)) + 0.2 * (brk - 0.5)
	return (
		smoothstep(0.5, 0.56, pn + 0.2 * (drv - 1.0))
		* smoothstep(0.0, 0.3, drv)
		* float(_look.get("outcrop_amount", 0.9))
	)


## Можно ли ставить камень радиуса rad в (x, z): не вода/лес, не просека, не у площадки.
func is_free(x: float, z: float, rad: float) -> bool:
	var q := Vector2(x, z)
	for s: Array in _sites:
		var d: Vector2 = q - s[0]
		var keep: float = s[2] + rad
		if d.length_squared() < keep * keep:
			return false
		# коридор разбега старта: вдоль курса run_m, в стороны half_w
		var dir: Vector2 = s[1]
		if dir != Vector2.ZERO:
			var along := d.dot(dir)
			var run: Array = _cfg.get("start_run_m", [45.0, 10.0])
			if along > -5.0 and along < float(run[0]) and absf(d.cross(dir)) < float(run[1]) + rad:
				return false
	var offs: Array[Vector2] = [
		Vector2.ZERO, Vector2(rad, 0), Vector2(-rad, 0), Vector2(0, rad), Vector2(0, -rad)
	]
	for o in offs:
		if _cleared(x + o.x, z + o.y):
			return false
	var c := terrain.surface_at(x, z)
	return not c in NO_ROCKS


func _keep_start() -> float:
	return float(_cfg.get("keep_off_start_m", 12.0))


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


## Детерминированный хеш клетки 0..1.
static func hash01(ix: int, iz: int, k: int) -> float:
	var h := (ix * 73856093) ^ (iz * 19349663) ^ (k * 83492791) ^ 0x5bd1e995
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFFFF) / 16777216.0


# ---- шум как в terrain_common.gdshaderinc (hash12, vnoise, fbm) ----


static func hash12(p: Vector2) -> float:
	p = Vector2(fposmod(p.x, 4096.0), fposmod(p.y, 4096.0))
	var p3 := Vector3(p.x, p.y, p.x) * 0.1031
	p3 = Vector3(p3.x - floorf(p3.x), p3.y - floorf(p3.y), p3.z - floorf(p3.z))
	p3 += Vector3.ONE * p3.dot(Vector3(p3.y, p3.z, p3.x) + Vector3.ONE * 33.33)
	var r := (p3.x + p3.y) * p3.z
	return r - floorf(r)


static func vnoise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a := hash12(i)
	var b := hash12(i + Vector2(1.0, 0.0))
	var c := hash12(i + Vector2(0.0, 1.0))
	var d := hash12(i + Vector2(1.0, 1.0))
	return lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y)


## fbm(p, 2) шейдера.
static func fbm2(p: Vector2) -> float:
	var s := 0.5 * vnoise(p)
	# GLSL mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p: столбцы (1.6, 1.2) и (−1.2, 1.6)
	p = Vector2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y) + Vector2(17.3, 9.1)
	s += 0.25 * vnoise(p)
	return s / 0.75
