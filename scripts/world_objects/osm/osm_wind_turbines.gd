class_name OsmWindTurbines
extends Node3D
## Ветряки OSM (L6, osm-look OL-3): башня (MultiMesh по тайлам, статика), гондола и ротор — отдельные
## экземпляры. Гондола разворачивается носом на ветер с ограниченной скоростью (yaw_deg_s), ротор крутится
## по кривой: 0 ниже cut_in_ms, линейно до rated_rpm при rated_ms, rated_rpm до cut_out_ms, стоп выше;
## частота вращения меняется не быстрее rotor_accel_rpm_s, угол копится (без рывков при смене ветра).
## Ветер — только через контракт L4: узел в группе &"osm_wind", метод osm_wind(air_fn, cam); воздух
## спрашивается на высоте ступицы, по одному вызову на кластер (cluster_m), ближайшие кластеры в
## visibility_m, не больше max_samples за вызов. Без osm_wind — нос по +X, ротор стоит.
## Модели — assets/models/osm/wind_tower.glb (Tower, Nacelle, Hub) и wind_rotor.glb (L6); высота ступицы
## модели берётся из неё же, экземпляр масштабируется равномерно на h / h_эталона. Настройки —
## world_objects.json → osm_pilot.wind_turbines; башня — препятствие-цилиндр, как у прежних ветряков.

const TOWER_PATH := "res://assets/models/osm/wind_tower.glb"
const ROTOR_PATH := "res://assets/models/osm/wind_rotor.glb"
const TILE_M := 4000.0

var _cfg: Dictionary = {}
var _vis := 8000.0
var _max_samples := 24
var _yaw_rate := 0.0  # рад/с
var _acc := 0.0       # рад/с²
var _cut_in := 3.0
var _rated := 12.0
var _cut_out := 25.0
var _rated_omega := 0.0  # рад/с

var _nac_pos := Vector3.ZERO     # ось рыскания гондолы в модели башни
var _hub_off := Vector3.ZERO     # ступица в системе гондолы
var _ref_hub := 80.0

# состояние ветряков (индекс i)
var _base: PackedVector3Array = PackedVector3Array()
var _scale: PackedFloat32Array = PackedFloat32Array()
var _yaw: PackedFloat32Array = PackedFloat32Array()
var _target_yaw: PackedFloat32Array = PackedFloat32Array()
var _omega: PackedFloat32Array = PackedFloat32Array()
var _target_omega: PackedFloat32Array = PackedFloat32Array()
var _angle: PackedFloat32Array = PackedFloat32Array()
var _tile_of: PackedInt32Array = PackedInt32Array()
var _slot_of: PackedInt32Array = PackedInt32Array()  # номер экземпляра в MultiMesh тайла
var _cluster_of: PackedInt32Array = PackedInt32Array()

var _tiles: Array[Dictionary] = []     # {center, nac: MultiMesh, rot: MultiMesh, members: PackedInt32Array}
var _clusters: Array[Dictionary] = []  # {pos: Vector3, members: PackedInt32Array}
var _cam := Vector3.ZERO
var _has_cam := false


## Частота вращения ротора, об/мин, при скорости ветра на ступице speed_ms (кривая турбины).
static func rpm_for(speed_ms: float, cut_in: float, rated: float, cut_out: float, rated_rpm: float) -> float:
	if speed_ms < cut_in or speed_ms > cut_out:
		return 0.0
	if speed_ms >= rated:
		return rated_rpm
	return rated_rpm * (speed_ms - cut_in) / maxf(rated - cut_in, 1e-3)


static func build(data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> Node3D:
	var pc: Dictionary = cfg.get("osm_pilot", {})
	if data == null or pc.is_empty() or not pc.has("wind_turbines"):
		return null
	var wc: Dictionary = pc.wind_turbines
	if not bool(wc.get("enabled", true)):
		return null
	var items: Array = []
	for v: Dictionary in data.verticals:
		if String(v.t) == "wind":
			items.append(v)
	if items.is_empty():
		return null
	var node := OsmWindTurbines.new()
	if not node._setup(items, pc, cfg, height_fn, obstacles):
		node.free()
		return null
	return node


func _init() -> void:
	name = "WindTurbines"
	add_to_group(&"osm_wind")


func turbine_count() -> int:
	return _base.size()


func yaw_of(i: int) -> float:
	return _yaw[i]


func omega_of(i: int) -> float:
	return _omega[i]


func angle_of(i: int) -> float:
	return _angle[i]


func hub_position(i: int) -> Vector3:
	return _base[i] + Vector3.UP * _scale[i] * _ref_hub


## Тест/отладка: выставить состояние ветряка напрямую.
func debug_set(i: int, yaw: float, omega: float) -> void:
	_yaw[i] = yaw
	_omega[i] = omega


func _setup(items: Array, pc: Dictionary, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> bool:
	var wc: Dictionary = pc.wind_turbines
	_cfg = wc
	_vis = float(wc.visibility_m)
	_max_samples = int(wc.max_samples)
	_yaw_rate = deg_to_rad(float(wc.yaw_deg_s))
	_acc = float(wc.rotor_accel_rpm_s) * TAU / 60.0
	_cut_in = float(wc.cut_in_ms)
	_rated = float(wc.rated_ms)
	_cut_out = float(wc.cut_out_ms)
	_rated_omega = float(wc.rated_rpm) * TAU / 60.0
	if not _load_meshes():
		return false
	var vc: Dictionary = pc.verticals
	var cl_m := float(wc.cluster_m)
	var tile_idx := {}   # Vector2i → индекс в _tiles
	var cl_idx := {}     # Vector2i → индекс в _clusters
	for v: Dictionary in items:
		var x := float(v.x)
		var z := float(v.z)
		var h := float(v.h) if float(v.h) > 0.0 else float(vc.default_h_m.wind)
		var g := float(height_fn.call(x, z))
		var i := _base.size()
		_base.append(Vector3(x, g, z))
		_scale.append(h / _ref_hub)
		_yaw.append(0.0)
		_target_yaw.append(0.0)
		_omega.append(0.0)
		_target_omega.append(0.0)
		_angle.append(WorldTiles.hash01(int(x) + int(z) * 31) * TAU)
		var tk := WorldTiles.key(x, z, TILE_M)
		if not tile_idx.has(tk):
			tile_idx[tk] = _tiles.size()
			_tiles.append({"center": WorldTiles.center(tk, TILE_M), "members": PackedInt32Array()})
		var ti: int = tile_idx[tk]
		_tile_of.append(ti)
		var tm: PackedInt32Array = _tiles[ti].members
		_slot_of.append(tm.size())
		tm.append(i)
		_tiles[ti].members = tm
		var ck := WorldTiles.key(x, z, cl_m)
		if not cl_idx.has(ck):
			cl_idx[ck] = _clusters.size()
			_clusters.append({"sum": Vector3.ZERO, "pos": Vector3.ZERO, "members": PackedInt32Array()})
		var ci: int = cl_idx[ck]
		_cluster_of.append(ci)
		var cm: PackedInt32Array = _clusters[ci].members
		cm.append(i)
		_clusters[ci].members = cm
		_clusters[ci].sum += Vector3(x, g + h, z)
		var rad := float(vc.radius_m.wind)
		obstacles.add_cylinder(x, z, maxf(rad, 0.5), g - 1.0, g + h, "tower")
	for c: Dictionary in _clusters:
		c.pos = (c.sum as Vector3) / float((c.members as PackedInt32Array).size())
	var shadows := bool(wc.cast_shadows)
	var r := WorldTiles.tile_range(_vis, TILE_M)
	for t: Dictionary in _tiles:
		var members: PackedInt32Array = t.members
		var tower_tf: Array[Transform3D] = []
		for i in members:
			tower_tf.append(Transform3D(Basis.from_scale(Vector3.ONE * _scale[i]), _base[i]))
		var tn := WorldTiles.multimesh_node(_tower_mesh, tower_tf, PackedColorArray(), t.center, r, shadows)
		var nn := WorldTiles.multimesh_node(_nacelle_mesh, tower_tf, PackedColorArray(), t.center, r, shadows)
		var rn := WorldTiles.multimesh_node(_rotor_mesh, tower_tf, PackedColorArray(), t.center, r, shadows)
		for n: Node3D in [tn, nn, rn]:
			add_child(n)
		t.nac = nn.multimesh
		t.rot = rn.multimesh
		_write_tile(t)
	return true


var _tower_mesh: Mesh
var _nacelle_mesh: Mesh
var _rotor_mesh: Mesh


func _load_meshes() -> bool:
	if not ResourceLoader.exists(TOWER_PATH) or not ResourceLoader.exists(ROTOR_PATH):
		push_warning("OsmWindTurbines: нет моделей %s / %s" % [TOWER_PATH, ROTOR_PATH])
		return false
	var ts := load(TOWER_PATH) as PackedScene
	var rs := load(ROTOR_PATH) as PackedScene
	if ts == null or rs == null:
		return false
	var tr := ts.instantiate()
	var tower := tr.find_child("Tower", true, false) as MeshInstance3D
	var nac := tr.find_child("Nacelle", true, false) as MeshInstance3D
	var hub := tr.find_child("Hub", true, false) as Node3D
	var ro := rs.instantiate()
	var rotor: MeshInstance3D = ro.find_child("Rotor", true, false) as MeshInstance3D
	var ok := tower != null and nac != null and hub != null and rotor != null
	if ok:
		_tower_mesh = tower.mesh
		_nacelle_mesh = nac.mesh
		_rotor_mesh = rotor.mesh
		_nac_pos = nac.position
		_hub_off = hub.position
		_ref_hub = _nac_pos.y + _hub_off.y
	tr.free()
	ro.free()
	return ok


## L4: опрос воздуха на высоте ступицы; кластеры ближе visibility_m, ближайшие first, ≤ max_samples.
func osm_wind(air_fn: Callable, cam: Vector3) -> void:
	_cam = cam
	_has_cam = true
	var near: Array = []
	for ci in _clusters.size():
		var d: float = Vector2((_clusters[ci].pos as Vector3).x - cam.x, (_clusters[ci].pos as Vector3).z - cam.z).length()
		if d <= _vis:
			near.append([d, ci])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var rated_rpm := _rated_omega * 60.0 / TAU
	for k in mini(near.size(), _max_samples):
		var c: Dictionary = _clusters[near[k][1]]
		var w: Vector3 = air_fn.call(c.pos)
		var sp := Vector2(w.x, w.z).length()
		var om := rpm_for(sp, _cut_in, _rated, _cut_out, rated_rpm) * TAU / 60.0
		for i in (c.members as PackedInt32Array):
			_target_omega[i] = om
			if sp >= float(_cfg.min_dir_ms):
				_target_yaw[i] = atan2(w.z, -w.x)  # нос навстречу ветру


## Продвинуть состояние на dt: рыскание с ограничением скорости, частота вращения с ограничением ускорения,
## угол копится. Тайлы в visibility_m от камеры перезаписываются в MultiMesh.
func step(dt: float) -> void:
	for i in _base.size():
		var d := wrapf(_target_yaw[i] - _yaw[i], -PI, PI)
		var mx := _yaw_rate * dt
		_yaw[i] = wrapf(_yaw[i] + clampf(d, -mx, mx), -PI, PI)
		var dw := _target_omega[i] - _omega[i]
		_omega[i] += clampf(dw, -_acc * dt, _acc * dt)
		_angle[i] = fposmod(_angle[i] + _omega[i] * dt, TAU)
	for t: Dictionary in _tiles:
		if not _has_cam or _tile_near(t):
			_write_tile(t)


func _tile_near(t: Dictionary) -> bool:
	var c: Vector3 = t.center
	return Vector2(c.x - _cam.x, c.z - _cam.z).length() <= _vis + TILE_M * 0.7072


func _write_tile(t: Dictionary) -> void:
	var members: PackedInt32Array = t.members
	var nac: MultiMesh = t.nac
	var rot: MultiMesh = t.rot
	var org: Vector3 = t.center
	for slot in members.size():
		var i := members[slot]
		var s := _scale[i]
		var yb := Basis(Vector3.UP, _yaw[i])
		var sb := Basis.from_scale(Vector3.ONE * s)
		var pivot := _base[i] + Vector3(0.0, _nac_pos.y * s, 0.0) - org
		nac.set_instance_transform(slot, Transform3D(yb * sb, pivot))
		# ротор: локальная Z модели → нос (+X гондолы); вращение по часовой при взгляде спереди
		var rb := yb * Basis(Vector3.UP, PI * 0.5) * Basis(Vector3.BACK, -_angle[i]) * sb
		rot.set_instance_transform(slot, Transform3D(rb, pivot + yb * (_hub_off * s)))


func _process(dt: float) -> void:
	var vp := get_viewport()
	var cam3d := vp.get_camera_3d() if vp != null else null
	if cam3d != null:
		_cam = cam3d.global_position
		_has_cam = true
	step(dt)
