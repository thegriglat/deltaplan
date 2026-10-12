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
