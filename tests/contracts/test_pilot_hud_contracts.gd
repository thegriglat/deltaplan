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
