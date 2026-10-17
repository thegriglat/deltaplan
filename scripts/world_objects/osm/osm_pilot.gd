class_name OsmPilot
extends RefCounted
## Слой OSM «для пилота» (OT-10, контракт O9, docs/contracts/osm-tiles.md): вершины и перевалы с
## подписью «<имя> <высота> м» (общий помощник NameTag — как у ботов), ЛЭП (опоры + провода
## wire.gdshader), мачты/башни/трубы/ветряки, канатные дороги, аэродромы и ВПП. Опоры ЛЭП, столбы,
## мачты, телебашни и трубы — модели assets/models/osm (OL-2, контракт L5, MultiMesh по тайлам);
## ветряки и канатки — простые меши. Опоры и провода — препятствия (ObstacleIndex). Настройки — world_objects.json → osm_pilot.
## Данные места (OsmData), конфиг WorldObjects, высота рельефа height_fn(x, z) -> float и индекс
## препятствий (OsmLayer передаёт свой). Возвращает Node3D для OsmLayer или null, если строить нечего.

const WIRE_SHADER := preload("res://scripts/world_objects/wire.gdshader")
const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")

const MODEL_DIR := "res://assets/models/osm/"

## Кэш мешей моделей: имя → Mesh (null — файла нет, тогда конус).
static var _models: Dictionary = {}

## Сколько создано по видам (для тестов и замеров); заполняется последним build().
static var stats: Dictionary = {}


static func build(
	data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex
) -> Node3D:
	var prep := prepare(data, cfg, height_fn)
	if obstacles != null and prep.has("obstacles"):
		obstacles.merge(prep.obstacles)
	return OsmLayer.run_all(assemble(prep))


## Расчёт (FL-6): только данные — подписи, преобразования экземпляров, массивы лент проводов и ВПП, препятствия
## (свой ObstacleIndex). Без узлов и ресурсов — безопасно в рабочем потоке при потокобезопасной height_fn.
static func prepare(data: OsmData, cfg: Dictionary, height_fn: Callable) -> Dictionary:
	var pc: Dictionary = cfg.get("osm_pilot", {})
	if data == null or pc.is_empty() or not bool(pc.get("enabled", true)):
		return {}
	var p := {"pc": pc, "obstacles": ObstacleIndex.new(), "stats": {}}
	if bool(pc.peaks.enabled):
		p.peaks = _peaks_data(data, pc.peaks, height_fn, p.stats)
	if bool(pc.power.enabled) and not data.power.is_empty():
		p.power = _power_data(data.power, pc.power, height_fn, p.obstacles, p.stats)
	if bool(pc.verticals.enabled) and not data.verticals.is_empty():
		p.verticals = _verticals_data(data, pc.verticals, height_fn, p.obstacles, p.stats)
	if bool(pc.aerialways.enabled) and not data.aerialways.is_empty():
		p.aerialways = _aerialways_data(data.aerialways, pc.aerialways, height_fn, p.obstacles, p.stats)
	if bool(pc.aeroways.enabled) and not data.aeroways.is_empty():
		p.aeroways = _aeroways_data(data.aeroways, pc.aeroways, height_fn, p.stats)
	return p


## Сборка на главном потоке (FL-6): {root, steps} — корень и шаги, каждый добавляет немного узлов
## (OsmLayer.run_all — все сразу). stats — после сборки. Нечего строить — root null.
static func assemble(p: Dictionary) -> Dictionary:
	stats = {}
	if p.is_empty():
		return {"root": null, "steps": []}
	stats = (p.stats as Dictionary).duplicate()
	var pc: Dictionary = p.pc
	var root := Node3D.new()
	var steps: Array[Callable] = []
	if p.has("peaks") and not (p.peaks as Array).is_empty():
		steps.append(_peaks_node.bind(root, p.peaks, pc.peaks))
	if p.has("power"):
		_power_steps(root, p.power, pc.power, steps)
	if p.has("verticals"):
		_verticals_steps(root, p.verticals, pc.verticals, steps)
	if p.has("aerialways"):
		_aerialways_steps(root, p.aerialways, pc.aerialways, steps)
	if p.has("aeroways") and not (p.aeroways as Dictionary).is_empty():
		steps.append(_aeroways_node.bind(root, p.aeroways, pc.aeroways))
	if steps.is_empty():
		root.free()
		return {"root": null, "steps": []}
	return {"root": root, "steps": steps}


# --- вершины и перевалы -------------------------------------------------------------------------


static func _peaks_data(data: OsmData, pc: Dictionary, height_fn: Callable, st: Dictionary) -> Array:
	var items: Array = []
	var up := float(pc.height_m)
	var n_peaks := 0
	var n_passes := 0
	for pair: Array in [[data.peaks, false], [data.passes, true]]:
		for p: Dictionary in pair[0]:
			var text := NameTag.peak_text(String(p.name), float(p.ele))
			if text == "":
				continue
			var s := {
				"pos": Vector3(float(p.x), float(height_fn.call(float(p.x), float(p.z))) + up, float(p.z)),
				"text": text,
				"start": float(pc.pass_fade_start_m if pair[1] else pc.fade_start_m),
				"end": float(pc.pass_fade_end_m if pair[1] else pc.fade_end_m),
			}
			items.append(s)
			if pair[1]:
				n_passes += 1
			else:
				n_peaks += 1
	st["peak_labels"] = n_peaks
	st["pass_labels"] = n_passes
	return items


static func _peaks_node(root: Node3D, items: Array, pc: Dictionary) -> void:
	var labels := PeakLabels.new()
	labels.name = "PeakLabels"
	# вид — как у имён ботов, но включение отдельное: world_objects.json → osm_pilot.peaks.show
	labels.names_cfg = (Config.get_config("bots").get("names", {}) as Dictionary).duplicate()
	labels.show_labels = bool(pc.get("show", true))
	labels.update_s = float(pc.update_s)
	labels.items = items
	root.add_child(labels)


## Подписи вершин: один Label3D на подпись (NameTag.create), только вблизи дальности угасания.
## Обновляются раз в update_s (размер на экране зависит от поля зрения камеры).
class PeakLabels:
	extends Node3D

	var items: Array = []
	var names_cfg: Dictionary = {}
	## Показ подписей (настройка «Подписи вершин»); перечитывается из конфига каждые update_s
	var show_labels := true
	var update_s := 0.1
	var tags: Array[Label3D] = []
	var _t := 1.0e9

	func _ready() -> void:
		for it: Dictionary in items:
			var tag := NameTag.create()
			NameTag.apply_style(tag, names_cfg)
			tag.text = it.text
			add_child(tag)
			tags.append(tag)

	func _process(dt: float) -> void:
		_t += dt
		if _t < update_s:
			return
		_t = 0.0
		show_labels = bool(Config.value("world_objects", "osm_pilot.peaks.show", show_labels))
		refresh(get_viewport().get_camera_3d())

	## Обновить все подписи по камере; возвращает, сколько видно.
	func refresh(cam: Camera3D) -> int:
		var shown := 0
		var on := show_labels
		names_cfg["show"] = true
		for i in items.size():
			var tag := tags[i]
			if cam == null or not on:
				tag.visible = false
				continue
			var it: Dictionary = items[i]
			var d := cam.global_position.distance_to(it.pos)
			var f := NameTag.fade(d, float(it.start), float(it.end))
			NameTag.show_at(tag, cam, String(it.text), it.pos, names_cfg, f)
			if tag.visible:
				shown += 1
		return shown


# --- ЛЭП -----------------------------------------------------------------------------------------


static func _power_data(
	lines: Array, pc: Dictionary, height_fn: Callable, obstacles: ObstacleIndex, st: Dictionary
) -> Dictionary:
	var plan := PowerLinePlanner.plan(lines, pc, height_fn)
	var tile := float(pc.tile_m)
	var heights := {true: float(pc.tower_height_m), false: float(pc.pole_height_m)}
	var radii := {true: float(pc.tower_radius_m), false: float(pc.pole_radius_m)}
	var groups := {}
	for s: Dictionary in plan.supports:
		var p: Vector3 = s.position
		var tk := WorldTiles.key(p.x, p.z, tile)
		var key := "%d:%d:%d" % [int(s.tower), tk.x, tk.y]
		if not groups.has(key):
			groups[key] = {"tower": s.tower, "tile": tk, "t": [] as Array[Transform3D]}
		groups[key].t.append(Transform3D(Basis(Vector3.UP, float(s.yaw)), p))
		obstacles.add_cylinder(p.x, p.z, maxf(0.3, radii[s.tower]), p.y - 1.0, p.y + float(heights[s.tower]), "tower")
	var wires := _wire_data(plan.wires, pc, obstacles, st)
	st["supports"] = plan.supports.size()
	st["wires"] = plan.wires.size()
	return {"groups": groups, "wires": wires}


static func _power_steps(root: Node3D, d: Dictionary, pc: Dictionary, steps: Array[Callable]) -> void:
	var node := Node3D.new()
	node.name = "PowerLines"
	steps.append(root.add_child.bind(node))
	var tile := float(pc.tile_m)
	var r := WorldTiles.tile_range(float(pc.tower_visibility_m), tile)
	var meshes := {}
	steps.append(func() -> void:
		meshes[true] = model_mesh("power_tower", float(pc.tower_radius_m), float(pc.tower_height_m), pc.tower_color)
		meshes[false] = model_mesh("power_pole", float(pc.pole_radius_m), float(pc.pole_height_m), pc.pole_color))
	var groups: Dictionary = d.groups
	for key: String in groups:
		var g: Dictionary = groups[key]
		steps.append(func() -> void:
			node.add_child(WorldTiles.multimesh_node(meshes[g.tower], g.t, PackedColorArray(),
				WorldTiles.center(g.tile, tile), r, bool(pc.cast_shadows))))
	_wire_steps(node, d.wires, pc, steps)


## Провода лентами wire.gdshader (по тайлам wire_tile_m), каждый отрезок — капсула-препятствие: массивы по тайлам.
static func _wire_data(wires: Array, pc: Dictionary, obstacles: ObstacleIndex, st: Dictionary) -> Dictionary:
	var tile := float(pc.wire_tile_m)
	var hit_r := float(pc.wire_hit_radius_m)
	var acc := {}
	for w: PackedVector3Array in wires:
		var mid := w[w.size() / 2]
		var k := WorldTiles.key(mid.x, mid.z, tile)
		if not acc.has(k):
			acc[k] = {"v": PackedVector3Array(), "n": PackedVector3Array(),
				"uv": PackedVector2Array(), "i": PackedInt32Array()}
		var a: Dictionary = acc[k]
		var o := WorldTiles.center(k, tile)
		for j in w.size() - 1:
			obstacles.add_capsule(w[j], w[j + 1], hit_r, "wire")
			var t := (w[j + 1] - w[j]).normalized()
			var base: int = a.v.size()
			for p: Vector3 in [w[j], w[j + 1]]:
				for s: float in [-1.0, 1.0]:
					a.v.append(p - o)
					a.n.append(t)
					a.uv.append(Vector2(s, 0.0))
			a.i.append_array(PackedInt32Array([base, base + 1, base + 2, base + 1, base + 3, base + 2]))
	st["wire_tiles"] = st.get("wire_tiles", 0) + acc.size()
	return acc


static func _wire_steps(root: Node3D, acc: Dictionary, pc: Dictionary, steps: Array[Callable]) -> void:
	var tile := float(pc.wire_tile_m)
	var vis := float(pc.get("wire_visibility_m", pc.get("visibility_m", 500.0)))
	var mat := ShaderMaterial.new()
	mat.shader = WIRE_SHADER
	mat.set_shader_parameter(&"wire_color", _color3(pc.wire_color))
	mat.set_shader_parameter(&"wire_width_m", float(pc.wire_width_m))
	mat.set_shader_parameter(&"visibility_boost", float(pc.get("wire_visibility_boost", 1.5)))
	mat.set_shader_parameter(&"fade_start_m", vis * 0.6)
	mat.set_shader_parameter(&"fade_end_m", vis)
	for k: Vector2i in acc:
		var a: Dictionary = acc[k]
		steps.append(func() -> void:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = a.v
			arrays[Mesh.ARRAY_NORMAL] = a.n
			arrays[Mesh.ARRAY_TEX_UV] = a.uv
			arrays[Mesh.ARRAY_INDEX] = a.i
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = mat
			mi.position = WorldTiles.center(k, tile)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = WorldTiles.tile_range(vis, tile)
			# Провода тоньше пикселя — AABB расширяем на ширину ленты вдали.
			mi.extra_cull_margin = 2.0
			root.add_child(mi))


# --- мачты, башни, трубы, ветряки ----------------------------------------------------------------


const VERT_TILE := 4000.0


static func _verticals_data(
	data: OsmData, pc: Dictionary, height_fn: Callable, obstacles: ObstacleIndex, st: Dictionary
) -> Dictionary:
	var items: Array = data.verticals
	var landmarks := landmark_towers(items, data.peaks, data.buildings, pc)
	var tile := VERT_TILE
	var skip: Array = pc.get("skip", [])
	var groups := {}  # "модель:x:z" → {kind, tile, t}
	var n := 0
	for idx in items.size():
		var v: Dictionary = items[idx]
		var cls := String(v.t)
		if cls in skip:
			continue
		var h_tag := float(v.h)
		var h := h_tag if h_tag > 0.0 else float(pc.default_h_m[cls])
		var kind := vertical_model(cls, bool(v.get("comm", false)), h_tag, pc)
		if landmarks.has(idx):
			kind = "tv_tower"
			h = float(pc.landmark.default_h_m)
		var x := float(v.x)
		var z := float(v.z)
		var g := float(height_fn.call(x, z))
		var tk := WorldTiles.key(x, z, tile)
		var base := Vector3(x, g, z)
		var rad := float(pc.radius_m[kind])
		if kind == "wind":
			_group(groups, kind, tk).t.append(Transform3D(Basis.from_scale(Vector3(rad, h, rad)), base))
		else:
			var sc := model_scale(h, float(pc.model_h_m[kind]))
			var yaw := WorldTiles.hash01(int(x * 7.0) ^ int(z * 13.0)) * TAU
			_group(groups, kind, tk).t.append(Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(sc.x, sc.y, sc.x)), base))
			rad *= sc.x
		if kind == "tv_tower":
			for part: Array in pc.tv_tower_obstacle:
				var y0 := g + float(part[1]) * h if float(part[1]) > 0.0 else g - 1.0
				obstacles.add_cylinder(x, z, maxf(rad * float(part[0]), 0.5), y0, g + float(part[2]) * h, "tower")
		else:
			obstacles.add_cylinder(x, z, maxf(rad, 0.5), g - 1.0, g + h, "tower")
		if kind == "wind":
			var yaw := WorldTiles.hash01(int(x * 7.0) ^ int(z * 13.0)) * TAU
			var len := h * float(pc.blade_frac)
			var hub := base + Vector3.UP * h
			var face := Basis(Vector3.UP, yaw)
			var phase := WorldTiles.hash01(int(x) + int(z) * 31) * TAU
			for b in 3:
				var ang := phase + b * TAU / 3.0
				# лопасть в плоскости ротора (X-Y лица), от ступицы наружу
				var bas := face * Basis(Vector3.BACK, ang) * Basis.from_scale(Vector3(1, len, 1))
				_group(groups, "blade", tk).t.append(Transform3D(bas, hub + face * Vector3(0, 0, 2.5)))
		n += 1
	st["verticals"] = n
	return groups


static func _verticals_steps(root: Node3D, groups: Dictionary, pc: Dictionary, steps: Array[Callable]) -> void:
	var node := Node3D.new()
	node.name = "Verticals"
	steps.append(root.add_child.bind(node))
	var tile := VERT_TILE
	var r := WorldTiles.tile_range(float(pc.visibility_m), tile)
	var unit := {}  # модель → меш
	steps.append(func() -> void:
		for m: String in ["mast_lattice", "tv_tower", "chimney"]:
			unit[m] = model_mesh(m, float(pc.radius_m[m]), float(pc.model_h_m[m]), [0.6, 0.6, 0.6])
		unit["wind"] = _cone(1.0, 1.0, pc.color.wind, 0.6)
		unit["blade"] = _box_mesh(Vector3(0.5, 1.0, 0.2), pc.color.wind))
	for key: String in groups:
		var gr: Dictionary = groups[key]
		steps.append(func() -> void:
			node.add_child(WorldTiles.multimesh_node(unit[gr.kind], gr.t, PackedColorArray(),
				WorldTiles.center(gr.tile, tile), r, bool(pc.cast_shadows))))


## Модель по классу OSM (L5): mast → mast_lattice; tower → tv_tower при comm или высоте с тега
## не ниже tv_tower_min_h_m, иначе mast_lattice; chimney → chimney; wind — прежний конус (L6).
static func vertical_model(cls: String, comm: bool, h_tag: float, pc: Dictionary) -> String:
	match cls:
		"tower":
			# comm без высоты — обычно сотовая мачта; телебашня — только с высотой с тега
			return "tv_tower" if h_tag >= float(pc.tv_tower_min_h_m) else "mast_lattice"
		"mast":
			return "mast_lattice"
		"chimney":
			return "chimney"
	return cls


## Телебашни без высоты в OSM (Кок-Тобе и подобные): индексы verticals. Признак — mast/tower с comm и h = 0
## не дальше landmark.peak_r_m от именованной вершины (телебашни стоят на городской горе) и ≥ landmark.min_buildings
## домов в landmark.city_r_m (город внизу, не горная глушь); из группы ближе landmark.dedup_r_m — одна (ближайшая к вершине).
static func landmark_towers(items: Array, peaks: Array, buildings: Array, pc: Dictionary) -> Dictionary:
	var out := {}
	var lc: Dictionary = pc.get("landmark", {})
	if lc.is_empty() or not bool(lc.get("enabled", true)):
		return out
	var named: Array = []
	for p: Dictionary in peaks:
		if String(p.name) != "":
			named.append(Vector2(float(p.x), float(p.z)))
	if named.is_empty():
		return out
	var pr := float(lc.peak_r_m)
	var cand: Array = []  # [расстояние до вершины, индекс, позиция]
	for i in items.size():
		var v: Dictionary = items[i]
		if not bool(v.get("comm", false)) or float(v.h) > 0.0 or not (String(v.t) in ["mast", "tower"]):
			continue
		var q := Vector2(float(v.x), float(v.z))
		var best := INF
		for p: Vector2 in named:
			best = minf(best, p.distance_to(q))
		if best <= pr:
			cand.append([best, i, q])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var cr2 := float(lc.city_r_m) * float(lc.city_r_m)
	var taken: Array = []
	for c: Array in cand:
		var q: Vector2 = c[2]
		var near := false
		for t: Vector2 in taken:
			if t.distance_to(q) < float(lc.dedup_r_m):
				near = true
				break
		if near:
			continue
		var n := 0
		for b: Array in buildings:
			if Vector2(float(b[0]), float(b[1])).distance_squared_to(q) <= cr2:
				n += 1
				if n >= int(lc.min_buildings):
					break
		if n >= int(lc.min_buildings):
			out[c[1]] = true
			taken.append(q)
	return out


## Масштаб экземпляра модели высотой model_h под высоту h: x — по XZ, y — по Y (верх = h).
## По XZ мягче, чем по Y: clamp((h/model_h)^0.75, 0.35, 1) — след не шире radius_m модели.
static func model_scale(h: float, model_h: float) -> Vector2:
	var s := h / model_h
	return Vector2(clampf(pow(s, 0.75), 0.35, 1.0), s)


## Меш модели assets/models/osm/<name>.glb (первый MeshInstance3D); нет файла — конус-запасной.
static func model_mesh(name: String, radius: float, height: float, rgb: Array) -> Mesh:
	if not _models.has(name):
		_models[name] = _load_model(name)
	var m: Mesh = _models[name]
	return m if m != null else _cone(radius, height, rgb)


static func _load_model(name: String) -> Mesh:
	var path := MODEL_DIR + name + ".glb"
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate()
	var mesh: Mesh = null
	var stack: Array[Node] = [inst]
	while not stack.is_empty() and mesh == null:
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D:
			mesh = (nd as MeshInstance3D).mesh
		stack.append_array(nd.get_children())
	inst.free()
	return mesh


static func _group(groups: Dictionary, kind: String, tk: Vector2i) -> Dictionary:
	var key := "%s:%d:%d" % [kind, tk.x, tk.y]
	if not groups.has(key):
		groups[key] = {"kind": kind, "tile": tk, "t": [] as Array[Transform3D]}
	return groups[key]


# --- канатные дороги ------------------------------------------------------------------------------


static func _aerialways_data(
	items: Array, pc: Dictionary, height_fn: Callable, obstacles: ObstacleIndex, st: Dictionary
) -> Dictionary:
	var poles := {true: [] as Array[Transform3D], false: [] as Array[Transform3D]}
	var wires: Array[PackedVector3Array] = []
	var n_poles := 0
	for a: Dictionary in items:
		var lift: bool = String(a.t) in ["cable_car", "gondola", "chair_lift", "mixed_lift"]
		var ph := float(pc.lift_pole_height_m if lift else pc.tow_pole_height_m)
		var pts := PowerLinePlanner.support_points(a.p, float(pc.min_span_m), float(pc.max_span_m))
		if pts.size() < 2:
			continue
		var tops := PackedVector3Array()
		for q in pts:
			var g := float(height_fn.call(q.x, q.y))
			tops.append(Vector3(q.x, g + ph, q.y))
			(poles[lift] as Array[Transform3D]).append(
				Transform3D(Basis.from_scale(Vector3(1, 1, 1)), Vector3(q.x, g, q.y)))
			obstacles.add_cylinder(q.x, q.y, float(pc.pole_radius_m) + 0.1, g - 1.0, g + ph, "tower")
			n_poles += 1
		for i in tops.size() - 1:
			wires.append(PowerLinePlanner.catenary(tops[i], tops[i + 1], float(pc.sag_ratio), int(pc.wire_segments)))
	var wc := _aerial_wire_cfg(pc)
	var acc := _wire_data(wires, wc, obstacles, st)
	st["aerialway_poles"] = n_poles
	st["aerialway_wires"] = wires.size()
	return {"poles": poles, "wires": acc}


static func _aerial_wire_cfg(pc: Dictionary) -> Dictionary:
	return {"wire_tile_m": 400.0, "visibility_m": float(pc.visibility_m) * 0.1,
		"wire_width_m": pc.wire_width_m, "wire_color": [0.12, 0.12, 0.12],
		"wire_hit_radius_m": pc.wire_hit_radius_m}


static func _aerialways_steps(root: Node3D, d: Dictionary, pc: Dictionary, steps: Array[Callable]) -> void:
	var node := Node3D.new()
	node.name = "Aerialways"
	steps.append(root.add_child.bind(node))
	var poles: Dictionary = d.poles
	for lift: bool in poles:
		var list: Array[Transform3D] = poles[lift]
		if list.is_empty():
			continue
		var ph := float(pc.lift_pole_height_m if lift else pc.tow_pole_height_m)
		steps.append(func() -> void:
			var m := _cone(float(pc.pole_radius_m), ph, pc.pole_color)
			node.add_child(WorldTiles.multimesh_node(m, list, PackedColorArray(), Vector3.ZERO, 1.0e6, true)))
	_wire_steps(node, d.wires, _aerial_wire_cfg(pc), steps)


# --- аэродромы и ВПП ------------------------------------------------------------------------------


## Ленты и круги аэродромов одним буфером; пусто — {}.
static func _aeroways_data(items: Array, pc: Dictionary, height_fn: Callable, st: Dictionary) -> Dictionary:
	var buf := {"v": PackedVector3Array(), "c": PackedColorArray(), "uv": PackedVector2Array(),
		"i": PackedInt32Array()}
	var lift := float(pc.lift_m)
	var step := float(pc.step_m)
	var strips := 0
	var points := 0
	for a: Dictionary in items:
		var kind := String(a.kind)
		var t := String(a.t)
		if kind == "point":
			var p: Vector2 = (a.p as PackedVector2Array)[0]
			var rad := float(pc.point_radius_m.get(t, 15.0))
			_disc(buf, p, rad, height_fn, lift, _lin(pc.point_color))
			points += 1
		elif kind == "line":
			var runway := t == "runway"
			var w := float(pc.runway_width_m if runway else pc.strip_width_m)
			_ribbon(buf, a.p, w, step, height_fn, lift, _lin(pc.runway_color if runway else pc.strip_color), false)
			strips += 1
		else:
			_ribbon(buf, a.p, float(pc.outline_width_m), step, height_fn, lift, _lin(pc.outline_color), true)
			strips += 1
	if strips + points == 0:
		return {}
	st["aeroway_strips"] = strips
	st["aeroway_points"] = points
	return buf


static func _aeroways_node(root: Node3D, buf: Dictionary, pc: Dictionary) -> void:
	var node := Node3D.new()
	node.name = "Aeroways"
	root.add_child(node)
	var mat := ShaderMaterial.new()
	mat.shader = DRAPED_SHADER
	mat.set_shader_parameter(&"depth_pull", float(pc.depth_pull))
	mat.set_shader_parameter(&"depth_bias_m", float(pc.lift_m) * 2.0)
	mat.set_shader_parameter(&"edge_darken", 0.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = buf.v
	arrays[Mesh.ARRAY_COLOR] = buf.c
	arrays[Mesh.ARRAY_TEX_UV] = buf.uv
	arrays[Mesh.ARRAY_INDEX] = buf.i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = float(pc.visibility_m)
	mi.extra_cull_margin = 100.0
	node.add_child(mi)


static func _vert(buf: Dictionary, p: Vector2, height_fn: Callable, lift: float, col: Color, u: float) -> void:
	buf.v.append(Vector3(p.x, float(height_fn.call(p.x, p.y)) + lift, p.y))
	buf.c.append(col)
	buf.uv.append(Vector2(u, 0.0))


static func _ribbon(
	buf: Dictionary, pts: PackedVector2Array, width: float, step: float, height_fn: Callable,
	lift: float, col: Color, closed: bool
) -> void:
	var src := pts
	if closed and src.size() > 2 and src[0] != src[src.size() - 1]:
		src = src.duplicate()
		src.append(src[0])
	if src.size() < 2:
		return
	var dense := PackedVector2Array()
	for i in src.size() - 1:
		var seg := src[i + 1] - src[i]
		var n := maxi(1, ceili(seg.length() / step))
		for k in n:
			dense.append(src[i] + seg * (float(k) / n))
	dense.append(src[src.size() - 1])
	var first: int = buf.v.size()
	for i in dense.size():
		var d := dense[mini(i + 1, dense.size() - 1)] - dense[maxi(i - 1, 0)]
		d = d.normalized() if d.length() > 1.0e-4 else Vector2.RIGHT
		var nrm := Vector2(-d.y, d.x) * width * 0.5
		_vert(buf, dense[i] + nrm, height_fn, lift, col, 0.0)
		_vert(buf, dense[i] - nrm, height_fn, lift, col, 1.0)
		if i > 0:
			var b := first + 2 * (i - 1)
			buf.i.append_array(PackedInt32Array([b, b + 1, b + 2, b + 1, b + 3, b + 2]))


static func _disc(
	buf: Dictionary, c: Vector2, rad: float, height_fn: Callable, lift: float, col: Color
) -> void:
	var first: int = buf.v.size()
	_vert(buf, c, height_fn, lift, col, 0.5)
	var seg := 16
	for k in seg:
		var a := TAU * k / seg
		_vert(buf, c + Vector2(cos(a), sin(a)) * rad, height_fn, lift, col, 0.5)
	for k in seg:
		buf.i.append_array(PackedInt32Array([first, first + 1 + k, first + 1 + (k + 1) % seg]))


# --- меши и цвета ---------------------------------------------------------------------------------


## Усечённый конус (низ — radius, верх — 0,4·radius), основание в нуле, высота height.
static func _cone(radius: float, height: float, rgb: Array, top: float = 0.4) -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = radius * top
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 8
	m.rings = 1
	m.cap_bottom = false
	m.material = _mat(rgb)
	var arr := m.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i].y += height * 0.5
	arr[Mesh.ARRAY_VERTEX] = v
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	out.surface_set_material(0, m.material)
	return out


## Коробка 1×1×1·size, основание в нуле по Y, вытянута вверх (лопасть: от ступицы).
static func _box_mesh(size: Vector3, rgb: Array) -> Mesh:
	var m := BoxMesh.new()
	m.size = size
	var arr := m.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i].y += size.y * 0.5
	arr[Mesh.ARRAY_VERTEX] = v
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	out.surface_set_material(0, _mat(rgb))
	return out


static func _mat(rgb: Array) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color3(rgb)
	mat.roughness = 0.85
	return mat


static func _color3(rgb: Array) -> Color:
	return Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))


static func _lin(rgb: Array) -> Color:
	return WorldTiles.linear_color(rgb)
