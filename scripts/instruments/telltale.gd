class_name Telltale
extends Node3D
## Ленточка («ниточка», yaw string) на тросе трапеции (docs/telltale.md). Нода — дочерняя крыла,
## стоит в точке узла на тросе; физика — TelltaleModel, рисунок — лента ImmediateMesh.
## Точка крепления выводится из геометрии трапеции модели крыла (find_anchor), без координат в
## коде: работает для любого крыла, собранного по контракту docs/models.md.
##
## Шаг физики делает владелец (GliderVisual.step_telltales ← Glider.step): до первого шага
## ленточка скрыта (у ботов шагов нет — ленточек не видно).

## Имена пустышек, которыми модель крыла может задать узел явно (иначе — из тросов трапеции).
const MARKERS := {-1: "TelltaleL", 1: "TelltaleR"}

var model := TelltaleModel.new()
var side := 1  ## −1 — левый трос, +1 — правый

var _cfg: Dictionary = {}
var _mesh := ImmediateMesh.new()
var _mi: MeshInstance3D
var _twist_deg := 0.0
var _width := 0.02
var _stepped := false


## Собрать ленточки на крыле wing по instruments.json → telltale. Возвращает созданные ноды.
static func build_on(wing: Node3D, cfg: Dictionary = {}) -> Array[Telltale]:
	var out: Array[Telltale] = []
	if cfg.is_empty():
		cfg = Config.get_config("instruments").get("telltale", {})
	if wing == null or not bool(cfg.get("enabled", true)):
		return out
	for s: String in cfg.get("sides", ["left", "right"]):
		var sd := -1 if s == "left" else 1
		var a := find_anchor(wing, sd, cfg)
		if a.is_empty():
			push_warning("Telltale: не нашёл трос трапеции (%s) — ленточки нет" % s)
			continue
		var t := Telltale.new()
		t.name = "Telltale" + ("L" if sd < 0 else "R")
		t.side = sd
		t.position = a.point
		wing.add_child(t)
		t.setup(cfg)
		out.append(t)
	return out


## Точка узла на тросе в осях крыла {point, wire_dir} или {} если тросов нет.
## Сначала пустышка TelltaleL/R; иначе поверхность с материалом «Wire» у ControlFrame
## (docs/models.md): угол трапеции — нижние точки тросов этой стороны; боковой трос — к самой
## дальней по размаху точке (узел поперечины), передний — к носу (самой передней точке у киля).
static func find_anchor(wing: Node3D, sd: int, cfg: Dictionary) -> Dictionary:
	var mk := wing.find_child(MARKERS[sd], true, false) as Node3D
	if mk != null:
		var x := _rel(wing, mk)
		return {"point": x.origin, "wire_dir": x.basis.y.normalized()}
	var cf := wing.find_child("ControlFrame", true, false) as MeshInstance3D
	if cf == null or cf.mesh == null:
		return {}
	var xf := _rel(wing, cf)
	var verts := PackedVector3Array()
	var mesh := cf.mesh
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat == null or not mat.resource_name.begins_with("Wire"):
			continue
		for v: Vector3 in mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			verts.append(xf * v)
	var mine := PackedVector3Array()
	var y_min := INF
	for v in verts:
		if v.x * sd > 0.05:
			mine.append(v)
			y_min = minf(y_min, v.y)
	if mine.size() < 4:
		return {}
	var corner := Vector3.ZERO
	var cn := 0
	for v in mine:
		if v.y < y_min + 0.03:
			corner += v
			cn += 1
	corner /= cn
	var far := corner
	if String(cfg.get("wire", "side")) == "front":
		var best := INF
		for v in verts:
			if absf(v.x) < 0.05 and v.z < best:
				best = v.z
				far = v
	else:
		for v in mine:
			if absf(v.x) > absf(far.x):
				far = v
	var d := far - corner
	if d.length() < 0.3:
		return {}
	var wire_len := d.length()
	d = d.normalized()
	# Узел от верхнего конца троса (у носа), если задан; иначе — от угла трапеции.
	var from_top := float(cfg.get("from_top_m", -1.0))
	var along := wire_len - from_top if from_top >= 0.0 else float(cfg.get("along_wire_m", 0.35))
	return {"point": corner + d * along, "wire_dir": d}


static func _rel(root: Node, node: Node3D) -> Transform3D:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x


func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	model.setup(cfg)
	_width = float(cfg.get("width_m", 0.02))
	_twist_deg = float(cfg.get("twist_max_deg", 30.0))
	_mi = MeshInstance3D.new()
	_mi.name = "Ribbon"
	_mi.mesh = _mesh
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var c: Array = cfg.get("color", [0.9, 0.02, 0.02])
	m.albedo_color = Color(float(c[0]), float(c[1]), float(c[2]))
	m.roughness = float(cfg.get("roughness", 0.8))
	var e := float(cfg.get("emission_energy", 0.0))
	if e > 0.0:
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = e
	_mi.material_override = m
	add_child(_mi)
	visible = false


## Шаг физики: r — точка узла в осях планера (от начала ноды Glider), prev/cur — ориентация
## планера на прошлом и этом шаге, velocity — скорость начала планера, air_fn(pos) → ветер.
func step(
	dt: float, r: Vector3, prev: Basis, cur: Transform3D, velocity: Vector3, air_fn: Callable
) -> void:
	var pos := cur * r
	var air: Vector3 = air_fn.call(pos) if air_fn.is_valid() else Vector3.ZERO
	var w := TelltaleModel.airflow_at(air, velocity, prev, cur.basis, r, dt)
	if not _stepped:
		model.snap(w)
		_stepped = true
		visible = true
	model.step(dt, w)


func _process(_dt: float) -> void:
	if not _stepped or not is_inside_tree():
		return
	var inv := global_basis.orthonormalized().inverse()
	var lat := inv * model.lateral
	var n := model.dirs.size()
	var p := Vector3.ZERO
	var t := model.time_s
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n + 1:
		var d := inv * model.dirs[mini(i, n - 1)]
		var wd := d.cross(lat)
		wd = wd.normalized() if wd.length() > 1.0e-3 else d.cross(Vector3.RIGHT).normalized()
		var tw := deg_to_rad(_twist_deg) * float(i) / n * sin(t * 2.3 + i * 0.8 + side)
		wd = wd.rotated(d, tw)
		var nrm := d.cross(wd).normalized()
		var half := wd * (_width * 0.5 * (1.0 - 0.25 * float(i) / n))
		_mesh.surface_set_normal(nrm)
		_mesh.surface_add_vertex(p - half)
		_mesh.surface_set_normal(nrm)
		_mesh.surface_add_vertex(p + half)
		if i < n:
			p += d * model.segment_m
	_mesh.surface_end()
