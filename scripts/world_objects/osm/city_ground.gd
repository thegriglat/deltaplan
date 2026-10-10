class_name OsmCityGround
extends RefCounted
## Земля города (L8, OL-5): в городской застройке между домами — серо-бежевая подложка дворов с мягкими пятнами тона
## вместо зелёного поля рельефа; к краю города плавно уходит (дизеринг по альфе вершин, как у лент draped).
## Маска — доля площади под домами по клеткам cell_m (сетка плотности L2), сглаженная на fade_m, порог
## coverage_min: сёла и промзоны вне города остаются с травой. Слой — сетка с шагом vertex_m по рельефу,
## по тайлам tile_m, только там, где маска ненулевая; один материал, без текстур.
## Класс «застройка» WorldCover рельеф знает (built_color, built_soft), но только в местах с картой поверхности;
## маска по домам OSM работает везде, где есть тайлы, и совпадает с тем, что стоит на земле, — выбрана она.
## ЗАМЕНА: расчёт доли по клеткам (_coverage) — место для общего помощника BuildingStyle (OL-1, плотность клетки).

const SHADER := preload("res://scripts/world_objects/osm/city_ground.gdshader")


## Возвращает Node3D "CityGround" (в meta "stats") или null, если города нет.
static func build(data: OsmData, cfg: Dictionary, height_fn: Callable) -> Node3D:
	var gc: Dictionary = cfg.get("city_ground", {})
	if data == null or not bool(gc.get("enabled", true)) or data.buildings.size() < 50:
		return null
	var cell := float((cfg.get("buildings", {}).get("style", {}) as Dictionary).get("cell_m", gc.get("cell_m", 200.0)))
	var grid := _coverage(data.buildings, cell)
	if grid.is_empty():
		return null
	var cov_min := float(gc.get("coverage_min", 0.12))
	var iters := maxi(1, roundi(float(gc.get("fade_m", 250.0)) / cell))
	var f: PackedFloat32Array = grid.cov
	for i in iters:
		f = _blur(f, grid.nx, grid.nz)
	var step := float(gc.get("vertex_m", 40.0))
	var tile := float(gc.get("tile_m", 2000.0))
	var lift := float(gc.get("lift_m", 0.05))
	var x0: float = grid.x0
	var z0: float = grid.z0
	var nx: int = grid.nx
	var nz: int = grid.nz
	var spans := Vector2(nx * cell, nz * cell)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"depth_pull", float(cfg.get("roads", {}).get("depth_pull", 0.004)))
	mat.set_shader_parameter(&"depth_bias_m", float(gc.get("depth_bias_m", 0.12)))
	for k: String in ["ground_color", "yard_color"]:
		if gc.has(k):
			var a: Array = gc[k]
			mat.set_shader_parameter(StringName(k), Color(float(a[0]), float(a[1]), float(a[2])))
	for k: String in ["patch_m", "roughness"]:
		if gc.has(k):
			mat.set_shader_parameter(StringName(k), float(gc[k]))
	var root := Node3D.new()
	root.name = "CityGround"
	var vis := WorldTiles.tile_range(float(gc.get("visibility_m", 6000.0)), tile)
	var n_tiles := 0
	var n_verts := 0
	var tx0 := floori(x0 / tile)
	var tz0 := floori(z0 / tile)
	var tx1 := floori((x0 + spans.x) / tile)
	var tz1 := floori((z0 + spans.y) / tile)
	for tz in range(tz0, tz1 + 1):
		for tx in range(tx0, tx1 + 1):
			var m := _tile_mesh(Vector2i(tx, tz), tile, step, lift, f, grid, cell, cov_min, height_fn)
			if m == null:
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = m
			mi.material_override = mat
			mi.position = WorldTiles.center(Vector2i(tx, tz), tile)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = vis
			mi.visibility_range_end_margin = float(gc.get("fade_margin_m", 800.0))
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			root.add_child(mi)
			n_tiles += 1
			n_verts += (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if n_tiles == 0:
		root.free()
		return null
	root.set_meta(&"stats", {"tiles": n_tiles, "vertices": n_verts, "cells": nx * nz, "cell_m": cell})
	return root


## Доля площади под домами по клеткам cell_m: {cov: PackedFloat32Array (nx·nz), nx, nz, x0, z0}.
## Дом — запись OsmData.buildings: [x, z, полудлина, полуширина, ...]; площадь следа 4·w·l.
static func _coverage(buildings: Array, cell: float) -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for b: Array in buildings:
		mn.x = minf(mn.x, b[0])
		mn.y = minf(mn.y, b[1])
		mx.x = maxf(mx.x, b[0])
		mx.y = maxf(mx.y, b[1])
	if mn.x > mx.x:
		return {}
	var x0 := floorf(mn.x / cell) * cell - cell
	var z0 := floorf(mn.y / cell) * cell - cell
	var nx := int((mx.x - x0) / cell) + 3
	var nz := int((mx.y - z0) / cell) + 3
	var cov := PackedFloat32Array()
	cov.resize(nx * nz)
	var inv_a := 1.0 / (cell * cell)
	for b: Array in buildings:
		var ix := int((float(b[0]) - x0) / cell)
		var iz := int((float(b[1]) - z0) / cell)
		cov[iz * nx + ix] += 4.0 * float(b[2]) * float(b[3]) * inv_a
	return {"cov": cov, "nx": nx, "nz": nz, "x0": x0, "z0": z0}


## Сглаживание 3×3 (среднее).
static func _blur(f: PackedFloat32Array, nx: int, nz: int) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(f.size())
	for j in nz:
		for i in nx:
			var s := 0.0
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var a := i + di
					var c := j + dj
					if a >= 0 and a < nx and c >= 0 and c < nz:
						s += f[c * nx + a]
			o[j * nx + i] = s / 9.0
	return o


## Плотность в точке (билинейно по центрам клеток).
static func _sample(f: PackedFloat32Array, nx: int, nz: int, gx: float, gz: float) -> float:
	var fx := clampf(gx - 0.5, 0.0, nx - 1.001)
	var fz := clampf(gz - 0.5, 0.0, nz - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var a := lerpf(f[j * nx + i], f[j * nx + i + 1], tx)
	var b := lerpf(f[(j + 1) * nx + i], f[(j + 1) * nx + i + 1], tx)
	return lerpf(a, b, tz)


static func _tile_mesh(
	k: Vector2i, tile: float, step: float, lift: float, f: PackedFloat32Array, grid: Dictionary, cell: float,
	cov_min: float, height_fn: Callable
) -> ArrayMesh:
	var o := WorldTiles.center(k, tile)
	var n := int(round(tile / step))
	var x_a := o.x - tile * 0.5
	var z_a := o.z - tile * 0.5
	var nx: int = grid.nx
	var nz: int = grid.nz
	var alpha := PackedFloat32Array()
	alpha.resize((n + 1) * (n + 1))
	var any := false
	for j in n + 1:
		for i in n + 1:
			var wx := x_a + i * step
			var wz := z_a + j * step
			var d := _sample(f, nx, nz, (wx - float(grid.x0)) / cell, (wz - float(grid.z0)) / cell)
			var a := smoothstep(cov_min * 0.5, cov_min, d)
			alpha[j * (n + 1) + i] = a
			any = any or a > 0.0
	if not any:
		return null
	var v := PackedVector3Array()
	var norm := PackedVector3Array()
	var col := PackedColorArray()
	v.resize((n + 1) * (n + 1))
	norm.resize(v.size())
	col.resize(v.size())
	for j in n + 1:
		for i in n + 1:
			var q := j * (n + 1) + i
			var wx := x_a + i * step
			var wz := z_a + j * step
			v[q] = Vector3(wx - o.x, float(height_fn.call(wx, wz)) + lift, wz - o.z)
			norm[q] = Vector3.UP
			col[q] = Color(1, 1, 1, alpha[q])
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var q := j * (n + 1) + i
			if alpha[q] + alpha[q + 1] + alpha[q + n + 1] + alpha[q + n + 2] <= 0.0:
				continue
			idx.append_array(PackedInt32Array([q, q + 1, q + n + 1, q + 1, q + n + 2, q + n + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = norm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
