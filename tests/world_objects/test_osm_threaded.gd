extends TestCase
## FL-6: расчёт слоя OSM и домов посёлков — в рабочих потоках, на главном — только узлы и меши из готовых
## массивов; мир тот же. Перепись построенного (узлы, экземпляры MultiMesh, вершины мешей, препятствия по видам,
## хеши данных) на фикстуре Бохинь — Блед (3x3) и посёлках Онгудая сравнивается с эталоном, снятым со старого
## (синхронного) пути до правки.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=osm_threaded

const FIX := "res://tests/fixtures/osm_tiles"
const VILLAGES_ID := "ongudai"
## Эталон старого (синхронного) пути, снят до правки FL-6 (commit 0af63bd4): JSON переписи.
const OSM_BEFORE := '{"Buildings":{"h":449950129,"inst":80226,"nodes":2629,"verts":0},"Cabins":{"h":3466169479,"inst":20,"nodes":5,"verts":576},"CityTrees":{"h":124663825,"inst":0,"nodes":13,"verts":0},"Pilot":{"h":3234552717,"inst":2472,"nodes":1020,"verts":287405},"Roads":{"h":1153183074,"inst":0,"nodes":1153,"verts":616678},"Traffic":{"h":292925602,"inst":200,"nodes":4,"verts":0},"Wind":{"h":1319549637,"inst":24,"nodes":13,"verts":0},"building_obstacles":{"building":33628,"h":4268415557},"obstacles":{"h":830482026,"tower":2482,"wire":71880}}'
const VILLAGES_BEFORE := '{"Landing_ongudai_fields":{"h":2118426024,"inst":14,"nodes":3,"verts":3239},"StartGear_0":{"h":2673744465,"inst":34,"nodes":49,"verts":18933},"Tracks":{"h":1847392777,"inst":0,"nodes":2,"verts":212},"Villages":{"h":1339889249,"inst":24128,"nodes":295,"verts":0},"obstacles":{"gear":8,"h":2766950185,"tree":14},"streamer_1":{"h":661698943,"inst":0,"nodes":6,"verts":84},"streamer_2":{"h":1208753166,"inst":0,"nodes":6,"verts":84},"streamer_3":{"h":1212832599,"inst":0,"nodes":6,"verts":84},"streamer_4":{"h":701660549,"inst":0,"nodes":6,"verts":84},"village_obstacles":{"building":8464,"h":521660741},"windsock_0":{"h":683950314,"inst":0,"nodes":7,"verts":768},"windsock_5":{"h":2114370543,"inst":0,"nodes":7,"verts":768}}'


## Рельеф фикстуры: чистая функция (потокобезопасна).
static func _relief(x: float, z: float) -> float:
	return 500.0 + 60.0 * sin(x / 700.0) * cos(z / 900.0) + 0.01 * x


func _root() -> Node:
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	return tree_root.get_child(tree_root.get_child_count() - 1)


func _fixture_osm() -> OsmData:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "/fixture.json"))
	OsmTilesStage.cache_root_override = "user://test_osm_threaded/v1"
	LocationCache.remove_dir("user://test_osm_threaded")
	var ctx := LocationBuildContext.new()
	ctx.center_lat = float(fx.center_lat)
	ctx.center_lon = float(fx.center_lon)
	ctx.host = _root()
	ctx.dir = "user://test_osm_threaded/place"
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	var stage := OsmTilesStage.new()
	stage.cfg_override = {"base_url": ProjectSettings.globalize_path(FIX)}
	var err: int = await stage.run(ctx)
	check(err == OK, "стадия OK (%d)" % err)
	var d := OsmData.load_for(ctx.dir, ctx.center_lat, ctx.center_lon, 20000.0)
	OsmTilesStage.cache_root_override = ""
	LocationCache.remove_dir("user://test_osm_threaded")
	return d


## Перепись поддерева: {nodes, inst, verts, h}; h — хеш преобразований, буферов MultiMesh и массивов мешей.
static func census(n: Node) -> Dictionary:
	var c := {"nodes": 0, "inst": 0, "verts": 0, "h": 0}
	_walk(n, c)
	return c


static func _walk(n: Node, c: Dictionary) -> void:
	c.nodes += 1
	var h: int = c.h
	h = hash([h, n.get_class(), String(n.name) if not String(n.name).begins_with("@") else ""])
	if n is Node3D:
		h = hash([h, (n as Node3D).transform])
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		h = hash([h, g.visibility_range_begin, g.visibility_range_end, g.cast_shadow])
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
		var mm := (n as MultiMeshInstance3D).multimesh
		c.inst += mm.instance_count
		var xs: Array = []
		for i in mm.instance_count:
			xs.append(mm.get_instance_transform(i))
			if mm.use_colors:
				xs.append(mm.get_instance_color(i))
		h = hash([h, mm.instance_count, xs, mm.mesh.get_surface_count() if mm.mesh != null else -1])
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		var m := (n as MeshInstance3D).mesh as ArrayMesh
		for s in m.get_surface_count():
			var a := m.surface_get_arrays(s)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			c.verts += v.size()
			h = hash([h, v, a[Mesh.ARRAY_INDEX]])
	var items: Variant = n.get(&"items")
	if items is Array:
		h = hash([h, items])
	c.h = h
	for ch in n.get_children():
		_walk(ch, c)


## Препятствия по видам и хеш их фигур.
static func obstacle_census(o: ObstacleIndex) -> Dictionary:
	var kinds := {}
	if o == null:
		return kinds
	for k in o._kinds:
		kinds[k] = int(kinds.get(k, 0)) + 1
	kinds["h"] = hash([o._types, o._kinds, o._p0, o._p1, o._p2])
	return kinds


static func layer_census(layer: OsmLayer, obstacles: ObstacleIndex) -> Dictionary:
	var out := {}
	for ch in layer.get_children():
		out[String(ch.name)] = census(ch)
	out["obstacles"] = obstacle_census(obstacles)
	out["building_obstacles"] = obstacle_census(layer.building_obstacles)
	return out


func test_osm_layer_census() -> void:
	var d := await _fixture_osm()
	var cfg := WorldObjects.load_config()
	var obs := ObstacleIndex.new()
	var layer := OsmLayer.new()
	layer.build(d, cfg, _relief, obs)
	var got := layer_census(layer, obs)
	print("FL-6 перепись OSM: ", JSON.stringify(got))
	_same(got, OSM_BEFORE, "OSM")
	layer.free()


## Посёлки Онгудая (план PlaceData, FL-К2): дома, сады, препятствия-дома и общий индекс WorldObjects.
func test_villages_census() -> void:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location(VILLAGES_ID)
	var pd := PlaceData.for_terrain(t)
	var w := WorldObjects.new()
	w.build(
		VILLAGES_ID, t.get_start_sites(), t.get_landing_sites(), t.height_at, Callable(), t.latlon_to_local,
		Vector2(t.center_lat, t.center_lon), pd.patches, pd
	)
	var got := {}
	for ch in w.get_children():
		got[String(ch.name)] = census(ch)
	got["obstacles"] = obstacle_census(w.obstacles)
	got["village_obstacles"] = obstacle_census(w.village_layer.building_obstacles if w.village_layer != null else null)
	print("FL-6 перепись посёлков: ", JSON.stringify(got))
	_same(got, VILLAGES_BEFORE, "посёлки")
	w.free()
	t.free()


## Сравнение переписи с эталоном по построителям (числа из JSON — float).
func _same(got: Dictionary, before_json: String, label: String) -> void:
	var want: Dictionary = JSON.parse_string(before_json)
	var g: Dictionary = JSON.parse_string(JSON.stringify(got))
	for k in want:
		check(g.has(k), "%s: есть %s" % [label, k])
		if g.has(k):
			check(g[k] == want[k], "%s: %s как до правки: %s ≠ %s" % [label, k, g[k], want[k]])
	for k in g:
		check(want.has(k), "%s: лишний %s" % [label, k])
