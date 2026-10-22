extends TestCase
## Контракт TK-K2 (docs/contracts/trike-model.md): версия в заголовке; модель assets/models/trike/trike.glb.
## Размеры — из tools/blender/trike_params.json (Blender: x вправо, y вперёд, z вверх; Godot = (x, z, −y)).

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 4
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
	_check_v3(root, p, nodes)
	_check_v4(root, p, nodes)
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
		# габарит самого двигателя — без выхлопа (резонатор, глушитель: свои размеры, проверка v3)
		var ecv := _verts_cols(eng)
		for i in (ecv[0] as PackedVector3Array).size():
			var cc: Color = (ecv[1] as PackedColorArray)[i]
			var v: Vector3 = (ecv[0] as PackedVector3Array)[i]
			if _col_is(cc, 0.133, 0.119, 0.1, 0.02) or (_col_is(cc, 0.26, 0.27, 0.29, 0.03) and v.y < float(p.ground_z) + float(dims.prop_axis_height.value) - 0.15):
				continue
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


## Цвет вершины (линейный) близок к (r, g, b) ± tol.
func _col_is(c: Color, r: float, g: float, b: float, tol: float) -> bool:
	return absf(c.r - r) <= tol and absf(c.g - g) <= tol and absf(c.b - b) <= tol


## Вершины и цвета меша (все поверхности).
func _verts_cols(mi: MeshInstance3D) -> Array:
	var vs := PackedVector3Array()
	var cs := PackedColorArray()
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		vs.append_array(arr[Mesh.ARRAY_VERTEX])
		var c: Variant = arr[Mesh.ARRAY_COLOR]
		if c is PackedColorArray and (c as PackedColorArray).size() == (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			cs.append_array(c)
		else:
			for i in (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
				cs.append(Color(0, 0, 0))
	return [vs, cs]


## v3: трубы 60 мм, бак над килем, пружины-спирали, резонатор и глушитель.
func _check_v3(root: Node, p: Dictionary, nodes: Dictionary) -> void:
	var dims: Dictionary = p.dims
	var l0 := nodes.get("Trike_LOD0") as MeshInstance3D
	if l0 == null:
		return
	var vs := _verts(l0)
	var bl := PackedVector3Array()
	for v in vs:
		bl.append(Vector3(v.x, -v.z, v.y))
	# киль: вершины на оси x≈0 между сиденьями (без отводов): диаметр по z
	var klo := 1e9
	var khi := -1e9
	for b in bl:
		if absf(b.x) < 0.04 and b.y > 0.65 and b.y < 0.75 and b.z < -2.0 and b.z > -2.25:
			klo = minf(klo, b.z)
			khi = maxf(khi, b.z)
	var dk := float(dims.tube_keel_d.value)
	check(khi > klo and absf((khi - klo) - dk) <= 0.05 * dk, "киль: диаметр %.4f = %.3f ± 5 %%" % [khi - klo, dk])
	# мачта: ширина по x на высоте z∈[−1.0, −0.9] вокруг оси x≈0 (без сидений, двигателя)
	var mlo := 1e9
	var mhi := -1e9
	for b in bl:
		if absf(b.x) < 0.045 and b.z > -2.2 and b.z < -2.05 and absf(b.y + tan(deg_to_rad(float(dims.mast_tilt_deg.value))) * 2.12) < 0.03:
			mlo = minf(mlo, b.x)
			mhi = maxf(mhi, b.x)
	var dm := float(dims.tube_mast_d.value)
	check(mhi > mlo and absf((mhi - mlo) - dm) <= 0.05 * dm, "мачта: диаметр %.4f = %.3f ± 5 %%" % [mhi - mlo, dm])
	# ниже низа киля — только колёса, их вилка и стойки шасси (по бокам |x| > 0,16 или у переднего колеса)
	var yf := float(dims.axle_front_y.value)
	var below := 0
	var lowest := 0.0
	for b in bl:
		if b.z < klo - 0.005 and absf(b.x) <= 0.16 and absf(b.y - yf) > 0.4:
			below += 1
			lowest = minf(lowest, b.z)
	check(below == 0, "ниже низа киля %.3f вне колёс и шасси вершин: %d (до z %.3f)" % [klo, below, lowest])
	# бак: низ выше верха киля на ≥ keel_clear − 0,5 см
	var c := _bl(p.tank.center)
	var hs := Vector3(float(p.tank.size[0]), float(p.tank.size[1]), float(p.tank.size[2])) * 0.5
	var tlo := 1e9
	for b in bl:
		if absf(b.x - c.x) <= hs.x + 0.01 and absf(b.y - c.y) <= hs.y + 0.01 and absf(b.z - c.z) <= hs.z + 0.01 and b.z < c.z:
			tlo = minf(tlo, b.z)
	check(khi > klo and tlo - khi >= float(p.tank.keel_clear) - 0.005, "бак: низ %.3f над верхом киля %.3f на %.3f ≥ keel_clear %.3f − 0,005" % [tlo, khi, tlo - khi, float(p.tank.keel_clear)])
	# горловина — вертикальная, на верху бака: вершины над верхом бака вокруг filler
	var f := _bl(p.tank.filler)
	var fhi := -1e9
	var fx_lo := 1e9
	var fx_hi := -1e9
	for b in bl:
		if Vector2(b.x - f.x, b.y - f.y).length() < 0.06 and b.z > c.z + hs.z + 0.003:
			fhi = maxf(fhi, b.z)
			fx_lo = minf(fx_lo, b.x)
			fx_hi = maxf(fx_hi, b.x)
	check(fhi > c.z + hs.z + 0.015 and fx_hi - fx_lo < 0.1, "горловина вертикально над баком: высота +%.3f, ширина %.3f" % [fhi - c.z - hs.z, fx_hi - fx_lo])
	# пружины: жёлтые вершины вдоль амортизатора, >= 5 витков по развёртке угла вокруг оси
	var vc := _verts_cols(l0)
	var cols: PackedColorArray = vc[1]
	var tilt := deg_to_rad(float(dims.mast_tilt_deg.value))
	var kz := -2.12
	var mb_y := -tan(tilt) * (-kz)
	var m_pt := Vector3(0, mb_y * -1.62 / kz, -1.62)
	for s in [-1, 1]:
		var h := Vector3(s * (float(dims.track.value) / 2.0 - float(dims.tire_rear_w.value) / 2.0 - 0.02), float(dims.axle_rear_y.value), float(p.ground_z) + float(dims.wheel_rear_d.value) / 2.0 + 0.03)
		var ax := (h - m_pt).normalized()
		var u := ax.cross(Vector3.RIGHT if absf(ax.x) < 0.9 else Vector3.UP).normalized()
		var w := ax.cross(u)
		var pts: Array = []
		for i in bl.size():
			var cc := cols[i]
			if cc.r > cc.g * 1.2 and cc.g > cc.b * 5.0 and cc.r > 0.3 and bl[i].x * s > 0.0:
				var d := bl[i] - m_pt
				var t := d.dot(ax)
				var rad := (d - ax * t).length()
				if rad < 0.06:
					pts.append([t, atan2(d.dot(w), d.dot(u))])
		pts.sort_custom(func(a, b): return a[0] < b[0])
		var turns := 0.0
		for i in range(1, pts.size()):
			var dth := wrapf(pts[i][1] - pts[i - 1][1], -PI, PI)
			turns += dth
		check(pts.size() >= 20 and absf(turns) / TAU >= 5.0, "пружина %d: %d вершин, %.1f витков ≥ 5" % [s, pts.size(), absf(turns) / TAU])
	# резонансная труба и глушитель: габарит в осях винта (z — вдоль оси двигателя)
	var eng := nodes.get("Engine_LOD0") as MeshInstance3D
	var prop := root.find_child("Propeller", true, false) as Node3D
	if eng != null and prop != null:
		var ec := _verts_cols(eng)
		var inv := _xf(prop, root).affine_inverse()
		var res_lo := Vector3(1e9, 1e9, 1e9)
		var res_hi := Vector3(-1e9, -1e9, -1e9)
		var mu_lo := res_lo
		var mu_hi := res_hi
		for i in (ec[0] as PackedVector3Array).size():
			var cc: Color = (ec[1] as PackedColorArray)[i]
			if not _col_is(cc, 0.133, 0.119, 0.1, 0.02):
				continue
			var q: Vector3 = inv * (_xf(eng, root) * (ec[0] as PackedVector3Array)[i])
			if q.y < -0.22:
				mu_lo = mu_lo.min(q)
				mu_hi = mu_hi.max(q)
			elif q.y >= -0.22 and q.y < -0.045 and q.x < -0.1:
				res_lo = res_lo.min(q)
				res_hi = res_hi.max(q)
		var rs := res_hi - res_lo
		var ms := mu_hi - mu_lo
		var ed := float(dims.engine_exhaust_d.value)
		var el := float(dims.engine_exhaust_l.value)
		var md := float(dims.muffler_d.value)
		var ml := float(dims.muffler_l.value)
		check(absf(rs.z - el) <= 0.15 * el, "резонансная труба: длина %.3f = %.2f ± 15 %%" % [rs.z, el])
		check(absf(rs.y - ed) <= 0.15 * ed, "резонансная труба: диаметр %.3f = %.2f ± 15 %%" % [rs.y, ed])
		check(absf(ms.z - ml) <= 0.15 * ml, "глушитель: длина %.3f = %.2f ± 15 %%" % [ms.z, ml])
		check(absf(ms.y - md) <= 0.15 * md, "глушитель: диаметр %.3f = %.2f ± 15 %%" % [ms.y, md])


## v4: площадки педалей под pedal_angle_deg, приборная панель и маркер InstrumentPanel.
func _check_v4(root: Node, p: Dictionary, nodes: Dictionary) -> void:
	var l0 := nodes.get("Trike_LOD0") as MeshInstance3D
	if l0 == null:
		return
	var bl := PackedVector3Array()
	for v in _verts(l0):
		bl.append(Vector3(v.x, -v.z, v.y))
	var s: Dictionary = p.seat
	var a := deg_to_rad(float(s.pedal_angle_deg))
	check(absf(float(s.pedal_angle_deg) - 45.0) <= 0.01, "pedal_angle_deg = 45")
	var n := Vector3(0, -sin(a), cos(a))
	var u := Vector3(0, cos(a), sin(a))
	var pw := float(s.pedal_size[0])
	var pl := float(s.pedal_size[1])
	for key in ["foot_l", "foot_r", "throttle_pedal"]:
		var c := _bl(s[key])
		var k := 1.0 if key != "throttle_pedal" else 0.8
		var found := 0
		for sx in [-1.0, 1.0]:
			for su in [-1.0, 1.0]:
				var want: Vector3 = c + Vector3(sx * pw * k * 0.5, 0, 0) + u * (su * pl * k * 0.5)
				var best := 1e9
				for b in bl:
					# угол площадки: расстояние от вершины до плоскости педали ≤ 1 см (накладка газа — +0,8 см)
					best = minf(best, b.distance_to(want + n * (0.0 if key != "throttle_pedal" else 0.008)))
				if best <= 0.012:
					found += 1
		check(found == 4, "%s: площадка %.2f×%.2f под %.0f°, углов на плоскости: %d из 4 (±1 см)" % [key, pw, pl, float(s.pedal_angle_deg), found])
		# нормаль плоскости 45 ± 2°: вершины вблизи центра лежат в плоскости педали ±1 см
		var inplane := 0
		for b in bl:
			if absf((b - c).dot(n)) <= 0.012 and absf((b - c).dot(u)) <= pl * 0.5 + 0.01 and absf(b.x - c.x) <= pw * 0.5 + 0.01:
				inplane += 1
		check(inplane >= 4, "%s: вершин в плоскости педали ±1 см: %d" % [key, inplane])
	# приборная панель
	var pn: Dictionary = p.panel
	var im := root.find_child("InstrumentPanel", true, false) as Node3D
	check(im != null, "маркер InstrumentPanel")
	var cb := _bl(pn.center)
	if im != null:
		var xf := _xf(im, root)
		var want := Vector3(cb.x, cb.z, -cb.y)
		check(xf.origin.distance_to(want) <= 0.01, "InstrumentPanel: позиция %s = %s ± 1 см" % [xf.origin, want])
		var nb := _bl(pn.normal).normalized()
		var nw := Vector3(nb.x, nb.z, -nb.y)
		var ang := rad_to_deg(xf.basis.z.normalized().angle_to(nw))
		check(ang <= 2.0, "InstrumentPanel: basis.z к normal %.2f° ≤ 2°" % ang)
	var nbv := _bl(pn.normal).normalized()
	var up := nbv.cross(Vector3.RIGHT)
	var pw2 := float(pn.size[0])
	var ph2 := float(pn.size[1])
	var got := 0
	for sx in [-1.0, 1.0]:
		for su in [-1.0, 1.0]:
			var want2: Vector3 = cb + Vector3(sx * pw2 * 0.5, 0, 0) + up * (su * ph2 * 0.5)
			var best2 := 1e9
			for b in bl:
				best2 = minf(best2, b.distance_to(want2))
			if best2 <= 0.02:
				got += 1
	check(got == 4, "панель в Trike_LOD0: углов %.2f×%.2f на месте ±2 см: %d из 4" % [pw2, ph2, got])


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
