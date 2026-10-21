extends TestCase
## Контракт TK-K2 (docs/contracts/trike-model.md): версия в заголовке; модель assets/models/trike/trike.glb.
## Размеры — из tools/blender/trike_params.json (Blender: x вправо, y вперёд, z вверх; Godot = (x, z, −y)).

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 2
const GLB := "res://assets/models/trike/trike.glb"
const PARAMS := "res://tools/blender/trike_params.json"
const BUDGET := {"Trike_LOD0": 4500, "Engine_LOD0": 1500, "Trike_LOD1": 1200, "Trike_LOD2": 250, "Prop_LOD0": 500, "Prop_LOD1": 80}


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TK-K\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TK-K2", 0) == VERSION, "TK-K2 (v%d) в заголовках: %s" % [VERSION, found])


func _params() -> Dictionary:
	var text := FileAccess.get_file_as_string(PARAMS)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(PARAMS))
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}


func _tris(mi: MeshInstance3D) -> int:
	var n := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return n


func _verts(mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mi.mesh.get_surface_count():
		out.append_array(mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	return out


func test_trike_model() -> void:
	var p := _params()
	check(not p.is_empty(), "trike_params.json читается")
	var ps := load(GLB) as PackedScene
	check(ps != null, "trike.glb грузится")
	if ps == null or p.is_empty():
		return
	var dims: Dictionary = p.dims
	var root := ps.instantiate()
	var nodes := {}
	for nm in ["Trike_LOD0", "Engine_LOD0", "Trike_LOD1", "Trike_LOD2", "Prop_LOD0", "Prop_LOD1"]:
		var mi := root.find_child(nm, true, false) as MeshInstance3D
		check(mi != null, "%s: MeshInstance3D" % nm)
		nodes[nm] = mi
		if mi != null:
			var t := _tris(mi)
			check(t > 0 and t <= BUDGET[nm], "%s: %d треугольников ≤ %d" % [nm, t, BUDGET[nm]])
	var prop := root.find_child("Propeller", true, false) as Node3D
	check(prop != null and not (prop is MeshInstance3D), "Propeller: Node3D")
	for nm in ["HangPoint", "WheelFront", "WheelRearL", "WheelRearR"]:
		var m := root.find_child(nm, true, false) as Node3D
		check(m != null, "маркер %s" % nm)
		nodes[nm] = m
	if nodes.has("Prop_LOD0") and prop != null:
		for nm in ["Prop_LOD0", "Prop_LOD1"]:
			check(nodes[nm] != null and nodes[nm].get_parent() == prop, "%s — ребёнок Propeller" % nm)
	var hang := nodes["HangPoint"] as Node3D
	if hang != null:
		check(_xf(hang, root).origin.length() < 1e-4, "HangPoint в начале координат")
	var gz := float(p.ground_z)
	var l0 := nodes["Trike_LOD0"] as MeshInstance3D
	if l0 != null:
		for lod in ["Trike_LOD0", "Trike_LOD1", "Trike_LOD2"]:
			var mi := nodes[lod] as MeshInstance3D
			if mi != null:
				var lo := 1e9
				for v in _verts(mi):
					lo = minf(lo, v.y)
				check(absf(lo - gz) <= 0.01, "низ %s y = %.3f, земля %.3f ± 1 см" % [lod, lo, gz])
	var wf := nodes["WheelFront"] as Node3D
	var wl := nodes["WheelRearL"] as Node3D
	var wr := nodes["WheelRearR"] as Node3D
	if wf != null and wl != null and wr != null:
		var wb := float(dims.wheelbase.value)
		var tr := float(dims.track.value)
		var wb_m := _xf(wf, root).origin.distance_to((_xf(wl, root).origin + _xf(wr, root).origin) * 0.5)
		var tr_m := _xf(wl, root).origin.distance_to(_xf(wr, root).origin)
		check(absf(wb_m - wb) <= 0.02 * wb, "колёсная база %.3f = %.3f ± 2 %%" % [wb_m, wb])
		check(absf(tr_m - tr) <= 0.02 * tr, "колея %.3f = %.3f ± 2 %%" % [tr_m, tr])
		check(absf(_xf(wf, root).origin.y - (gz + float(dims.wheel_front_d.value) / 2)) <= 0.01, "ось переднего колеса на радиус над землёй")
		check(absf(_xf(wl, root).origin.y - (gz + float(dims.wheel_rear_d.value) / 2)) <= 0.01, "ось заднего колеса на радиус над землёй")
		check(_xf(wf, root).origin.z < _xf(wl, root).origin.z, "переднее колесо впереди (−Z)")
	if prop != null:
		var pl0 := nodes["Prop_LOD0"] as MeshInstance3D
		if pl0 != null:
			var rmax := 0.0
			for v in _verts(pl0):
				var q := _xf(prop, root).affine_inverse() * (_xf(pl0, root) * v)
				rmax = maxf(rmax, Vector2(q.x, q.y).length())
			var pd := float(dims.prop_d.value)
			check(absf(rmax * 2.0 - pd) <= 0.02 * pd, "диаметр диска винта %.3f = %.3f ± 2 %%" % [rmax * 2.0, pd])
		var axis := _xf(prop, root).basis.z.normalized()
		var tilt := rad_to_deg(asin(clampf(-axis.y, -1.0, 1.0)))   # ось смотрит назад; нос вверх → ось вниз
		check(axis.z > 0.9, "ось винта направлена назад (+Z): %s" % axis)
		check(absf(tilt - float(dims.prop_tilt_deg.value)) <= 1.0, "наклон оси винта %.2f° = %.2f° ± 1°" % [tilt, float(dims.prop_tilt_deg.value)])
		check(absf(_xf(prop, root).origin.y - (gz + float(dims.prop_axis_height.value))) <= 0.02, "ось винта на высоте prop_axis_height")
	# анимация: один оборот линейно за prop_spin_period_s, цикл, ось — ось двигателя
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(ap != null and ap.has_animation("prop_spin"), "AnimationPlayer с prop_spin")
	if ap != null and ap.has_animation("prop_spin") and prop != null:
		var an := ap.get_animation("prop_spin")
		var period := float(dims.prop_spin_period_s.value)
		check(absf(an.length - period) <= 0.01, "prop_spin длиной %.2f с: %.3f" % [period, an.length])
		check(an.loop_mode == Animation.LOOP_LINEAR, "prop_spin — цикл")
		var found := -1
		for i in an.get_track_count():
			if an.track_get_type(i) == Animation.TYPE_ROTATION_3D and String(an.track_get_path(i)).ends_with("Propeller"):
				found = i
		check(found >= 0, "дорожка вращения Propeller")
		if found >= 0:
			var cw := bool(dims.prop_cw_from_behind.value)
			var qs: Array[Quaternion] = []
			for k in 4:
				qs.append(an.rotation_track_interpolate(found, an.length * k / 4.0))
			var total := 0.0
			for k in 4:
				var rel: Quaternion = qs[k].inverse() * qs[(k + 1) % 4]
				var ang := rad_to_deg(2.0 * acos(clampf(absf(rel.w), 0.0, 1.0)))
				total += ang
				var ax := rel.get_axis()
				var sgn := ax.z * (1.0 if rel.w >= 0.0 else -1.0)
				check(absf(ang - 90.0) <= 1.0, "шаг ¼ клипа %d: %.2f° = 90° ± 1°" % [k, ang])
				check(absf(absf(sgn) - 1.0) < 0.01, "спин вокруг локальной Z: %s" % ax)
				check((sgn < 0.0) == cw, "направление: prop_cw_from_behind = %s, ось %s" % [cw, ax])
			check(absf(total - 360.0) <= 2.0, "за клип %.1f° = 360°" % total)
			# линейно: середины между выборками тоже равномерны (1/8 клипа = 45°)
			var q_e: Quaternion = an.rotation_track_interpolate(found, an.length * 0.125)
			check(absf(rad_to_deg(2.0 * acos(clampf(absf((qs[0].inverse() * q_e).w), 0.0, 1.0))) - 45.0) <= 1.0, "без ускорения: 1/8 клипа = 45°")
	_check_v2(root, p, nodes)
	root.free()


## v2: двигатель отдельным мешем, винт, сиденья, бак.
func _check_v2(root: Node, p: Dictionary, nodes: Dictionary) -> void:
	var dims: Dictionary = p.dims
	var eng := nodes.get("Engine_LOD0") as MeshInstance3D
	if eng != null:
		var uvs := PackedVector2Array()
		var pos := PackedVector3Array()
		var idx := PackedInt32Array()
		for s in eng.mesh.get_surface_count():
			var arr := eng.mesh.surface_get_arrays(s)
			var off := uvs.size()
			var uv: Variant = arr[Mesh.ARRAY_TEX_UV]
			check(uv is PackedVector2Array and (uv as PackedVector2Array).size() == (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "Engine_LOD0: UV0 на каждой вершине")
			if uv is PackedVector2Array:
				uvs.append_array(uv)
			pos.append_array(arr[Mesh.ARRAY_VERTEX])
			for i in arr[Mesh.ARRAY_INDEX] as PackedInt32Array:
				idx.append(i + off)
		var inside := true
		for q in uvs:
			if q.x < -1e-4 or q.x > 1.0001 or q.y < -1e-4 or q.y > 1.0001:
				inside = false
		check(uvs.size() > 0 and inside, "Engine_LOD0: UV0 в [0, 1]")
		check(_uv_overlaps(uvs, idx) == 0, "Engine_LOD0: развёртка без наложений")
		# габарит двигателя ≈ engine_l/w/h (оценки в источниках ±20 %), цилиндры вверх: верх выше оси винта
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := Vector3(-1e9, -1e9, -1e9)
		for v in pos:
			lo = lo.min(v)
			hi = hi.max(v)
		var sz := hi - lo
		var el := float(dims.engine_l.value)
		var ew := float(dims.engine_w.value)
		var eh := float(dims.engine_h.value)
		check(absf(sz.z - el) <= 0.3 * el, "двигатель: длина %.2f ≈ %.2f ± 30 %%" % [sz.z, el])
		check(absf(sz.x - ew) <= 0.3 * ew, "двигатель: ширина %.2f ≈ %.2f ± 30 %%" % [sz.x, ew])
		check(absf(sz.y - eh) <= 0.3 * eh, "двигатель: высота %.2f ≈ %.2f ± 30 %%" % [sz.y, eh])
		check(hi.y > float(p.ground_z) + float(dims.prop_axis_height.value) + 0.1, "цилиндры вверх: верх двигателя %.2f над осью винта" % hi.y)
	# винт
	var prop := nodes.get("Propeller") as Node3D
	var pl0 := nodes.get("Prop_LOD0") as MeshInstance3D
	if prop == null:
		prop = root.find_child("Propeller", true, false) as Node3D
	if pl0 != null and prop != null:
		var inv := _xf(prop, root).affine_inverse()
		var R := float(dims.prop_d.value) / 2.0
		var pts := PackedVector3Array()
		for v in _verts(pl0):
			pts.append(inv * (_xf(pl0, root) * v))
		var angs: Array[float] = []
		for q in pts:
			if Vector2(q.x, q.y).length() > 0.5 * R:
				angs.append(fposmod(atan2(q.y, q.x), TAU))
		angs.sort()
		var clusters := 0
		for i in angs.size():
			var gap := (angs[(i + 1) % angs.size()] - angs[i]) if i + 1 < angs.size() else (angs[0] + TAU - angs[i])
			if gap > deg_to_rad(20.0):
				clusters += 1
		check(clusters == int(dims.prop_blades.value), "лопастей %d = prop_blades %d" % [clusters, int(dims.prop_blades.value)])
		for e in [[0.7 * R, float(dims.prop_chord_max.value), "0,7 R"], [R - 0.05, float(dims.prop_chord_tip.value), "начало закругления"]]:
			var sec: Array[Vector3] = []
			var a0 := -10.0
			for q in pts:
				if absf(Vector2(q.x, q.y).length() - float(e[0])) <= 0.02:
					var a := fposmod(atan2(q.y, q.x), TAU)
					if a0 < 0.0:
						a0 = a
					if absf(angle_difference(a, a0)) < 0.5:
						sec.append(q)
			var ch := 0.0
			for i in sec.size():
				for j in range(i + 1, sec.size()):
					ch = maxf(ch, sec[i].distance_to(sec[j]))
			check(sec.size() > 0 and absf(ch - float(e[1])) <= 0.1 * float(e[1]), "хорда у %s: %.3f = %.3f ± 10 %%" % [e[2], ch, float(e[1])])
		# материал: дерево под стеклотканью — полуглянец, без металла и прозрачности
		var ok_mat := false
		for s in pl0.mesh.get_surface_count():
			var m := pl0.mesh.surface_get_material(s) as BaseMaterial3D
			if m != null and m.roughness >= 0.4 and m.roughness <= 0.5 and m.metallic == 0.0 and m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				ok_mat = true
		check(ok_mat, "материал лопастей: roughness 0,4–0,5, metallic 0, без прозрачности")
	# сиденья: верх подушки у seat_pan; заднее выше переднего на rear_seat_rise
	var l0 := nodes.get("Trike_LOD0") as MeshInstance3D
	if l0 != null:
		var vs := _verts(l0)
		var tops := {}
		for key in ["seat", "seat_rear"]:
			var pan := _bl(p[key].seat_pan)
			var top := -1e9
			for v in vs:
				var b := Vector3(v.x, -v.z, v.y)               # в оси Blender
				if absf(b.x) < 0.1 and absf(b.y - pan.y) < 0.2 and b.z >= pan.z - 0.15 and b.z <= pan.z + 0.03:
					top = maxf(top, b.z)
			tops[key] = top
			check(absf(top - pan.z) <= 0.02, "%s: верх подушки %.3f = seat_pan %.3f ± 2 см" % [key, top, pan.z])
		var rise := float(dims.rear_seat_rise.value)
		check(absf(float(tops.seat_rear) - float(tops.seat) - rise) <= 0.02, "заднее сиденье выше переднего на %.3f ± 2 см (%.3f)" % [rise, float(tops.seat_rear) - float(tops.seat)])
		# бак: габарит вершин у tank.center ≈ tank.size
		var c := _bl(p.tank.center)
		var hs := Vector3(float(p.tank.size[0]), float(p.tank.size[1]), float(p.tank.size[2])) * 0.5
		var lo2 := Vector3(1e9, 1e9, 1e9)
		var hi2 := Vector3(-1e9, -1e9, -1e9)
		var cnt := 0
		for v in vs:
			var b := Vector3(v.x, -v.z, v.y)
			if absf(b.x - c.x) <= hs.x + 0.02 and absf(b.y - c.y) <= hs.y + 0.02 and absf(b.z - c.z) <= hs.z + 0.02:
				lo2 = lo2.min(b)
				hi2 = hi2.max(b)
				cnt += 1
		check(cnt >= 100, "бак: %d вершин в объёме tank" % cnt)
		check(_mx(((hi2 - lo2) - hs * 2.0).abs()) <= 0.06, "бак: габарит вершин %s = tank.size %s ± 6 см" % [hi2 - lo2, hs * 2.0])
		check(_mx(((hi2 + lo2) * 0.5 - c).abs()) <= 0.03, "бак: центр %s = tank.center %s ± 3 см" % [(hi2 + lo2) * 0.5, c])


func _mx(v: Vector3) -> float:
	return maxf(maxf(v.x, v.y), v.z)


func _bl(a: Variant) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Число треугольников развёртки, чей центр лежит внутри другого треугольника (наложения).
func _uv_overlaps(uvs: PackedVector2Array, idx: PackedInt32Array) -> int:
	var n := idx.size() / 3
	var bmin: Array[Vector2] = []
	var bmax: Array[Vector2] = []
	for t in n:
		var a := uvs[idx[t * 3]]
		var b := uvs[idx[t * 3 + 1]]
		var c := uvs[idx[t * 3 + 2]]
		bmin.append(a.min(b).min(c))
		bmax.append(a.max(b).max(c))
	var bad := 0
	for t in n:
		var a := uvs[idx[t * 3]]
		var b := uvs[idx[t * 3 + 1]]
		var c := uvs[idx[t * 3 + 2]]
		if absf((b - a).cross(c - a)) < 1e-9:
			continue                                           # вырожденный треугольник
		var m := (a + b + c) / 3.0
		for u in n:
			if u == t or m.x < bmin[u].x or m.x > bmax[u].x or m.y < bmin[u].y or m.y > bmax[u].y:
				continue
			var d := uvs[idx[u * 3]]
			var e := uvs[idx[u * 3 + 1]]
			var f := uvs[idx[u * 3 + 2]]
			var s1 := (e - d).cross(m - d)
			var s2 := (f - e).cross(m - e)
			var s3 := (d - f).cross(m - f)
			if (s1 > 1e-9 and s2 > 1e-9 and s3 > 1e-9) or (s1 < -1e-9 and s2 < -1e-9 and s3 < -1e-9):
				bad += 1
				break
	return bad


func _xf(n: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t
