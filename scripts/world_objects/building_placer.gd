class_name BuildingPlacer
extends RefCounted
## Дома (VR-6, VR-9, NO-2, OL-1): коробка стен реального размера + (у села) двускатная крыша-призма, по тайлам
## для MultiMesh. Стены уходят в землю ниже самой низкой точки пятна (на склоне не висят). Вид — стиль L2
## (BuildingStyle: город / село / промзона): цвета стен и крыш из палитры стиля с гарантированным контрастом,
## данные экземпляра для шейдера building.gdshader (альфа цвета), трубы и точки дыма у села (L3).
## Без нод: place() → {Vector2i тайл: {walls, wall_colors, roofs, roof_colors, chimneys,
## chimney_colors, smoke}}, попутно заносит коробки в ObstacleIndex (если передан).
## Запись дома — L1: [x, z, w, l, угол_град, высота_стен_м, крыша, (тип, по_правилу)]; крыша 0 — двускатная
## (только у села), 1 — плоская; у города и промзоны крыша всегда плоская. 7 полей — процедурный дом посёлка.
## Данные экземпляра стен — в альфе цвета (INSTANCE_COLOR.a·32 = стиль + 4 × стекло + 8 × индекс цвета плоской
## крыши; кратно 1/32 — точно в половинной точности); зерно разброса окон шейдер берёт из положения экземпляра.

const WALL_SHADER := preload("res://scripts/world_objects/osm/building.gdshader")


## style / glass — стиль и флаг фасада на запись (BuildingStyle.classify / adjust); пусто — стиль считается здесь
## (все записи 7-польные — всё село), стекла нет.
static func place(
	buildings: Array,
	cfg: Dictionary,
	height_fn: Callable,
	obstacles: ObstacleIndex = null,
	style: PackedByteArray = PackedByteArray(),
	glass: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var tile := float(cfg.tile_m)
	var sink := float(cfg.sink_m)
	var pitch := tan(deg_to_rad(float(cfg.roof_pitch_deg)))
	var scfg: Dictionary = cfg.style
	if style.size() != buildings.size():
		style = BuildingStyle.classify(buildings, scfg)
	var has_glass := glass.size() == buildings.size()
	var pals := _palettes(scfg)
	var min_c := float(scfg.get("min_roof_contrast", 0.08))
	var ccfg: Dictionary = cfg.get("chimney", {})
	var chim_frac := float(ccfg.get("fraction", 0.0))
	var csize: Array = ccfg.get("size_m", [0.5, 1.3, 0.5])
	var chim_col := WorldTiles.linear_color(ccfg.get("color", [0.36, 0.3, 0.28]))
	var smoke_frac := float(cfg.get("smoke", {}).get("fraction", 0.0))
	var out := {}
	var n := buildings.size()
	for i in n:
		var b: Array = buildings[i]
		var x: float = b[0]
		var z: float = b[1]
		var w: float = b[2]
		var l: float = b[3]
		var ang := deg_to_rad(b[4] as float)
		var ca := cos(ang)
		var sa := sin(ang)
		# Basis(UP, -ang): (px, pz) → (px·cos a − pz·sin a, px·sin a + pz·cos a); пять точек: центр и углы
		var hx := w * 0.5
		var hz := l * 0.5
		var ex := hx * ca - hz * sa
		var ez := hx * sa + hz * ca
		var fx := hx * ca + hz * sa
		var fz := hx * sa - hz * ca
		var g0 := height_fn.call(x, z) as float
		var g1 := height_fn.call(x - ex, z - ez) as float
		var g2 := height_fn.call(x + fx, z + fz) as float
		var g3 := height_fn.call(x + ex, z + ez) as float
		var g4 := height_fn.call(x - fx, z - fz) as float
		var gmin := minf(minf(g0, g1), minf(minf(g2, g3), g4))
		var gmax := maxf(maxf(g0, g1), maxf(maxf(g2, g3), g4))
		var rot := Basis(Vector3.UP, -ang)
		var base := gmin - sink
		var bh: float = b[5]
		var wall_h := bh + (gmax - gmin) + sink
		var tk := WorldTiles.key(x, z, tile)
		if not out.has(tk):
			out[tk] = {
				"walls": [] as Array[Transform3D],
				"wall_colors": PackedColorArray(),
				"roofs": [] as Array[Transform3D],
				"roof_colors": PackedColorArray(),
				"chimneys": [] as Array[Transform3D],
				"chimney_colors": PackedColorArray(),
				"smoke": PackedVector3Array(),
			}
		var t: Dictionary = out[tk]
		t.walls.append(
			Transform3D(
				rot * Basis.from_scale(Vector3(w, wall_h, l)), Vector3(x, base + wall_h * 0.5, z)
			)
		)
		var st: int = style[i]
		var pal: Dictionary = pals[st]
		var hh := ((i * 2654435761) + 12345) & 0xffffffff
		var h1 := hh >> 8
		var wl: PackedFloat32Array = pal.wall_l
		var wi: int = h1 % wl.size()
		var rl: PackedFloat32Array = pal.roof_l
		var nr := rl.size()
		var ri: int = (h1 >> 8) % nr
		for _k in nr:  # крыша другой яркости, чем стены этого дома (палитры не пересекаются, но проверяем)
			if absf(rl[ri] - wl[wi]) >= min_c:
				break
			ri = (ri + 1) % nr
		var gl := 1 if has_glass and glass[i] == 1 else 0
		var wc: Color = pal.walls[wi]
		wc.a = float(st + 4 * gl + 8 * ri) * 0.03125
		t.wall_colors.append(wc)
		var top := base + wall_h
		if st == BuildingStyle.VILLAGE and int(b[6]) == 0:
			var span := minf(w, l)
			var ridge := maxf(w, l)
			var rh := span * 0.5 * pitch
			var rb := rot
			if w >= l:
				rb = rot * Basis(Vector3.UP, PI * 0.5)
			t.roofs.append(
				Transform3D(
					rb * Basis.from_scale(Vector3(span, rh, ridge)), Vector3(x, top + rh * 0.5, z)
				)
			)
			t.roof_colors.append(pal.roofs[ri])
			# труба (L3): на скате у конька; дым — у доли домов с трубой; выбор по округлённым координатам
			var hc := ((roundi(x) * 73856093) ^ (roundi(z) * 19349663)) & 0x7fffffff
			if float(hc % 1000) * 0.001 < chim_frac:
				var side := 1.0 if (hc >> 10) & 1 == 0 else -1.0
				var lat := span * 0.18 * side
				var along := ridge * (float((hc >> 11) % 1000) * 0.001 - 0.5) * 0.5
				var lp: Vector3 = rb * Vector3(lat, 0.0, along)
				var surf := top + rh * (1.0 - 2.0 * absf(lat) / span)
				var ch := top + rh + float(csize[1]) - (surf - 0.3)
				var base_c := Vector3(x + lp.x, surf - 0.3 + ch * 0.5, z + lp.z)
				t.chimneys.append(
					Transform3D(rb * Basis.from_scale(Vector3(float(csize[0]), ch, float(csize[2]))), base_c)
				)
				t.chimney_colors.append(chim_col)
				if float((hc >> 4) % 1000) * 0.001 < smoke_frac:
					t.smoke.append(Vector3(base_c.x, surf - 0.3 + ch, base_c.z))
			top += rh
		if obstacles != null:
			obstacles.add_box(x, z, w * 0.5, l * 0.5, ang, base, top, "building")
	return out


## MultiMesh-узлы по тайлам (стены с шейдером стиля, крыши села, трубы) + узел дыма OsmSmoke (группа osm_wind).
## Общее для OsmBuildings и VillageLayer; корень без имени.
static func make_nodes(tiles: Dictionary, cfg: Dictionary) -> Node3D:
	var scfg: Dictionary = cfg.style
	var wall := BoxMesh.new()
	wall.material = wall_material(scfg)
	var vmat := StandardMaterial3D.new()
	vmat.vertex_color_use_as_albedo = true
	vmat.roughness = 0.9
	var roof := PrismMesh.new()
	roof.material = vmat
	var chim := BoxMesh.new()
	chim.material = vmat
	var tile := float(cfg.tile_m)
	var r := WorldTiles.tile_range(float(cfg.visibility_m), tile)
	var shadows := bool(cfg.cast_shadows)
	var root := Node3D.new()
	var smoke_pts := PackedVector3Array()
	for k in tiles:
		var t: Dictionary = tiles[k]
		var o := WorldTiles.center(k, tile)
		root.add_child(WorldTiles.multimesh_node(wall, t.walls, t.wall_colors, o, r, shadows))
		if not t.roofs.is_empty():
			root.add_child(WorldTiles.multimesh_node(roof, t.roofs, t.roof_colors, o, r, shadows))
		if not t.chimneys.is_empty():
			root.add_child(
				WorldTiles.multimesh_node(chim, t.chimneys, t.chimney_colors, o, r, false)
			)
		smoke_pts.append_array(t.smoke)
	if not smoke_pts.is_empty():
		var sm := OsmSmoke.new()
		sm.name = "Smoke"
		sm.setup(smoke_pts, cfg.get("smoke", {}))
		root.add_child(sm)
	return root


## Материал стен: шейдер building.gdshader с параметрами стиля.
static func wall_material(scfg: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = WALL_SHADER
	var pals := _palettes(scfg)
	var roofs := PackedColorArray()
	for s in 3:
		var rc: PackedColorArray = pals[s].roofs
		for k in 4:
			roofs.append(rc[k % rc.size()])
	m.set_shader_parameter(&"roof_pal", roofs)
	m.set_shader_parameter(&"floor_m", float(scfg.get("floor_m", 3.0)))
	m.set_shader_parameter(&"ground_dark", float(scfg.get("ground_dark", 0.45)))
	m.set_shader_parameter(&"ground_h_m", float(scfg.get("ground_dark_h_m", 1.0)))
	m.set_shader_parameter(&"window_fade_m", float(scfg.get("window_fade_m", 1100.0)))
	for k: String in ["window_dark", "window_light", "glass"]:
		if scfg.has(k):
			var c: Color = WorldTiles.linear_color(scfg[k])
			m.set_shader_parameter(StringName(k), Vector3(c.r, c.g, c.b))
	return m


## Палитры по стилю: [{walls, roofs (PackedColorArray, линейные), wall_l, roof_l (яркость)}] для CITY, VILLAGE, INDUSTRIAL.
static func _palettes(scfg: Dictionary) -> Array:
	var out := []
	for s in 3:
		var p := BuildingStyle.palette(scfg, s)
		var d := {
			"walls": PackedColorArray(),
			"roofs": PackedColorArray(),
			"wall_l": PackedFloat32Array(),
			"roof_l": PackedFloat32Array(),
		}
		for c: Array in p.get("wall_colors", [[0.7, 0.7, 0.7]]):
			d.walls.append(WorldTiles.linear_color(c))
			d.wall_l.append(BuildingStyle.luminance(c))
		for c: Array in p.get("roof_colors", [[0.3, 0.3, 0.3]]):
			d.roofs.append(WorldTiles.linear_color(c))
			d.roof_l.append(BuildingStyle.luminance(c))
		out.append(d)
	return out
