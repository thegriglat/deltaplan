extends TestCase
## SLT-5: маска анимации паруса (UV2) читается шейдером без переворота V. Сборщик (build_gliders.py)
## пишет UV2.y = t (верх, 0 — передняя кромка) и t + 2 (низ); экспорт glTF переворачивает V, в Godot
## приходит 1 − y. По массивам меша Sail у всех моделей крыльев (configs/wings → visual.visual_model).


## Как в vertex() assets/shaders/sail/sail.gdshader: y = 1 − UV2.y; low = step(1.5, y); t = y − 2·low.
static func decode(uv2_y: float) -> Vector2:
	var y := 1.0 - uv2_y
	var low := 1.0 if y >= 1.5 else 0.0
	return Vector2(low, y - 2.0 * low)


func _models() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at("res://configs/wings"):
		if not f.ends_with(".json"):
			continue
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/wings/" + f))
		if d is Dictionary and d.has("visual") and d["visual"] is Dictionary and d["visual"].has("visual_model"):
			var p: String = d["visual"]["visual_model"]
			if p not in out:
				out.append(p)
	return out


func _sail_mesh(path: String) -> Mesh:
	var root := (load(path) as PackedScene).instantiate()
	var mi := root.find_child("Sail", true, false) as MeshInstance3D
	var mesh: Mesh = mi.mesh if mi != null else null
	root.free()
	return mesh


func _corr(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := a.size()
	if n < 3:
		return 0.0
	var ma := 0.0
	var mb := 0.0
	for i in n:
		ma += a[i]
		mb += b[i]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in n:
		sab += (a[i] - ma) * (b[i] - mb)
		saa += (a[i] - ma) * (a[i] - ma)
		sbb += (b[i] - mb) * (b[i] - mb)
	return sab / maxf(sqrt(saa * sbb), 1e-12)


## Корреляция t с положением по хорде (z нормирован в полосе по x), передняя кромка — минимальный z (−Z — нос).
func _chord_corr(verts: PackedVector3Array, ts: PackedFloat32Array, ids: PackedInt32Array) -> float:
	var zlo := {}
	var zhi := {}
	for i in ids:
		var k := roundi(verts[i].x * 10.0)
		zlo[k] = minf(zlo.get(k, INF), verts[i].z)
		zhi[k] = maxf(zhi.get(k, -INF), verts[i].z)
	var f := PackedFloat32Array()
	var t := PackedFloat32Array()
	for i in ids:
		var k := roundi(verts[i].x * 10.0)
		var span: float = zhi[k] - zlo[k]
		if span < 0.1:
			continue
		f.append((verts[i].z - zlo[k]) / span)
		t.append(ts[i])
	return _corr(f, t)


func test_uv2_decoding_all_models() -> void:
	var models := _models()
	check(models.size() >= 49, "моделей крыльев: %d" % models.size())
	var worst_frac := 0.0
	var worst_top := 1.0
	var worst_bot := 1.0
	for path in models:
		var mesh := _sail_mesh(path)
		check(mesh != null and mesh.get_surface_count() > 0, path + ": есть Sail")
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
		check(uv2.size() == verts.size(), path + ": UV2 есть")
		if uv2.size() != verts.size():
			continue
		var ts := PackedFloat32Array()
		ts.resize(verts.size())
		var n_low := 0
		for i in verts.size():
			var d := decode(uv2[i].y)
			ts[i] = d.y
			if d.x > 0.5:
				n_low += 1
		var bottom := SailMaterial.skin_indices(mesh, false)
		var top := SailMaterial.skin_indices(mesh, true)
		var frac_dec := float(n_low) / verts.size()
		var frac_skin := float(bottom.size()) / verts.size()
		worst_frac = maxf(worst_frac, absf(frac_dec - frac_skin))
		check(absf(frac_dec - frac_skin) <= 0.01, "%s: доля низа low=1 %.3f, по треугольникам %.3f" % [path, frac_dec, frac_skin])
		for i in top:
			if ts[i] < -0.01 or ts[i] > 1.01 or decode(uv2[i].y).x > 0.5:
				check(false, "%s: верх вне t ∈ [0,1] / low=0 (вершина %d, t=%.3f)" % [path, i, ts[i]])
				break
		for i in bottom:
			if ts[i] < -0.01 or ts[i] > 1.01 or decode(uv2[i].y).x < 0.5:
				check(false, "%s: низ вне t ∈ [0,1] / low=1 (вершина %d, t=%.3f)" % [path, i, ts[i]])
				break
		var ct := _chord_corr(verts, ts, top)
		var cb := _chord_corr(verts, ts, bottom)
		worst_top = minf(worst_top, ct)
		worst_bot = minf(worst_bot, cb)
		check(ct > 0.9, "%s: t верха растёт от передней кромки: corr=%.3f" % [path, ct])
		check(cb > 0.9, "%s: t низа растёт от передней кромки: corr=%.3f" % [path, cb])
	print("sail_uv2: моделей=%d, макс. расхождение доли низа=%.4f, мин. corr верх=%.3f низ=%.3f" % [models.size(), worst_frac, worst_top, worst_bot])
