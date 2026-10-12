extends TestCase
## Контрактные тесты pilot-hud (docs/contracts/pilot-hud.md). Версии — координатор; проверки формы и
## инвариантов дописывают владельцы: PH-К1 — PH-1, PH-К2 — PH-2/PH-7, PH-К3 — PH-3, PH-К4 — PH-5/PH-6,
## PH-К5 — PH-9, PH-К6 — PH-4, PH-К7 — PH-8. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-hud.md"
const VERSIONS := {
	"PH-К1": 1, "PH-К2": 1, "PH-К3": 2, "PH-К4": 1, "PH-К5": 1, "PH-К6": 1, "PH-К7": 1,
}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


# ---------------------------------------------------------------- PH-К3: pilot.glb

const PILOT_TRIS_BEFORE := 10431   # треугольников пилота до PH-3
const WRIST_AT_MIN := 0.040
const WRIST_AT_MAX := 0.050
const GLOVE_MAX_BACK := 0.045      # вершины Glove — не дальше от оси запястья к локтю
const EYE_ANGLE_MAX := 56.0        # prone: угол между -Z пустышки и направлением на глаза, град
const BETA_MAX := 50.0


func _pilot() -> Node:
	return (load("res://assets/models/pilot.glb") as PackedScene).instantiate()


## Поза кости в пространстве скелета (поза покоя).
func _bone(sk: Skeleton3D, n: String) -> Transform3D:
	return sk.get_bone_global_rest(sk.find_bone(n))


## Пустышка под BoneAttachment3D: трансформ в пространстве скелета.
func _mount(root: Node, sk: Skeleton3D, n: String) -> Transform3D:
	var node := root.find_child(n, true, false) as Node3D
	var ba := node.get_parent() as BoneAttachment3D
	return _bone(sk, ba.bone_name) * node.transform


func test_wrist_mounts() -> void:
	var root := _pilot()
	var sk := root.find_child("Skeleton3D", true, false) as Skeleton3D
	for s: String in ["L", "R"]:
		var node := root.find_child("Wrist" + s, true, false) as Node3D
		check(node != null, "Wrist%s есть" % s)
		if node == null:
			continue
		var ba := node.get_parent() as BoneAttachment3D
		check(ba != null and ba.bone_name == "Forearm." + s, "Wrist%s на кости Forearm.%s" % [s, s])
		var m := _mount(root, sk, "Wrist" + s)
		var b := m.basis
		check(absf(b.x.length() - 1.0) < 0.01 and absf(b.y.length() - 1.0) < 0.01
			and absf(b.z.length() - 1.0) < 0.01, "Wrist%s: оси единичные" % s)
		check(absf(b.x.dot(b.y)) < 0.02 and absf(b.y.dot(b.z)) < 0.02, "Wrist%s: оси ортогональны" % s)
		check(b.determinant() > 0.0 and b.x.cross(b.y).dot(b.z) > 0.9, "Wrist%s: правая тройка" % s)
		var wr := _bone(sk, "Hand." + s).origin
		var el := _bone(sk, "Forearm." + s).origin
		var fa := (wr - el).normalized()
		check(b.y.dot(fa) > 0.98, "Wrist%s: +Y вдоль предплечья к пальцам (%.3f)" % [s, b.y.dot(fa)])
		var back := (wr - m.origin).dot(fa)
		check(back > WRIST_AT_MIN - 0.012 and back < WRIST_AT_MAX + 0.012,
			"Wrist%s: %.0f мм от оси запястья к локтю (поверхность рукава)" % [s, back * 1000.0])
		var axis_pt := wr - fa * back
		var out := (m.origin - axis_pt)
		out -= fa * out.dot(fa)
		check(out.length() > 0.015 and out.length() < 0.045,
			"Wrist%s: на поверхности руки (%.0f мм от оси)" % [s, out.length() * 1000.0])
		check(-b.z.dot(out.normalized()) > 0.9, "Wrist%s: -Z наружная нормаль (%.2f)" % [s, -b.z.dot(out.normalized())])
		check(-b.z.dot(fa) < 0.2, "Wrist%s: нормаль ⟂ предплечью" % s)
	root.free()


func test_glove_cuff_and_sleeve() -> void:
	var root := _pilot()
	var sk := root.find_child("Skeleton3D", true, false) as Skeleton3D
	var mats := {}
	var worst := {"L": -1.0, "R": -1.0}
	var tris := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var pre := mi.get_parent() as Node3D
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			xf = (p as Node3D).transform * xf
			p = p.get_parent()
		for i in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(i)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx.size() > 0 else verts.size()) / 3
			var mn := mi.mesh.surface_get_material(i).resource_name
			mats[mn] = true
			if mn != "Glove":
				continue
			for s: String in ["L", "R"]:
				var wr := _bone(sk, "Hand." + s).origin
				var el := _bone(sk, "Forearm." + s).origin
				var fa := (wr - el).normalized()
				var sd := -1.0 if s == "L" else 1.0
				for v in verts:
					var g := xf * v
					if g.x * sd > 0.2:
						worst[s] = maxf(worst[s], (wr - g).dot(fa))
		if pre == null:
			continue
	check(mats.has("JacketSleeve") and mats.has("Jacket") and mats.has("Glove"), "материалы Jacket/JacketSleeve/Glove")
	for k: String in ["Pod", "Trousers", "Boot", "Sole", "Skin"]:
		check(mats.has(k), "материал %s на месте" % k)
	for s: String in ["L", "R"]:
		check(worst[s] <= GLOVE_MAX_BACK, "Glove %s: дальше всего %.1f мм к локтю от оси запястья (≤ 45)" % [s, worst[s] * 1000.0])
		check(worst[s] > 0.025, "Glove %s: манжета есть (%.1f мм)" % [s, worst[s] * 1000.0])
	check(tris <= PILOT_TRIS_BEFORE, "треугольников пилота %d ≤ %d" % [tris, PILOT_TRIS_BEFORE])
	root.free()


## prone: угол между -Z пустышки и направлением на глаза не больше EYE_ANGLE_MAX.
func test_wrist_faces_eyes_in_prone() -> void:
	var root := _pilot()
	var sk := root.find_child("Skeleton3D", true, false) as Skeleton3D
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var anim := ap.get_animation("prone")
	for s: String in ["L", "R"]:
		var bi := sk.find_bone("Forearm." + s)
		var hi := sk.find_bone("Head")
		# поза prone кости в пространстве скелета: цепочка локальных поз из анимации (t = 0)
		var pose := {}
		for tr in anim.get_track_count():
			var path := str(anim.track_get_path(tr))
			var bn := path.get_slice(":", 1)
			var kind := anim.track_get_type(tr)
			if not pose.has(bn):
				pose[bn] = sk.get_bone_rest(sk.find_bone(bn)) if sk.find_bone(bn) >= 0 else Transform3D.IDENTITY
			var t: Transform3D = pose[bn]
			if kind == Animation.TYPE_POSITION_3D:
				t.origin = anim.position_track_interpolate(tr, 0.0)
			elif kind == Animation.TYPE_ROTATION_3D:
				t.basis = Basis(anim.rotation_track_interpolate(tr, 0.0)) * Basis.from_scale(t.basis.get_scale())
			elif kind == Animation.TYPE_SCALE_3D:
				t.basis = t.basis.orthonormalized() * Basis.from_scale(anim.scale_track_interpolate(tr, 0.0))
			pose[bn] = t
		var g := func(n: String) -> Transform3D:
			var x := Transform3D.IDENTITY
			var i := sk.find_bone(n)
			var chain := []
			while i >= 0:
				chain.push_front(sk.get_bone_name(i))
				i = sk.get_bone_parent(i)
			for c: String in chain:
				x = x * (pose[c] if pose.has(c) else sk.get_bone_rest(sk.find_bone(c)))
			return x
		var rest_f := _bone(sk, "Forearm." + s)
		var m_rest := _mount(root, sk, "Wrist" + s)
		var local := rest_f.affine_inverse() * m_rest
		var m: Transform3D = g.call("Forearm." + s) * local
		var head := root.find_child("Head", true, false) as Node3D
		var hba := head.get_parent() as BoneAttachment3D
		var eye: Vector3 = (g.call(hba.bone_name) as Transform3D) * head.transform.origin
		var ang := rad_to_deg((-m.basis.z).angle_to((eye - m.origin).normalized()))
		check(ang <= EYE_ANGLE_MAX, "prone, Wrist%s: угол нормаль→глаза %.1f° ≤ %.0f°" % [s, ang, EYE_ANGLE_MAX])
	root.free()
