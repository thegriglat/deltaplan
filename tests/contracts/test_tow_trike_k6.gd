extends Node
## Контрактный тест TT-К6 v1 (docs/contracts/tow-trike.md): трапеция крыла буксировщика внутри треугольника тележки,
## руки пилота (поза sit) на штанге. По моделям trike.glb, glider_trike_ixess15.glb, pilot.glb и trike_params.json
## (v5, блок bar, seat.hand_*). Числа расчёта — tools/research/tow-trike/trapeze.json (psi, длина руки).

const TRIKE := "res://assets/models/trike/trike.glb"
const WING := "res://assets/models/glider_trike_ixess15.glb"
const PILOT := "res://assets/models/pilot.glb"
const PARAMS := "res://tools/blender/trike_params.json"
const TRAPEZE := "res://tools/research/tow-trike/trapeze.json"
var failures: PackedStringArray = []

const R_BAR := 0.015
const MARGIN := 0.01        # зазор штанги от труб, м
const BODY_GAP := 0.05      # зазор до тела пилота при full_pull, м
const ARM_MARGIN := 0.05    # запас руки при trim, м
const TOL := 0.003          # допуск измерения по вершинам меша, м
const STEP_DEG := 1.0       # шаг по ходу штанги (контракт: <= 2)


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	var d: Variant = JSON.parse_string(text)
	return d if d is Dictionary else {}


## Blender (x вправо, y вперёд, z вверх) -> Godot.
func _g(a: Array) -> Vector3:
	return Vector3(a[0], a[2], -a[1])


## Godot -> Blender.
func _b(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)


## Поворот (y, z) около подвески, + = нос крыла вверх (как trapeze_calc.rot), в осях Blender.
func _rot(v: Vector3, deg: float) -> Vector3:
	var a := deg_to_rad(deg)
	return Vector3(v.x, v.y * cos(a) - v.z * sin(a), v.y * sin(a) + v.z * cos(a))


func _arc(trim: Vector3, deg: float) -> Vector3:
	return _rot(trim, deg)


func _angle(p: Vector3) -> float:
	return rad_to_deg(atan2(p.y, -p.z))


## Расстояние от точки до отрезка.
func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Точки поверхности меша (вершины и точки вдоль рёбер через <= 5 мм) в системе корня, только вблизи дуги штанги
## (расстояние от HangPoint в [r_min, r_max]) и плоскости симметрии (|x| <= 0.06): трубы длинные, вершины на них редкие.
func _surface_pts(root: Node, name_prefix: String, r_min: float, r_max: float) -> PackedVector3Array:
	var res := PackedVector3Array()
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not String(mi.name).begins_with(name_prefix) or mi.mesh == null:
			continue
		var xf: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				idx = PackedInt32Array(range(vs.size()))
			var i := 0
			while i + 2 < idx.size():
				var t := [xf * vs[idx[i]], xf * vs[idx[i + 1]], xf * vs[idx[i + 2]]]
				i += 3
				for k in 3:
					var a: Vector3 = t[k]
					var b: Vector3 = t[(k + 1) % 3]
					if minf(absf(a.x), absf(b.x)) > 0.06:
						continue
					var len := a.distance_to(b)
					var m := maxi(1, int(ceil(len / 0.005)))
					for j in m + 1:
						var q := a.lerp(b, float(j) / float(m))
						var r := q.length()
						if absf(q.x) <= 0.06 and r >= r_min and r <= r_max:
							res.append(q)
	return res


func _empty_xf(skel: Skeleton3D, n: Node3D) -> Transform3D:
	var att := n.get_parent() as BoneAttachment3D
	if att == null:
		return n.global_transform
	return skel.global_transform * skel.get_bone_global_pose(skel.find_bone(att.bone_name)) * n.transform


## Вершины PilotBody в текущей позе (скиннинг вручную), с доминирующей костью каждой вершины.
func _body_verts(root: Node, skel: Skeleton3D) -> Array:
	var mi := root.find_child("PilotBody", true, false) as MeshInstance3D
	var pts := PackedVector3Array()
	var names: Array[String] = []
	if mi == null or mi.skin == null:
		return [pts, names]
	var bone_of := PackedInt32Array()
	for b in mi.skin.get_bind_count():
		var bi := mi.skin.get_bind_bone(b)
		if bi < 0:
			bi = skel.find_bone(mi.skin.get_bind_name(b))
		bone_of.append(bi)
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var wts: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / maxi(vs.size(), 1)
		for i in vs.size():
			var p := Vector3.ZERO
			var wmax := -1.0
			var bmax := -1
			for k in per:
				var w := wts[i * per + k]
				if w <= 0.0:
					continue
				var bi := bone_of[bones[i * per + k]]
				p += w * (skel.get_bone_global_pose(bi) * mi.skin.get_bind_pose(bones[i * per + k]) * vs[i])
				if w > wmax:
					wmax = w
					bmax = bi
			pts.append(skel.global_transform * p)
			names.append(skel.get_bone_name(bmax) if bmax >= 0 else "")
	return [pts, names]


func _is_arm(bone: String) -> bool:
	for k in ["upperarm", "forearm", "hand"]:   # как extract_sit.py: группы рук, из них грудь (|x| < 0,1) — тело
		if bone.to_lower().begins_with(k):
			return true
	return false


func test_params_v5() -> void:
	var p := _json(PARAMS)
	var bar: Dictionary = p.get("bar", {})
	var seat: Dictionary = p.get("seat", {})
	check(int(p.get("version", 0)) == 5, "trike_params.version = 5 (TK-К1 v5)")
	check(String(bar.get("wing", "")) == "trike_ixess15", "bar.wing = trike_ixess15")
	for k in ["d", "half_width", "trim", "full_pull", "full_push", "travel_m", "travel_deg", "how"]:
		check(bar.has(k), "bar." + k)
	if not (bar.has("trim") and bar.has("full_pull") and bar.has("full_push")):
		return
	var bt := _g(bar.trim)
	var bpl := _g(bar.full_pull)
	var bph := _g(bar.full_push)
	check(absf(bt.length() - bpl.length()) <= 0.005 and absf(bt.length() - bph.length()) <= 0.005, "штанга по дуге около HangPoint: %.3f %.3f %.3f" % [bt.length(), bpl.length(), bph.length()])
	var ap := _angle(_b(bpl))
	var at := _angle(_b(bt))
	var ah := _angle(_b(bph))
	check(ap < at and at < ah, "full_pull < trim < full_push по углу: %.2f %.2f %.2f" % [ap, at, ah])
	check(absf((ah - ap) - float(bar.travel_deg)) <= 0.05, "travel_deg = %.2f" % (ah - ap))
	check(absf(deg_to_rad(ah - ap) * bt.length() - float(bar.travel_m)) <= 0.01, "travel_m по дуге")
	var hl := _g(seat.hand_l)
	var hr := _g(seat.hand_r)
	check(absf(hl.x + hr.x) <= 1e-4 and absf(hl.y - hr.y) <= 1e-4 and absf(hl.z - hr.z) <= 1e-4, "хват симметричен")
	for h in [hl, hr]:
		check(absf(h.y - bt.y) <= 0.01 and absf(h.z - bt.z) <= 0.01, "хват на оси штанги trim ± 1 см: %s vs %s" % [h, bt])
	check(float(bar.d) == 0.03 and float(bar.half_width) >= 0.5, "bar.d, half_width")


## Крыло: BaseBar в осях крыла (киль горизонтален), повёрнутая на psi (тангаж киля относительно тележки при триме) —
## штанга trim; стойки сходятся к болту под килем (UprightTop*) и к оси штанги (UprightBottom*).
func test_wing_bar_matches_trim() -> void:
	var p := _json(PARAMS)
	var tz := _json(TRAPEZE)
	check(not tz.is_empty(), "trapeze.json читается")
	if tz.is_empty() or not p.has("bar"):
		return
	var psi := float(tz.glider_params.psi_deg.value)
	var root := (load(WING) as PackedScene).instantiate()
	add_child(root)
	var hang := root.find_child("HangPoint", true, false) as Node3D
	var bb := root.find_child("BaseBar", true, false) as Node3D
	check(hang != null and bb != null, "HangPoint и BaseBar в glb крыла")
	if hang != null and bb != null:
		var bw := _b(bb.global_position - hang.global_position)
		var trim_b: Vector3 = _rot(bw, psi)
		var want := Vector3(0.0, float(p.bar.trim[1]), float(p.bar.trim[2]))
		print("         BaseBar (оси крыла) %s, после psi %.2f°: %s; bar.trim %s" % [bw, psi, trim_b, want])
		check(absf(bw.x) <= 0.005, "BaseBar по центру (x = %.4f)" % bw.x)
		check(Vector2(trim_b.y, trim_b.z).distance_to(Vector2(want.y, want.z)) <= 0.01, "BaseBar + psi = bar.trim ± 1 см")
		var up_l := root.find_child("UprightBottomL", true, false) as Node3D
		var up_r := root.find_child("UprightBottomR", true, false) as Node3D
		check(up_l != null and up_r != null, "UprightBottomL/R")
		if up_l != null and up_r != null:
			var wd := absf(_b(up_r.global_position - up_l.global_position).x)
			check(absf(wd * 0.5 - float(p.bar.half_width)) <= 0.01, "полуширина штанги в glb %.3f = bar.half_width" % (wd * 0.5))
			var a := _b(up_l.global_position - hang.global_position)
			check(absf(a.y - bw.y) <= 0.02 and absf(a.z - bw.z) <= 0.02, "концы стоек у оси штанги")
	root.free()


## Штанга по всему ходу вне труб тележки (зазор >= r + 0,01), на full_push касается подкоса; trim — перед грудью пилота.
func test_bar_in_triangle() -> void:
	var p := _json(PARAMS)
	if not p.has("bar"):
		check(false, "bar в trike_params")
		return
	var bar: Dictionary = p.bar
	var trike := (load(TRIKE) as PackedScene).instantiate()
	add_child(trike)
	var rb := _b(_g(bar.trim)).length()
	var verts := _surface_pts(trike, "Trike_LOD0", rb - 0.25, rb + 0.25)
	if verts.is_empty():
		verts = _surface_pts(trike, "Trike", rb - 0.25, rb + 0.25)
	check(verts.size() > 50, "вершины Trike_LOD0: %d" % verts.size())
	var bt := _b(_g(bar.trim))
	var a_pull := _angle(_b(_g(bar.full_pull))) - _angle(bt)
	var a_push := _angle(_b(_g(bar.full_push))) - _angle(bt)
	var hw := float(bar.half_width)
	var need := R_BAR + MARGIN
	var worst := INF
	var at_push := INF
	var a := a_pull
	while a <= a_push + 1e-6:
		var c := _g([0.0, _rot(bt, a).y, _rot(bt, a).z])
		var d := INF
		for v in verts:
			# концы штанги проецируются на x = 0: рассматриваем поверхность у плоскости симметрии рамы
			d = minf(d, Vector2(v.y, v.z).distance_to(Vector2(c.y, c.z)))
		worst = minf(worst, d)
		if absf(a - a_push) < 1e-6:
			at_push = d
		a += STEP_DEG
		if a > a_push and a - STEP_DEG < a_push - 1e-6:
			a = a_push
	print("         min расстояние оси штанги до труб (плоскость x=0): %.4f (нужно >= %.4f), full_push %.4f" % [worst, need, at_push])
	check(worst >= need - TOL, "штанга вне труб по всему ходу: %.4f >= %.4f" % [worst, need])
	check(at_push <= need + 0.012, "full_push — упор в подкос: расстояние %.4f <= %.4f" % [at_push, need + 0.012])
	check(hw > 0.0, "half_width")
	trike.free()


## Поза sit: кисти на штанге при trim, рука не вытянута, тело не ближе 5 см на full_pull.
func test_pilot_hands_on_bar() -> void:
	var p := _json(PARAMS)
	var tz := _json(TRAPEZE)
	if not p.has("bar"):
		check(false, "bar в trike_params")
		return
	var root := (load(PILOT) as PackedScene).instantiate()
	add_child(root)
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	check(ap != null and skel != null and ap.has_animation("sit"), "pilot.glb: sit")
	if ap == null or skel == null or not ap.has_animation("sit"):
		root.free()
		return
	ap.play("sit")
	ap.seek(0.0, true)
	skel.force_update_all_bone_transforms()
	var bt := _g(p.bar.trim)
	var sh_r := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("UpperArm.R")).origin
	var el_r := skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Forearm.R")).origin
	var hands := {}
	for side in ["L", "R"]:
		var h := root.find_child("Hand" + side, true, false) as Node3D
		check(h != null, "пустышка Hand" + side)
		if h == null:
			continue
		var o := _empty_xf(skel, h).origin
		hands[side] = o
		var axis := Vector3(o.x, bt.y, bt.z)
		check(o.distance_to(axis) <= 0.02, "кисть %s на штанге trim ± 2 см: %s vs ось %s" % [side, o, axis])
		check(absf(absf(o.x) - absf(float(p.seat.hand_l[0]))) <= 0.02, "хват по ширине: |x| %.3f" % absf(o.x))
	if hands.has("R"):
		var arm := sh_r.distance_to(el_r) + el_r.distance_to(hands.R)
		# длина руки: плечо-локоть + локоть-запястье + запястье-хват (запястье = Hand.R, если есть)
		var wr_i := skel.find_bone("Hand.R")
		if wr_i >= 0:
			var wr := skel.global_transform * skel.get_bone_global_pose(wr_i).origin
			arm = sh_r.distance_to(el_r) + el_r.distance_to(wr) + wr.distance_to(hands.R)
		var reach := sh_r.distance_to(hands.R)
		print("         рука: плечо-хват %.3f, длина руки %.3f" % [reach, arm])
		check(reach <= arm - ARM_MARGIN + 0.005, "плечо-хват %.3f <= рука %.3f - 0,05" % [reach, arm])
		if not tz.is_empty():
			check(absf(arm - float(tz.arm_len)) <= 0.02, "длина руки %.3f = trapeze.json %.3f ± 2 см" % [arm, float(tz.arm_len)])
	# тело (без рук) от оси штанги full_pull по плоскости симметрии: зазор >= BODY_GAP
	var bv := _body_verts(root, skel)
	var pts: PackedVector3Array = bv[0]
	var names: Array = bv[1]
	check(pts.size() > 1000, "вершины PilotBody: %d" % pts.size())
	var pull := _g(p.bar.full_pull)
	var dmin := INF
	var dmin_info := ""
	for i in pts.size():
		var q := pts[i]
		if _is_arm(String(names[i])) and absf(q.x) >= 0.10:
			continue
		if absf(q.x) <= float(p.bar.half_width):
			var dd := Vector2(q.y, q.z).distance_to(Vector2(pull.y, pull.z))
			if dd < dmin:
				dmin = dd
				dmin_info = "%s %s" % [names[i], q]
	print("         тело - ось штанги full_pull: %.4f (нужно >= %.4f) %s" % [dmin, R_BAR + BODY_GAP, dmin_info])
	check(dmin >= R_BAR + BODY_GAP - TOL, "full_pull: зазор до тела %.4f >= %.4f" % [dmin, R_BAR + BODY_GAP])
	root.free()
