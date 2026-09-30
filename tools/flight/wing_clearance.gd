extends RefCounted
## Зазор крыла над рельефом на земле (SF-4, docs/flight.md → «Поза крыла на земле»).
##
## Берёт реальную модель крыла (GliderVisual: вершины всех сеток под нодой Wing, с трапецией),
## ставит её позой планера Transform3D(Telemetry.basis, FlightModel.position) — как Glider — и
## меряет высоту каждой вершины над рельефом по вертикали. Группы вершин (оси модели крыла от
## HangPoint, +X вправо, −Z вперёд, +Y вверх):
##   tips  — концы консолей (|x| > 0,6 полуразмаха), выше трапеции;
##   nose  — носовая часть киля (|x| < 1 м, z < 0), выше трапеции;
##   tail  — задняя часть киля (|x| < 1 м, z ≥ 0), выше трапеции;
##   frame — трапеция (ниже HangPoint больше чем на FRAME_BELOW_M).
## Используют тест tests/flight/test_wing_clearance.gd и таблица tools/flight/wing_clearance_run.gd.

const GLIDER_SCENE := preload("res://scenes/glider/glider.tscn")
const FRAME_BELOW_M := 0.3
const KEEL_HALF_WIDTH_M := 1.0
const TIP_FRACTION := 0.6
const GROUPS: Array[String] = ["tips", "nose", "tail", "frame"]


## Glider с визуалом в дереве parent, без своего шага физики (шагает зовущий).
static func make_glider(parent: Node, wing: String) -> Glider:
	var g: Glider = GLIDER_SCENE.instantiate()
	g.auto_start = Glider.AutoStart.NONE
	parent.add_child(g)
	g.setup(wing)
	g.set_physics_process(false)
	g.set_process(false)
	return g


## Вершины моделей крыла в осях визуала (начало — ступни), по группам: {группа: PackedVector3Array}.
static func wing_points(v: GliderVisual) -> Dictionary:
	var hang := Vector3(0, float(Config.get_config("flight").visual.hang_height_m), 0)
	var all := PackedVector3Array()
	for mi: MeshInstance3D in v.wing.find_children("*", "MeshInstance3D", true, false):
		var x := GliderVisual._relative_xform(v, mi)
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			for p: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				all.append(x * p)
	var half := 0.0
	for p in all:
		half = maxf(half, absf(p.x))
	var buf := {}  # группа → Array[Vector3] (Packed* — значения, append в словаре не сохранится)
	for gname in GROUPS:
		buf[gname] = []
	for p in all:
		var r := p - hang
		var gname := "frame"
		if r.y > -FRAME_BELOW_M:
			if absf(r.x) > TIP_FRACTION * half:
				gname = "tips"
			elif absf(r.x) < KEEL_HALF_WIDTH_M:
				gname = "nose" if r.z < 0.0 else "tail"
			else:
				continue
		(buf[gname] as Array).append(p)
	var out := {}
	for gname: String in buf:
		out[gname] = PackedVector3Array(buf[gname])
	return out


## Наименьший зазор каждой группы и общий (min) при позе xform над рельефом ground(x, z).
## {tips, nose, tail, frame, min: float, part: String — группа с наименьшим зазором}.
static func clearance(points: Dictionary, xform: Transform3D, ground: Callable) -> Dictionary:
	var res := {"min": INF, "part": ""}
	for gname: String in points:
		var lo := INF
		for p: Vector3 in points[gname]:
			var w := xform * p
			lo = minf(lo, w.y - float(ground.call(w.x, w.z)))
		res[gname] = lo
		if lo < res.min:
			res.min = lo
			res.part = gname
	return res


## Поза планера, как у Glider: Transform3D(basis, ступни); bank_override — крен вместо модельного.
static func pose(m: FlightModel, zero_bank: bool = false) -> Transform3D:
	var b := m.telemetry.basis
	if zero_bank:
		b = Basis.from_euler(Vector3(m.theta, -m.heading, 0.0))
	return Transform3D(b, m.position)


## Высота рельефа так, как её рисует сетка TerrainRenderer (LOD0): треугольники a-b-c и b-d-c
## клетки (диагональ b–c: (i+1, j) — (i, j+1)), линейно внутри треугольника. height_at — билинейно.
static func rendered_height(layer: HeightLayer, x: float, z: float) -> float:
	var fx := clampf((x - layer.origin_x) / layer.spacing, 0.0, layer.width - 1.0)
	var fz := clampf((z - layer.origin_z) / layer.spacing, 0.0, layer.height - 1.0)
	var i := mini(int(fx), layer.width - 2)
	var j := mini(int(fz), layer.height - 2)
	var tx := fx - i
	var tz := fz - j
	var k := j * layer.width + i
	var a := layer.heights[k]
	var b := layer.heights[k + 1]
	var c := layer.heights[k + layer.width]
	var d := layer.heights[k + layer.width + 1]
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


## Уклон рельефа в точке p по курсу (+ — вверх по курсу) и поперёк (+ — вверх вправо), градусы.
static func slopes(ground: Callable, p: Vector3, heading: float) -> Vector2:
	var fwd := Vector3(sin(heading), 0, -cos(heading))
	var right := Vector3(cos(heading), 0, sin(heading))
	var e := 2.0
	var hf := float(ground.call(p.x + fwd.x * e, p.z + fwd.z * e))
	var hb := float(ground.call(p.x - fwd.x * e, p.z - fwd.z * e))
	var hr := float(ground.call(p.x + right.x * e, p.z + right.z * e))
	var hl := float(ground.call(p.x - right.x * e, p.z - right.z * e))
	return Vector2(rad_to_deg(atan((hf - hb) / (2.0 * e))), rad_to_deg(atan((hr - hl) / (2.0 * e))))
