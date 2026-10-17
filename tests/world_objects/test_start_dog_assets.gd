extends TestCase
## Контракт DOG-K2/DOG-K3 (docs/contracts/start-dog.md): модель собаки dog.glb и лай bark_<n>.ogg.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_dog_assets

const DIR := "res://assets/easter_eggs/start_dog/"
const MODEL := DIR + "dog.glb"
const NEED: PackedStringArray = ["gallop", "trot", "idle", "bark", "lie"]
const WANT: PackedStringArray = ["walk", "sniff", "sit"]
const GAITS: PackedStringArray = ["gallop", "trot", "walk"]


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.start_dog


func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)


## Преобразование узла относительно корня сцены (сцена не в дереве).
func _xf(n: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p := n
	while p != null and p != root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func test_model() -> void:
	var ps: PackedScene = load(MODEL)
	check(ps != null, "dog.glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var nodes: Array = []
	_walk(root, nodes)
	var skel: Skeleton3D = null
	var ap: AnimationPlayer = null
	var tris := 0
	var mats := {}
	var aabb := AABB()
	var first := true
	for n in nodes:
		if n is Skeleton3D and skel == null:
			skel = n
		if n is AnimationPlayer and ap == null:
			ap = n
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mesh := mi.mesh
			for s in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(s)
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				tris += (
					idx.size() / 3
					if not idx.is_empty()
					else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
				)
				var m := mesh.surface_get_material(s)
				if m != null:
					mats[m.get_rid()] = m
			# скиновый меш glTF: вершины уже в пространстве корня (узел меша при скиннинге не влияет)
			var box := mesh.get_aabb() if mi.skin != null else _xf(mi, root) * mesh.get_aabb()
			aabb = box if first else aabb.merge(box)
			first = false
	check(skel != null, "есть Skeleton3D")
	check(ap != null, "есть AnimationPlayer")
	check(tris > 0 and tris <= 5000, "треугольников LOD0 ≤ 5000: %d" % tris)
	check(mats.size() >= 1 and mats.size() <= 2, "материалов ≤ 2: %d" % mats.size())
	for m in mats.values():
		if m is BaseMaterial3D:
			check(
				(m as BaseMaterial3D).vertex_color_use_as_albedo,
				"цвет — из вершин (dog_material.tres через .import)"
			)
			var tex := (m as BaseMaterial3D).albedo_texture
			if tex != null:
				check(
					tex.get_width() <= 512 and tex.get_height() <= 512,
					"текстура ≤ 512: %dx%d" % [tex.get_width(), tex.get_height()]
				)
	var sz := aabb.size
	check(sz.y >= 0.45 and sz.y <= 0.75, "высота 0,45–0,75 м: %.3f" % sz.y)
	check(sz.z > sz.x, "длина по Z (%.3f) больше ширины по X (%.3f)" % [sz.z, sz.x])
	check(absf(aabb.position.y) < 0.03, "низ на земле (y=0): %.3f" % aabb.position.y)
	# морда в −Z: голова (кость Head) впереди середины по Z
	if skel != null:
		var hi := skel.find_bone("Head")
		check(hi >= 0, "кость Head есть")
		if hi >= 0:
			var head := _xf(skel, root) * skel.get_bone_global_rest(hi).origin
			check(head.z < aabb.get_center().z - 0.2, "голова в −Z: z=%.3f" % head.z)
	if ap != null:
		for a in NEED:
			check(ap.has_animation(a), "клип %s есть" % a)
		for a in WANT:
			check(ap.has_animation(a), "желательный клип %s есть" % a)
		for a in GAITS:
			if ap.has_animation(a):
				check(
					ap.get_animation(a).loop_mode != Animation.LOOP_NONE, "ходовой %s зациклен" % a
				)
	root.free()


func test_config_speeds() -> void:
	var an: Dictionary = _cfg().get("anims", {})
	for a in ["gallop", "trot", "walk"]:
		var d: Dictionary = an.get(a, {})
		check(float(d.get("speed_ms", 0.0)) > 0.0, "%s.speed_ms > 0" % a)
		check(float(d.get("cycle_s", 0.0)) > 0.0, "%s.cycle_s > 0" % a)
	var b: Dictionary = an.get("bark", {})
	var at: Array = b.get("bark_at_s", [])
	check(at.size() >= 1 and at.size() <= 2, "bark: 1–2 гавка за цикл")
	for t in at:
		check(float(t) >= 0.0 and float(t) < float(b.get("cycle_s", 0.0)), "bark_at_s в цикле: %s" % t)


func test_barks() -> void:
	var n := 0
	for i in range(1, 6):
		var p := DIR + "bark_%d.ogg" % i
		if not ResourceLoader.exists(p):
			continue
		var s: AudioStream = load(p)
		check(s != null, "%s грузится" % p)
		if s == null:
			continue
		n += 1
		var len_s := s.get_length()
		check(len_s >= 0.1 and len_s <= 0.6, "%s: длина 0,1–0,6 с: %.3f" % [p, len_s])
	check(n >= 2 and n <= 4, "гавков 2–4: %d" % n)
