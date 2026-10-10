class_name BuildingPlacer
extends RefCounted
## Дома посёлков (VR-6, VR-9, NO-2): коробка стен реального размера + двускатная крыша (призма),
## по тайлам для MultiMesh. Стены уходят в землю ниже самой низкой точки пятна (на склоне не висят).
## Без нод: place() → {Vector2i тайл: {walls: [Transform3D], wall_colors, roofs, roof_colors}},
## попутно заносит коробки в ObstacleIndex (если передан).
## Формат записи дома (VillagePlacer, N3): [x, z, w, l, угол_град, высота_стен_м, крыша],
## крыша: 0 — двускатная, 1 — плоская.


static func place(
	buildings: Array, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex = null
) -> Dictionary:
	var tile := float(cfg.tile_m)
	var sink := float(cfg.sink_m)
	var pitch := tan(deg_to_rad(float(cfg.roof_pitch_deg)))
	var walls_c: Array = cfg.wall_colors
	var roofs_c: Array = cfg.roof_colors
	var out := {}
	for i in buildings.size():
		var b: Array = buildings[i]
		var x := float(b[0])
		var z := float(b[1])
		var w := float(b[2])
		var l := float(b[3])
		var ang := deg_to_rad(float(b[4]))
		var rot := Basis(Vector3.UP, -ang)
		var gmin := INF
		var gmax := -INF
		for c in [Vector2.ZERO, Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var p: Vector3 = rot * Vector3(c.x * w * 0.5, 0.0, c.y * l * 0.5)
			var g := float(height_fn.call(x + p.x, z + p.z))
			gmin = minf(gmin, g)
			gmax = maxf(gmax, g)
		var base := gmin - sink
		var wall_h := float(b[5]) + (gmax - gmin) + sink
		var tk := WorldTiles.key(x, z, tile)
		if not out.has(tk):
			out[tk] = {
				"walls": [] as Array[Transform3D],
				"wall_colors": PackedColorArray(),
				"roofs": [] as Array[Transform3D],
				"roof_colors": PackedColorArray(),
			}
		var t: Dictionary = out[tk]
		t.walls.append(
			Transform3D(
				rot * Basis.from_scale(Vector3(w, wall_h, l)), Vector3(x, base + wall_h * 0.5, z)
			)
		)
		var wc := int(WorldTiles.hash01(i * 7 + 3) * walls_c.size()) % walls_c.size()
		t.wall_colors.append(WorldTiles.linear_color(walls_c[wc]))
		var top := base + wall_h
		if int(b[6]) == 0:
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
			var rc := int(WorldTiles.hash01(i) * roofs_c.size()) % roofs_c.size()
			t.roof_colors.append(WorldTiles.linear_color(roofs_c[rc]))
			top += rh
		if obstacles != null:
			obstacles.add_box(x, z, w * 0.5, l * 0.5, ang, base, top, "building")
	return out
