extends TestCase
## Контракт TK-K2 (docs/contracts/trike-model.md): версия в заголовке; модель assets/models/trike/trike.glb.
## Размеры — из tools/blender/trike_params.json (Blender: x вправо, y вперёд, z вверх; Godot = (x, z, −y)).

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 2
const GLB := "res://assets/models/trike/trike.glb"
const PARAMS := "res://tools/blender/trike_params.json"
const BUDGET := {"Trike_LOD0": 5500, "Trike_LOD1": 1200, "Trike_LOD2": 250, "Prop_LOD0": 500, "Prop_LOD1": 80}


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
	for nm in ["Trike_LOD0", "Trike_LOD1", "Trike_LOD2", "Prop_LOD0", "Prop_LOD1"]:
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
	# анимация
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(ap != null and ap.has_animation("prop_spin"), "AnimationPlayer с prop_spin")
	if ap != null and ap.has_animation("prop_spin") and prop != null:
		var an := ap.get_animation("prop_spin")
		check(absf(an.length - 1.0) <= 0.01, "prop_spin длиной 1,0 с: %.3f" % an.length)
		check(an.loop_mode == Animation.LOOP_LINEAR, "prop_spin — цикл")
		# поворот вокруг локальной Z: +θ при взгляде сзади против часовой; prop_cw_from_behind → по часовой
		var found := -1
		for i in an.get_track_count():
			if an.track_get_type(i) == Animation.TYPE_ROTATION_3D and String(an.track_get_path(i)).ends_with("Propeller"):
				found = i
		check(found >= 0, "дорожка вращения Propeller")
		if found >= 0:
			var q0: Quaternion = an.rotation_track_interpolate(found, 0.0)
			var q1: Quaternion = an.rotation_track_interpolate(found, 0.125)   # 45°
			var rel := q0.inverse() * q1
			var ang := rel.get_angle()
			var ax := rel.get_axis()
			var cw := bool(dims.prop_cw_from_behind.value)
			check(absf(rad_to_deg(ang) - 45.0) < 1.0, "за 1/8 с поворот %.1f° ≈ 45°" % rad_to_deg(ang))
			# ось в локальной системе узла: ±Z; знак «+Z» = против часовой при взгляде сзади
			var sgn := ax.z * (1.0 if ang > 0.0 else 1.0)
			var q_mid: Quaternion = an.rotation_track_interpolate(found, 0.5)
			check(absf(rad_to_deg((q0.inverse() * q_mid).get_angle()) - 180.0) < 1.0, "за 0,5 с — полуоборот")
			check(absf(absf(sgn) - 1.0) < 0.01, "спин вокруг локальной Z: %s" % ax)
			check((sgn < 0.0) == cw, "направление: prop_cw_from_behind = %s, ось %s" % [cw, ax])
	root.free()


func _xf(n: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t
