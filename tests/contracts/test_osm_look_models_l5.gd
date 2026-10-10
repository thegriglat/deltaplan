extends TestCase
## Контракт L5 (docs/contracts/osm-look.md): модели опор ЛЭП, столба, мачты, телебашни и трубы
## assets/models/osm/*.glb — файлы, оси и начало, высота, след, бюджет треугольников/материалов/текстур,
## точки подвеса проводов, альфа-решётка (alpha scissor), правило модели OSM → класс, verticals.skip.

const DIR := "res://assets/models/osm/"
const NAMES := ["power_tower", "power_pole", "mast_lattice", "tv_tower", "chimney"]
const LATTICE := ["power_tower", "mast_lattice", "tv_tower"]
const MAX_TRIS := 600
const MAX_TRIS_TV := 1500  # L5 v2: телебашня по образцу Останкинской
const MAX_MATS := 2
const MAX_TEX := 1024
const FOOT_Y := 2.0  # «след» — сечение у земли, м

var _cfg: Dictionary


func _init() -> void:
	_cfg = WorldObjects.load_config().osm_pilot


## Вершины и индексы всех поверхностей + сам меш.
func _model(name: String) -> Dictionary:
	var ps := load(DIR + name + ".glb") as PackedScene
	if ps == null:
		return {}
	var inst := ps.instantiate()
	var mi: MeshInstance3D = null
	var stack: Array[Node] = [inst]
	while not stack.is_empty() and mi == null:
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D:
			mi = nd
		stack.append_array(nd.get_children())
	var out := {}
	if mi != null:
		var verts := PackedVector3Array()
		var tris := 0
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			verts.append_array(arr[Mesh.ARRAY_VERTEX])
			tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		out = {"mesh": mi.mesh, "verts": verts, "tris": tris, "xform": mi.transform, "mi": mi}
	inst.free()
	return out


func _expected_h(name: String) -> float:
	match name:
		"power_tower":
			return float(_cfg.power.tower_height_m)
		"power_pole":
			return float(_cfg.power.pole_height_m)
	return float(_cfg.verticals.model_h_m[name])


func _expected_r(name: String) -> float:
	match name:
		"power_tower":
			return float(_cfg.power.tower_radius_m)
		"power_pole":
			return float(_cfg.power.pole_radius_m)
	return float(_cfg.verticals.radius_m[name])


func test_files_budget_and_textures() -> void:
	for name: String in NAMES:
		var m := _model(name)
		check(not m.is_empty(), "%s: glb загружается" % name)
		if m.is_empty():
			continue
		check(int(m.tris) <= (MAX_TRIS_TV if name == "tv_tower" else MAX_TRIS) and int(m.tris) > 20, "%s: треугольников %d" % [name, m.tris])
		var mesh: Mesh = m.mesh
		check(mesh.get_surface_count() <= MAX_MATS, "%s: материалов %d ≤ %d" % [name, mesh.get_surface_count(), MAX_MATS])
		var scissor := false
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as BaseMaterial3D
			check(mat != null, "%s: материал %d" % [name, s])
			if mat == null:
				continue
			if mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				scissor = true
			check(mat.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA, "%s: не blend (тени, сортировка)" % name)
			if mat.albedo_texture != null:
				var sz := mat.albedo_texture.get_size()
				check(sz.x <= MAX_TEX and sz.y <= MAX_TEX, "%s: текстура %s ≤ %d" % [name, sz, MAX_TEX])
		if name in LATTICE:
			check(scissor, "%s: решётка — alpha scissor" % name)


func test_axes_height_and_footprint() -> void:
	for name: String in NAMES:
		var m := _model(name)
		if m.is_empty():
			continue
		check((m.xform as Transform3D).is_equal_approx(Transform3D.IDENTITY), "%s: без трансформации ноды" % name)
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := Vector3(-1e9, -1e9, -1e9)
		var foot := 0.0
		for v: Vector3 in m.verts:
			lo = lo.min(v)
			hi = hi.max(v)
			if v.y <= FOOT_Y:
				foot = maxf(foot, Vector2(v.x, v.z).length())
		var h := _expected_h(name)
		check(absf(lo.y) < 0.05, "%s: основание на y=0 (%.3f)" % [name, lo.y])
		var top := hi.y
		# столб: верх изолятора центрального провода выше столба на 0,15 м (в пределах 2 %)
		check(absf(top - h) <= 0.02 * h + 0.001, "%s: верх %.2f = %.2f ±2 %%" % [name, top, h])
		var cx := 0.5 * (lo.x + hi.x)
		var cz := 0.5 * (lo.z + hi.z)
		check(absf(cx) < 0.3 and absf(cz) < 0.3, "%s: начало — центр основания (%.2f, %.2f)" % [name, cx, cz])
		check(foot <= _expected_r(name) + 0.01, "%s: след %.2f ≤ radius_m %.2f" % [name, foot, _expected_r(name)])
		if name in ["mast_lattice", "tv_tower", "chimney"]:
			var r_all := 0.0
			for v: Vector3 in m.verts:
				r_all = maxf(r_all, Vector2(v.x, v.z).length())
			check(r_all <= _expected_r(name) + 0.01, "%s: весь контур %.2f ≤ radius_m" % [name, r_all])
		if name in ["power_tower", "power_pole"]:
			# траверсы поперёк линии: вдоль X шире, чем вдоль Z
			check(hi.x - lo.x > 2.0 * (hi.z - lo.z), "%s: траверсы вдоль X (X %.1f, Z %.1f)" % [name, hi.x - lo.x, hi.z - lo.z])


## Точки подвеса проводов: у модели есть вершина в каждой точке arms_m (±0,1 м по X и Y).
func test_attachment_points() -> void:
	for pair: Array in [["power_tower", "tower_arms_m"], ["power_pole", "pole_arms_m"]]:
		var m := _model(pair[0])
		if m.is_empty():
			continue
		for a: Array in _cfg.power[pair[1]]:
			var ok := false
			for v: Vector3 in m.verts:
				if absf(v.x - float(a[0])) <= 0.1 and absf(v.y - float(a[1])) <= 0.1:
					ok = true
					break
			check(ok, "%s: точка подвеса (%.1f, %.1f) есть в модели" % [pair[0], a[0], a[1]])


func test_class_to_model_rule() -> void:
	var pc: Dictionary = _cfg.verticals
	var min_h := float(pc.tv_tower_min_h_m)
	check(OsmPilot.vertical_model("mast", false, 0.0, pc) == "mast_lattice", "mast → mast_lattice")
	check(OsmPilot.vertical_model("chimney", false, 0.0, pc) == "chimney", "chimney → chimney")
	check(OsmPilot.vertical_model("tower", true, 0.0, pc) == "mast_lattice", "tower + comm без высоты → mast_lattice (сотовая)")
	check(OsmPilot.vertical_model("tower", true, 372.0, pc) == "tv_tower", "tower + comm высотой 372 → tv_tower")
	check(OsmPilot.vertical_model("tower", false, min_h, pc) == "tv_tower", "tower высотой ≥ порога → tv_tower")
	check(OsmPilot.vertical_model("tower", false, min_h - 1.0, pc) == "mast_lattice", "tower ниже порога → mast_lattice")
	var s := OsmPilot.model_scale(372.0, float(pc.model_h_m.tv_tower))
	check(absf(s.y * float(pc.model_h_m.tv_tower) - 372.0) < 0.01 and s.x <= 1.0 and s.x >= 0.35, "масштаб: верх = h, XZ ≤ 1: %s" % [s])


func test_skip_class() -> void:
	var d := OsmData.new()
	d.verticals = [
		{"t": "wind", "comm": false, "x": 500.0, "z": 500.0, "h": 90.0},
		{"t": "chimney", "comm": false, "x": 600.0, "z": 500.0, "h": 0.0},
		{"t": "tower", "comm": true, "x": 700.0, "z": 500.0, "h": 300.0},
	]
	var cfg := WorldObjects.load_config()
	cfg.osm_pilot.verticals.skip = []
	OsmPilot.build(d, cfg, func(_x: float, _z: float) -> float: return 0.0, ObstacleIndex.new())
	check(int(OsmPilot.stats.get("verticals", 0)) == 3, "без skip рисуются все: %s" % [OsmPilot.stats])
	cfg.osm_pilot.verticals.skip = ["wind"]
	var obs := ObstacleIndex.new()
	var node := OsmPilot.build(d, cfg, func(_x: float, _z: float) -> float: return 0.0, obs)
	check(int(OsmPilot.stats.get("verticals", 0)) == 2, "skip=[wind]: рисуются 2: %s" % [OsmPilot.stats])
	check(obs.hit(Vector3(500.0, 10.0, 480.0), Vector3(500.0, 10.0, 520.0)).is_empty(), "skip: ветряк не препятствие")
	check(not obs.hit(Vector3(600.0, 10.0, 480.0), Vector3(600.0, 10.0, 520.0)).is_empty(), "труба — препятствие")
	if node != null:
		node.free()
