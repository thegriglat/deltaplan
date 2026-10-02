class_name OsmLayer
extends Node3D
## Отрисовка данных OSM (VR-6, VR-9, VR-10): дороги (ленты по рельефу), здания (MultiMesh),
## опоры ЛЭП (MultiMesh) и провода (wire.gdshader). Всё — тайлами с дальностью видимости.
## Реки и озёра не рисуются: вода уже в раскраске рельефа (terrain) — см. docs/guide/world-objects.md.
## Препятствия (здания, опоры, провода) заносятся в ObstacleIndex.

const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")
const WIRE_SHADER := preload("res://scripts/world_objects/wire.gdshader")

## Сколько узлов создано по видам (для тестов и замеров).
var stats: Dictionary = {}
var power_plan: Dictionary = {}

## Препятствия-здания (отдельный индекс: заполняется в фоновом потоке).
var building_obstacles: ObstacleIndex


## Дороги и здания считаются в пуле потоков параллельно с ЛЭП (чистые функции над height_fn),
## ноды создаются здесь же после ожидания — вызов синхронный, но ~вдвое быстрее.
func build(data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> void:
	var t0 := Time.get_ticks_usec()
	var road_tiles := {}
	var bld_tiles := {}
	building_obstacles = ObstacleIndex.new()
	var bidx := building_obstacles
	var tasks: Array[int] = []
	var do_roads := bool(cfg.roads.get("enabled", true))
	var do_bld := bool(cfg.buildings.get("enabled", true))
	var threaded := bool(cfg.get("threaded_build", true))
	var roads_job := func() -> void:
		road_tiles.merge(RoadMesher.build(data.roads, cfg.roads, height_fn))
	var bld_job := func() -> void:
		bld_tiles.merge(BuildingPlacer.place(data.buildings, cfg.buildings, height_fn, bidx))
	for job: Array in [[do_roads, roads_job], [do_bld, bld_job]]:
		if job[0]:
			if threaded:
				tasks.append(WorkerThreadPool.add_task(job[1], true))
			else:
				(job[1] as Callable).call()
	if bool(cfg.power.get("enabled", true)):
		_build_power(data.power, cfg.power, height_fn, obstacles)
	var t1 := Time.get_ticks_usec()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	var t2 := Time.get_ticks_usec()
	if do_roads:
		_add_roads(road_tiles, cfg.roads)
	if do_bld:
		_add_buildings(bld_tiles, cfg.buildings)
	stats["power_s"] = (t1 - t0) / 1.0e6
	stats["wait_threads_s"] = (t2 - t1) / 1.0e6
	stats["nodes_s"] = (Time.get_ticks_usec() - t2) / 1.0e6


## Заборы из OSM только у посадочных площадок (VR-12): пролёты модели забора вдоль ломаной,
## части ближе radius_m к центру площадки; каждый пролёт — препятствие.
func build_fences_near(
	fences: Array,
	centers: Array[Vector3],
	cfg: Dictionary,
	height_fn: Callable,
	obstacles: ObstacleIndex
) -> void:
	var radius := float(cfg.osm_fence_radius_m)
	var span := float(cfg.fence_span_m)
	var fh := float(cfg.fence_height_m)
	var tile := float(cfg.fence_tile_m)
	var tiles := {}  # Vector2i -> Array[Transform3D]
	var n := 0
	for f in fences:
		var pts := OsmData.points(f.p)
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var seg_len := a.distance_to(b)
			if seg_len < 0.1:
				continue
			var dir := (b - a) / seg_len
			var yaw := atan2(-dir.y, dir.x)
			for k in ceili(seg_len / span):
				var p := a + dir * span * k
				if not _near(p, centers, radius):
					continue
				var g := float(height_fn.call(p.x, p.y))
				var tk := WorldTiles.key(p.x, p.y, tile)
				if not tiles.has(tk):
					tiles[tk] = [] as Array[Transform3D]
				(tiles[tk] as Array[Transform3D]).append(
					Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, g, p.y))
				)
				n += 1
				var m := p + dir * minf(span, seg_len - span * k) * 0.5
				obstacles.add_box(
					m.x, m.y, span * 0.5, 0.1, atan2(dir.y, dir.x), g - 1.0, g + fh, "fence"
				)
	stats["osm_fence_spans"] = n
	stats["osm_fence_tiles"] = tiles.size()
	if tiles.is_empty():
		return
	# Пролёт забора ~1,4 м вдали тоньше пикселя: MultiMesh по тайлам с короткой дальностью
	# (дальность — от центра тайла, а не от первого пролёта: иначе дальние заборы пропадали).
	var mesh := WorldTiles.load_mesh(String(cfg.fence_scene_path), BoxMesh.new())
	var r := WorldTiles.tile_range(float(cfg.fence_visibility_m), tile)
	var root := Node3D.new()
	root.name = "OsmFences"
	add_child(root)
	for tk: Vector2i in tiles:
		root.add_child(
			WorldTiles.multimesh_node(
				mesh,
				tiles[tk],
				PackedColorArray(),
				WorldTiles.center(tk, tile),
				r,
				bool(cfg.cast_shadows)
			)
		)


static func _near(p: Vector2, centers: Array[Vector3], radius: float) -> bool:
	for c in centers:
		if Vector2(c.x, c.z).distance_to(p) <= radius:
			return true
	return false


func _add_roads(tiles: Dictionary, cfg: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = DRAPED_SHADER
	mat.set_shader_parameter(&"depth_pull", float(cfg.depth_pull))
	mat.set_shader_parameter(&"depth_bias_m", float(cfg.lift_m) * 2.0)
	var tile := float(cfg.tile_m)
	var root := Node3D.new()
	root.name = "Roads"
	add_child(root)
	for k in tiles:
		var t: Dictionary = tiles[k]
		var mi := MeshInstance3D.new()
		mi.mesh = t.mesh
		mi.material_override = mat
		mi.position = t.origin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var r := float(cfg.major_visibility_m if t.major else cfg.minor_visibility_m)
		mi.visibility_range_end = WorldTiles.tile_range(r, tile)
		root.add_child(mi)
	stats["road_tiles"] = tiles.size()


func _add_buildings(tiles: Dictionary, cfg: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	var wall := BoxMesh.new()
	wall.material = mat
	var roof := PrismMesh.new()
	roof.material = mat
	var tile := float(cfg.tile_m)
	var r := WorldTiles.tile_range(float(cfg.visibility_m), tile)
	var shadows := bool(cfg.cast_shadows)
	var root := Node3D.new()
	root.name = "Buildings"
	add_child(root)
	var n := 0
	for k in tiles:
		var t: Dictionary = tiles[k]
		var o := WorldTiles.center(k, tile)
		root.add_child(WorldTiles.multimesh_node(wall, t.walls, t.wall_colors, o, r, shadows))
		if not t.roofs.is_empty():
			root.add_child(WorldTiles.multimesh_node(roof, t.roofs, t.roof_colors, o, r, shadows))
		n += t.walls.size()
	stats["buildings"] = n
	stats["building_tiles"] = tiles.size()


func _build_power(
	lines: Array, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex
) -> void:
	power_plan = PowerLinePlanner.plan(lines, cfg, height_fn)
	var root := Node3D.new()
	root.name = "PowerLines"
	add_child(root)
	_build_supports(root, power_plan.supports, cfg, obstacles)
	_build_wires(root, power_plan.wires, cfg, obstacles)
	stats["supports"] = power_plan.supports.size()
	stats["wires"] = power_plan.wires.size()


func _build_supports(
	root: Node3D, supports: Array, cfg: Dictionary, obstacles: ObstacleIndex
) -> void:
	var tile := float(cfg.tile_m)
	var r := WorldTiles.tile_range(float(cfg.tower_visibility_m), tile)
	var meshes := {
		true: WorldTiles.load_mesh(String(cfg.tower_scene_path), _placeholder(0.8, 26.0)),
		false: WorldTiles.load_mesh(String(cfg.pole_scene_path), _placeholder(0.15, 9.0)),
	}
	var heights := {true: float(cfg.tower_height_m), false: float(cfg.pole_height_m)}
	var groups := {}
	for s in supports:
		var p: Vector3 = s.position
		var tk := WorldTiles.key(p.x, p.z, tile)
		var key := "%d:%d:%d" % [int(s.tower), tk.x, tk.y]
		if not groups.has(key):
			groups[key] = {"tower": s.tower, "tile": tk, "t": [] as Array[Transform3D]}
		groups[key].t.append(Transform3D(Basis(Vector3.UP, float(s.yaw)), p))
		var rad := 2.0 if s.tower else 0.3
		obstacles.add_cylinder(p.x, p.z, rad, p.y - 1.0, p.y + float(heights[s.tower]), "tower")
	for key in groups:
		var g: Dictionary = groups[key]
		var o := WorldTiles.center(g.tile, tile)
		root.add_child(
			WorldTiles.multimesh_node(
				meshes[g.tower], g.t, PackedColorArray(), o, r, bool(cfg.cast_shadows)
			)
		)


func _build_wires(root: Node3D, wires: Array, cfg: Dictionary, obstacles: ObstacleIndex) -> void:
	var tile := float(cfg.wire_tile_m)
	var vis := float(cfg.wire_visibility_m)
	var mat := ShaderMaterial.new()
	mat.shader = WIRE_SHADER
	mat.set_shader_parameter(&"wire_color", _color3(cfg.wire_color))
	mat.set_shader_parameter(&"wire_width_m", float(cfg.wire_width_m))
	mat.set_shader_parameter(&"visibility_boost", float(cfg.wire_visibility_boost))
	mat.set_shader_parameter(&"fade_start_m", vis * 0.6)
	mat.set_shader_parameter(&"fade_end_m", vis)
	var hit_r := float(cfg.wire_hit_radius_m)
	var acc := {}
	for w: PackedVector3Array in wires:
		var mid := w[w.size() / 2]
		var k := WorldTiles.key(mid.x, mid.z, tile)
		if not acc.has(k):
			acc[k] = {
				"v": PackedVector3Array(),
				"n": PackedVector3Array(),
				"uv": PackedVector2Array(),
				"i": PackedInt32Array()
			}
		var a: Dictionary = acc[k]
		var o := WorldTiles.center(k, tile)
		for j in w.size() - 1:
			obstacles.add_capsule(w[j], w[j + 1], hit_r, "wire")
			var t := (w[j + 1] - w[j]).normalized()
			var base: int = a.v.size()
			for p in [w[j], w[j + 1]]:
				for s in [-1.0, 1.0]:
					a.v.append(p - o)
					a.n.append(t)
					a.uv.append(Vector2(s, 0.0))
			a.i.append_array(
				PackedInt32Array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
			)
	for k in acc:
		var a: Dictionary = acc[k]
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
		root.add_child(mi)
	stats["wire_tiles"] = acc.size()


static func _color3(rgb: Array) -> Color:
	return Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))


static func _placeholder(radius: float, height: float) -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = radius * 0.4
	m.bottom_radius = radius
	m.height = height
	return m
