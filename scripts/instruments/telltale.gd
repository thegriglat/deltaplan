class_name Telltale
extends Node3D
## Ленточка («ниточка», yaw string) на тросе трапеции (docs/guide/telltale.md). Нода — дочерняя крыла,
## стоит в точке узла на тросе; физика — TelltaleModel, рисунок — лента ImmediateMesh.
## Точка крепления выводится из геометрии трапеции модели крыла (find_anchor), без координат в
## коде: работает для любого крыла, собранного по контракту docs/guide/models.md.
##
## Шаг физики делает владелец (GliderVisual.step_telltales ← Glider.step): до первого шага
## ленточка скрыта (у ботов шагов нет — ленточек не видно).

## Имена пустышек, которыми модель крыла может задать узел явно (иначе — из тросов трапеции).
const MARKERS := {-1: "TelltaleL", 1: "TelltaleR"}
## Профиль рваного конца: доля полуширины по строкам слева/справа (зубцы разной глубины).
const FRAY_L := [0.75, 0.3, 0.9, 0.4, 0.7, 0.2]
const FRAY_R := [0.4, 0.9, 0.35, 0.8, 0.25, 0.6]
const DEFAULT_WIRE_R := 0.0045  ## радиус троса по умолчанию (пустышки), м

var model := TelltaleModel.new()
var side := 1  ## −1 — левый трос, +1 — правый

var _cfg: Dictionary = {}
var _mesh := ImmediateMesh.new()
var _mi: MeshInstance3D
var _twist_deg := 0.0
var _width := 0.02
var _stepped := false
var _pts := PackedVector3Array()  ## узлы цепочки в осях ноды (буфер кадра)
var _u := PackedFloat32Array()  ## параметр строки сплайна: целая часть — звено цепочки
var _fl := PackedFloat32Array()  ## доля полуширины слева по строкам (рваный край)
var _fr := PackedFloat32Array()  ## то же справа


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
		t.setup(cfg, a.wire_dir, float(a.wire_r))
		out.append(t)
	return out


## Точка узла на тросе в осях крыла {point, wire_dir, wire_r, wire_a, wire_b} или {} если тросов нет.
## Сначала пустышка TelltaleL/R; иначе тросы — поверхности с материалом «Wire» у ControlFrame
## (docs/guide/models.md). Каждый трос — отдельная трубка (компонента связности сетки): её ось —
## отрезок между центрами торцевых колец. Нужный трос этой стороны (передний — от угла трапеции к
## носу у киля; боковой — к самой дальней по размаху точке) берётся целиком, узел — точка на его оси
## на высоте height_frac трапеции (высота та же, что и раньше), wire_dir — вдоль оси снизу вверх.
static func find_anchor(wing: Node3D, sd: int, cfg: Dictionary) -> Dictionary:
	var mk := wing.find_child(MARKERS[sd], true, false) as Node3D
	if mk != null and not mk is Telltale:
		var x := _rel(wing, mk)
		return {"point": x.origin, "wire_dir": x.basis.y.normalized(), "wire_r": DEFAULT_WIRE_R}
	var cf := wing.find_child("ControlFrame", true, false) as MeshInstance3D
	if cf == null or cf.mesh == null:
		return {}
	var xf := _rel(wing, cf)
	var mesh := cf.mesh
	var wires: Array[Dictionary] = []
	var y_min := INF
	var y_top := -INF
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		var is_wire := mat != null and mat.resource_name.begins_with("Wire")
		var arr := mesh.surface_get_arrays(si)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in vs:
			y_top = maxf(y_top, (xf * v).y)
		if is_wire:
			_wire_axes(arr, xf, sd, wires)
	if wires.is_empty():
		return {}
	for w in wires:
		y_min = minf(y_min, minf(w.a.y, w.b.y) - w.r)
	# Угол трапеции стороны — нижний конец троса (a), верхний (b) — к носу / узлу поперечины.
	var pick := {}
	var best := INF
	var front := String(cfg.get("wire", "side")) == "front"
	for w in wires:
		# критерий: передний — верхний конец у киля (|x| мал) и самый передний (min z);
		# боковой — самый дальний по размаху верхний конец
		if front:
			if absf(w.b.x) < 0.05 and w.b.z < best:
				best = w.b.z
				pick = w
		elif absf(w.b.x) > 0.05 and -absf(w.b.x) < best:
			best = -absf(w.b.x)
			pick = w
	if pick.is_empty():
		return {}
	var a: Vector3 = pick.a
	var b: Vector3 = pick.b
	var d := b - a
	var wire_len := d.length()
	if wire_len < 0.3:
		return {}
	d /= wire_len
	# Узел на доле высоты трапеции над базовой штангой, если задана; иначе от верхнего конца
	# троса (у носа); иначе — от угла трапеции.
	var frac := float(cfg.get("height_frac", -1.0))
	var from_top := float(cfg.get("from_top_m", -1.0))
	var along := float(cfg.get("along_wire_m", 0.35))
	if frac >= 0.0 and d.y > 0.05:
		along = clampf((y_min + frac * (y_top - y_min) - a.y) / d.y, 0.0, wire_len)
	elif from_top >= 0.0:
		along = wire_len - from_top
	return {"point": a + d * along, "wire_dir": d, "wire_r": pick.r, "wire_a": a, "wire_b": b}


## Оси тросов стороны sd из массивов поверхности: добавляет {a, b, r} в out, a — нижний конец.
## Трос — компонента связности по индексам; концы — центры двух групп вершин (торцевых колец).
static func _wire_axes(arr: Array, xf: Transform3D, sd: int, out: Array[Dictionary]) -> void:
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		idx = PackedInt32Array(range(vs.size()))
	var par := PackedInt32Array()
	par.resize(vs.size())
	for i in vs.size():
		par[i] = i
	for t in range(0, idx.size() - 2, 3):
		for k in 2:
			var ra := _uf_find(par, idx[t])
			var rb := _uf_find(par, idx[t + k + 1])
			if ra != rb:
				par[ra] = rb
	var comps := {}
	for i in vs.size():
		var r := _uf_find(par, i)
		if not comps.has(r):
			comps[r] = PackedVector3Array()
		comps[r].append(xf * vs[i])
	for r in comps:
		var c: PackedVector3Array = comps[r]
		if c.size() < 4:
			continue
		var p0 := c[0]
		var pa := p0
		for v in c:
			if v.distance_squared_to(p0) > pa.distance_squared_to(p0):
				pa = v
		var pb := pa
		for v in c:
			if v.distance_squared_to(pa) > pb.distance_squared_to(pa):
				pb = v
		var ca := Vector3.ZERO
		var cb := Vector3.ZERO
		var na := 0
		var nb := 0
		for v in c:
			if v.distance_squared_to(pa) < v.distance_squared_to(pb):
				ca += v
				na += 1
			else:
				cb += v
				nb += 1
		if na == 0 or nb == 0:
			continue
		ca /= na
		cb /= nb
		var rad := 0.0
		for v in c:
			var near := ca if v.distance_squared_to(ca) < v.distance_squared_to(cb) else cb
			rad += v.distance_to(near)
		rad /= c.size()
		var lo := ca if ca.y < cb.y else cb
		var hi := cb if ca.y < cb.y else ca
		# только тросы этой стороны: нижний конец (угол трапеции) по знаку x
		if lo.x * sd > 0.05:
			out.append({"a": lo, "b": hi, "r": rad})


static func _uf_find(p: PackedInt32Array, i: int) -> int:
	while p[i] != i:
		p[i] = p[p[i]]
		i = p[i]
	return i


static func _rel(root: Node, node: Node3D) -> Transform3D:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x


func setup(cfg: Dictionary, wire_dir := Vector3.UP, wire_r := DEFAULT_WIRE_R) -> void:
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
	m.roughness = float(cfg.get("roughness", 0.35))
	var an := float(cfg.get("anisotropy", 0.0))
	if an > 0.0:  # атлас: узкий вытянутый блик поперёк нитей
		m.anisotropy_enabled = true
		m.anisotropy = an
	var e := float(cfg.get("emission_energy", 0.0))
	if e > 0.0:
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = e
	_mi.material_override = m
	add_child(_mi)
	_build_rows(cfg)
	_pts.resize(model.dirs.size() + 1)
	_build_ring(wire_dir, wire_r + float(cfg.get("ring_gap_m", 0.0015)), m)
	visible = false


## Сетка строк ленты вдоль сплайна: параметр u ∈ [0, n] (целая часть — номер звена цепочки), в
## последнем звене строк вдвое-втрое чаще — там рваный край; fl/fr — доля полуширины слева/справа.
func _build_rows(cfg: Dictionary) -> void:
	var n := model.dirs.size()
	var sub := maxi(int(cfg.get("subdiv", 4)), 1)
	var sub_last := sub * 3
	var fray := float(cfg.get("fray_len_m", 0.012)) / maxf(model.segment_m * n, 0.01) * n  # в u
	_u.clear()
	for k in n - 1:
		for j in sub:
			_u.append(k + float(j) / sub)
	for j in sub_last:
		_u.append(n - 1 + float(j) / sub_last)
	_u.append(float(n))
	var rows := _u.size()
	_fl.resize(rows)
	_fr.resize(rows)
	var first := rows
	for i in rows:
		_fl[i] = 1.0
		_fr[i] = 1.0
		if _u[i] >= n - fray and first == rows:
			first = i
	for i in range(first, rows):
		var q := i - first
		var ramp := minf(float(q + 1) / 3.0, 1.0)
		_fl[i] = lerpf(1.0, FRAY_L[q % FRAY_L.size()], ramp)
		_fr[i] = lerpf(1.0, FRAY_R[q % FRAY_R.size()], ramp)
	_fl[rows - 1] = 0.0
	_fr[rows - 1] = 0.0


## Узел-обмотка: короткое кольцо вокруг троса (ось — wire_dir), радиус чуть больше троса.
func _build_ring(axis: Vector3, radius: float, mat: Material) -> void:
	var ax := axis.normalized()
	var ref := Vector3.RIGHT if absf(ax.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var u := ax.cross(ref).normalized()
	var v := ax.cross(u)
	var half := _width * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 8
	for i in sides:
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var r0 := u * cos(a0) + v * sin(a0)
		var r1 := u * cos(a1) + v * sin(a1)
		var quad := [
			r0 * radius - ax * half, r1 * radius - ax * half,
			r1 * radius + ax * half, r0 * radius + ax * half,
		]
		var nrm := [r0, r1, r1, r0]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(nrm[k])
			st.add_vertex(quad[k])
	var ring := MeshInstance3D.new()
	ring.name = "Wrap"
	ring.mesh = st.commit()
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)


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
	var t := model.time_s
	# узлы цепочки в осях ноды (корень — на оси троса)
	var p := Vector3.ZERO
	for i in n + 1:
		_pts[i] = p
		if i < n:
			p += inv * model.dirs[i] * model.segment_m
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var tw_max := deg_to_rad(_twist_deg)
	for i in _u.size():
		var u := _u[i]
		var k := mini(int(u), n - 1)
		var f := u - k
		var p0 := _pts[maxi(k - 1, 0)]
		var p1 := _pts[k]
		var p2 := _pts[k + 1]
		var p3 := _pts[mini(k + 2, n)]
		var c1 := p2 - p0
		var c2 := 2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3
		var c3 := -p0 + 3.0 * p1 - 3.0 * p2 + p3
		var pos := p1 + 0.5 * (c1 * f + c2 * f * f + c3 * f * f * f)
		var d := 0.5 * (c1 + 2.0 * c2 * f + 3.0 * c3 * f * f)
		d = d.normalized() if d.length() > 1.0e-6 else (inv * model.dirs[k])
		var wd := d.cross(lat)
		wd = wd.normalized() if wd.length() > 1.0e-3 else d.cross(Vector3.RIGHT).normalized()
		wd = wd.rotated(d, tw_max * u / n * sin(t * 2.3 + u * 0.8 + side))
		var nrm := d.cross(wd).normalized()
		var half := wd * (_width * 0.5 * (1.0 - 0.25 * u / n))
		_mesh.surface_set_normal(nrm)
		_mesh.surface_set_tangent(Plane(d, 1.0))
		_mesh.surface_add_vertex(pos - half * _fl[i])
		_mesh.surface_set_normal(nrm)
		_mesh.surface_set_tangent(Plane(d, 1.0))
		_mesh.surface_add_vertex(pos + half * _fr[i])
	_mesh.surface_end()
