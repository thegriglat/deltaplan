extends TestCase
## Контрактные тесты pilot-hud (docs/contracts/pilot-hud.md). Версии — координатор; проверки формы и
## инвариантов дописывают владельцы: PH-К1 — PH-1, PH-К2 — PH-2/PH-7, PH-К3 — PH-3, PH-К4 — PH-5/PH-6,
## PH-К5 — PH-9, PH-К6 — PH-4, PH-К7 — PH-8. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-hud.md"
const VERSIONS := {
	"PH-К1": 1, "PH-К2": 1, "PH-К3": 2, "PH-К4": 2, "PH-К5": 1, "PH-К6": 1, "PH-К7": 1,
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


# ---- PH-К4: часы (watch.glb), владелец PH-5 ----

const WATCH := "res://assets/models/watch.glb"


func _watch_root() -> Node3D:
	var ps := load(WATCH) as PackedScene
	check(ps != null, "watch.glb загружается")
	return ps.instantiate() as Node3D if ps else null


## AABB меша ноды верхнего уровня в системе корня (для стрелок — с учётом поворота rot_z вокруг Z).
func _watch_aabb(root: Node3D, n: String, rot_z: float = 0.0) -> AABB:
	var node := root.find_child(n, false, false) as MeshInstance3D
	if node == null:
		check(false, "нода %s — MeshInstance3D, ребёнок корня" % n)
		return AABB()
	var t := Transform3D(Basis(Vector3(0, 0, 1), rot_z), Vector3.ZERO) * node.transform
	return t * node.mesh.get_aabb()


func test_ph_k4_watch_nodes_and_budget() -> void:
	var root := _watch_root()
	if root == null:
		return
	for n in ["Case", "Strap", "Dial", "HourHand", "MinuteHand", "Glass"]:
		check(root.find_child(n, false, false) is MeshInstance3D, "нода %s на верхнем уровне" % n)
	check(root.find_child("SecondHand", true, false) == null, "секундной стрелки нет")
	var tris := 0
	for c in root.get_children():
		var mi := c as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var idx: PackedInt32Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			tris += idx.size() / 3
	check(tris <= 2500, "треугольников %d ≤ 2500" % tris)
	var mats := {}
	for n in ["Case", "Strap", "Dial", "HourHand", "Glass"]:
		var mi := root.find_child(n, false, false) as MeshInstance3D
		mats[n] = mi.mesh.surface_get_material(0).resource_name
	check(mats == {"Case": "WatchCase", "Strap": "WatchStrap", "Dial": "WatchDial",
		"HourHand": "WatchHand", "Glass": "WatchGlass"}, "имена материалов: %s" % mats)
	root.free()


func test_ph_k4_watch_dimensions() -> void:
	var root := _watch_root()
	if root == null:
		return
	var case_box := _watch_aabb(root, "Case")
	# корпус: Ø 40 ± 2 по Y (вдоль руки), высота ≤ 13 мм от начала, дно на z=0, циферблат в −Z
	check(absf(case_box.size.y - 0.040) <= 0.002, "Ø корпуса %.1f мм" % (case_box.size.y * 1000))
	check(case_box.size.x <= 0.046, "ширина с головкой %.1f мм" % (case_box.size.x * 1000))
	check(case_box.position.x < -0.0225 and case_box.end.x < 0.0225, "заводная головка по −X")
	check(absf(case_box.end.z) < 1e-4 and case_box.position.z >= -0.013, "корпус от 0 до ≤ 13 мм в −Z: %s" % case_box)
	var dial := _watch_aabb(root, "Dial")
	check(dial.size.x >= 0.030 and dial.size.y >= 0.030, "Ø циферблата %.1f мм" % (dial.size.x * 1000))
	check(dial.size.z < 1e-4 and dial.position.z < 0, "циферблат плоский, смотрит в −Z")
	var strap := _watch_aabb(root, "Strap")
	var w := 0.056
	var h := 0.051
	var gap := 0.001
	# ширина вдоль руки 20 мм; охват эллипса W×H с зазором ≥ 1 мм, но не дальше 5 мм
	check(strap.size.y >= 0.0199 and strap.size.y <= 0.0245, "ширина ремешка 20 мм (с пряжкой до 24) %.1f мм" % (strap.size.y * 1000))
	check(strap.size.x >= w + 2 * gap and strap.size.x <= w + 10e-3, "ремешок по X %.1f мм" % (strap.size.x * 1000))
	check(strap.end.z >= h + 2 * gap and strap.end.z <= h + 10e-3, "ремешок по Z до %.1f мм" % (strap.end.z * 1000))
	root.free()


func test_ph_k4_watch_hands() -> void:
	var root := _watch_root()
	if root == null:
		return
	var rd := _watch_aabb(root, "Dial").size.x * 0.5
	var hh := root.find_child("HourHand", false, false) as Node3D
	var mh := root.find_child("MinuteHand", false, false) as Node3D
	check(absf(hh.position.x) < 1e-6 and absf(hh.position.y) < 1e-6 and hh.position.z < 0, "начало часовой на оси циферблата")
	check(absf(mh.position.x) < 1e-6 and absf(mh.position.y) < 1e-6 and mh.position.z < hh.position.z, "минутная выше часовой")
	check(hh.basis.is_equal_approx(Basis.IDENTITY) and mh.basis.is_equal_approx(Basis.IDENTITY), "поворот 0")
	var hb := _watch_aabb(root, "HourHand")
	var mb := _watch_aabb(root, "MinuteHand")
	check(hb.end.y > 0.0 and absf(hb.end.y / rd - 0.6) < 0.1, "часовая ≈0,6 R: %.2f" % (hb.end.y / rd))
	check(absf(mb.end.y / rd - 0.9) < 0.1, "минутная ≈0,9 R: %.2f" % (mb.end.y / rd))
	check(hb.size.x >= 0.0025, "часовая шире 2,5 мм")
	check(mb.size.x >= 0.002 and mb.size.x < hb.size.x + 1e-4, "минутная ≥ 2 мм")
	# положительный угол — по часовой для смотрящего (+Y → −X)
	for n in ["HourHand", "MinuteHand"]:
		var q := _watch_aabb(root, n, PI / 2)
		check(q.position.x < -0.5 * (hb.end.y if n == "HourHand" else mb.end.y), "%s при +90° смотрит в −X" % n)
	# не пересекаются со стеклом, циферблатом и друг с другом при любом угле (слои по Z)
	var glass := _watch_aabb(root, "Glass")
	var dial := _watch_aabb(root, "Dial")
	# слои вдоль −Z: циферблат > часовая > минутная > стекло, зазоры ≥ 0
	check(hb.end.z <= dial.position.z + 1e-6, "часовая под циферблатом-слоем (над ним): %s" % hb)
	check(mb.end.z <= hb.position.z + 1e-6, "минутная выше часовой: %s" % mb)
	check(mb.position.z > glass.position.z + 0.0003, "минутная под стеклом: %s" % mb)
	root.free()


func test_ph_k4_watch_textures() -> void:
	# текстуры ≤ 512², VRAM-сжатие + мипмапы в .import
	var dir := DirAccess.open("res://assets/models")
	var found := 0
	for f in dir.get_files():
		if f.begins_with("watch") and f.ends_with(".png"):
			found += 1
			var img := Image.load_from_file("res://assets/models/" + f)
			check(img.get_width() <= 512 and img.get_height() <= 512, "%s ≤ 512²" % f)
			var imp := _read("res://assets/models/%s.import" % f)
			check(imp.contains("compress/mode=2") and imp.contains("mipmaps/generate=true"), "%s: .import VRAM + мипмапы" % f)
	check(found >= 2, "текстуры циферблата и ремешка извлечены (%d)" % found)


# ---- PH-К4: наручный компас (PH-6) ----
const COMPASS := "res://assets/models/wrist_compass.glb"


func _compass() -> Node3D:
	return (load(COMPASS) as PackedScene).instantiate() as Node3D


func _mi(root: Node3D, n: String) -> MeshInstance3D:
	return root.find_child(n, false, false) as MeshInstance3D


func _tris(root: Node) -> int:
	var n := 0
	if root is MeshInstance3D and (root as MeshInstance3D).mesh:
		var mesh := (root as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var idx: PackedInt32Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			n += idx.size() / 3
	for c in root.get_children():
		n += _tris(c)
	return n


func test_ph_k4_compass_nodes_and_axes() -> void:
	var r := _compass()
	for n in ["Case", "Strap", "Card", "Lubber"]:
		check(_mi(r, n) != null, "%s — ребёнок корня" % n)
	var case_a := _mi(r, "Case").get_aabb()
	check(absf(case_a.size.x * 1000.0 - 46.0) <= 3.0, "корпус Ø 46 ± 3: %.1f" % (case_a.size.x * 1000.0))
	check(-case_a.position.z * 1000.0 <= 16.0 and case_a.position.z < 0.0, "корпус наружу (−Z), высота ≤ 16 мм")
	check(case_a.end.z >= 0.0 and case_a.end.z < 0.012, "юбка корпуса садится на рукав (до 12 мм вглубь)")
	var card := _mi(r, "Card")
	check(card.get_aabb().size.x >= 0.034, "картушка Ø ≥ 34 мм")
	for n in ["Card", "Lubber"]:
		var m := _mi(r, n)
		check(absf(m.position.x) < 1e-6 and absf(m.position.y) < 1e-6 and m.position.z < 0.0,
			"%s: начало на оси циферблата" % n)
		check(m.rotation.length() < 1e-4, "%s: поворот 0" % n)
	check(_tris(r) <= 2500, "треугольников ≤ 2500: %d" % _tris(r))
	r.free()


func test_ph_k4_compass_lubber_on_plus_y_and_clear_of_card() -> void:
	var r := _compass()
	var lub := _mi(r, "Lubber")
	var la := lub.get_aabb()
	check(la.get_center().y > 0.012 and absf(la.get_center().x) < 0.001, "Lubber на +Y (к пальцам)")
	var card := _mi(r, "Card")
	var ca := card.get_aabb()
	var card_front := card.position.z + ca.position.z   # дальняя от рукава грань картушки (−Z)
	var lub_back := lub.position.z + la.position.z + la.size.z   # ближняя к рукаву грань черты
	check(lub_back < card_front, "Lubber не пересекает картушку (зазор %.2f мм)" % ((card_front - lub_back) * 1000.0))
	check(ca.size.x * 0.5 < 0.0199, "картушка внутри колодца капсулы")
	r.free()


func test_ph_k4_compass_north_marker_on_plus_y() -> void:
	# красный треугольник N на текстуре при повороте 0 — у вершины картушки на +Y
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://assets/models/wrist_compass_CompassCard.png"))
	check(img != null and img.get_width() <= 512, "текстура картушки ≤ 512²")
	var r := _compass()
	var card := _mi(r, "Card")
	var arr := card.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var sx := 0.0
	var sy := 0.0
	var cnt := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.8 and c.g < 0.5 and c.b < 0.4 and y < img.get_height() * 0.5 + 1:
				sx += (x + 0.5) / img.get_width()
				sy += (y + 0.5) / img.get_height()
				cnt += 1
	check(cnt > 20, "красный маркер N есть на текстуре")
	var uv := Vector2(sx, sy) / maxf(cnt, 1)
	var best := -1
	var bd := 1e9
	for i in verts.size():
		if absf(verts[i].z - card.get_aabb().end.z) < 1e-6 or true:
			var d := uvs[i].distance_to(uv)
			if d < bd and verts[i].length() > 0.015:
				bd = d
				best = i
	var dir := Vector2(verts[best].x, verts[best].y).normalized()
	check(dir.y > 0.98 and absf(dir.x) < 0.2, "N картушки на +Y при повороте 0: %s" % dir)
	r.free()


func test_ph_k4_compass_materials_and_import() -> void:
	var r := _compass()
	var names := {}
	for n in ["Case", "Strap", "Card", "Lubber"]:
		var m := _mi(r, n)
		for s in m.mesh.get_surface_count():
			names[m.mesh.surface_get_material(s).resource_name] = true
	for n in ["CompassCase", "CompassStrap", "CompassCard", "CompassMark"]:
		check(names.has(n), "материал %s" % n)
	var glass := _mi(r, "Glass")
	if glass:
		var gm := glass.mesh.surface_get_material(0) as BaseMaterial3D
		check(gm.albedo_color.a <= 0.15, "Glass прозрачность ≥ 0,85")
	var imp := FileAccess.get_file_as_string("res://assets/models/wrist_compass_CompassCard.png.import")
	check(imp.contains("compress/mode=2") and imp.contains("mipmaps/generate=true"), ".import: VRAM-сжатие и мипмапы")
	r.free()


# ---- PH-К2: часы и флажки (владелец флажка clock — PH-2) ----


func test_ph_k2_clock_flag_default_and_source() -> void:
	check(Config.get_config("ui").get("clock", {}).get("enabled", null) == true, "ui.clock.enabled по умолчанию true")
	var c := SunClock.new()
	c.hour = 6.5
	check(SunClock.format_hour(c.hour) == "06:30" and c.time_text() == "06:30", "6,5 = 06:30")
	var lbl := ClockLabel.new()
	lbl.clock = c
	check(lbl.text() == SunClock.format_hour(c.hour), "текст = format_hour(clock.hour)")
	lbl.free()


## PH-К7 (владелец PH-8): интерфейс затенения и инварианты.
func test_sky_shade_contract_ph_k7() -> void:
	var area := 13.5
	var cfg := {"gain": 1.6, "sky_share": 0.3, "h_max_m": 12.0}
	var prev := 2.0
	for h in [1.0, 2.0, 4.0, 8.0]:
		var d := SkyShade.darkening(0.0, h, area, cfg)
		check(d < prev and d <= 1.0, "убывает по h, ≤ 1: %.3f" % d)
		prev = d
	check(SkyShade.darkening(0.0, 13.0, area, cfg) == 0.0, "ноль выше h_max")
	var d_touch := SkyShade.darkening(1.0, 2.5, area, cfg)
	check(d_touch > 0.1 * SkyShade.darkening(0.0, 2.5, area, cfg), "у касания охватывает точку под ногами")


# ---- PH-К6: трава в точке и подошвы пилота, владелец PH-4 ----
func test_ph_k6_grass_height_at() -> void:
	var n := 21
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var cs := PackedByteArray()
	cs.resize(n * n)
	for j in n:
		for i in n:
			cs[j * n + i] = SurfaceLayer.GRASS if i < 10 else SurfaceLayer.BARE
	var g := GrassField.new()
	g._layer = HeightLayer.from_heights("t", n, n, 10.0, -100.0, -100.0, hs)
	g._surface = SurfaceLayer.from_classes("t", n, n, 10.0, -100.0, -100.0, cs)
	g._cfg = Config.get_config("vegetation").grass.duplicate(true)
	g._cfg["enabled"] = true
	g._cfg["density_pct"] = 100
	var open := g.height_at(-50.0, 0.0)
	check(open > 0.0, "GRASS ровного места: height_at > 0")
	check(g.height_at(-50.0, 0.0) == open, "детерминирована")
	check(g.height_at(50.0, 0.0) == 0.0, "BARE → 0")
	var sites: Array[Dictionary] = [
		{"position": Vector3(-50, 0, 0), "axis_deg": 0.0, "length_m": 40.0, "width_m": 20.0}
	]
	g.set_landing_sites(sites)
	check(g.height_at(-50.0, 0.0) < g.height_at(-50.0, 60.0), "на площадке ниже, чем рядом")
	g._cfg["enabled"] = false
	check(g.height_at(-50.0, 60.0) == 0.0, "трава выключена → 0")
	g.free()


func test_ph_k6_feet_positions_shape() -> void:
	var v := GliderVisual.new()
	check(v.feet_positions() is PackedVector3Array, "feet_positions -> PackedVector3Array")
	check(v.feet_positions().is_empty(), "нет скелета пилота — пустой массив")
	v.free()
