extends TestCase
## Контракт SC-K4 v2 (docs/contracts/start-camp.md): ближний человек camp_pilot.glb — тело пилота без
## подвески и шлема, скелет из 16 костей пилота, анимации idle/wave/wave_both/walk (зациклены, без
## смещения корня), рост 1,78 м, начало на земле, бюджет, материалы.

const GLB := "res://assets/models/world/camp_pilot.glb"
const BONES := ["Hips", "Spine", "Chest", "Head", "UpperArm.L", "Forearm.L", "Hand.L", "Thigh.L", "Shin.L",
	"Foot.L", "UpperArm.R", "Forearm.R", "Hand.R", "Thigh.R", "Shin.R", "Foot.R"]
const ANIMS := {"idle": 4.0, "wave": 1.2, "wave_both": 1.2}
const MATS := ["Jacket", "Trousers", "Skin", "Hair", "Boot", "Sole"]
const BAD_NAMES := ["Helmet", "Visor", "Pod", "Strap", "Glove", "Harness", "Cocoon", "Collar"]


func _tris(mi: MeshInstance3D) -> int:
	var n := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return n


func test_camp_pilot() -> void:
	check(ResourceLoader.exists(GLB), "K4v2: есть " + GLB)
	var ps := load(GLB) as PackedScene
	check(ps != null, "K4v2: glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var f := FileAccess.open(GLB, FileAccess.READ)
	check(f != null and f.get_length() <= 700 * 1024, "K4v2: glb ≤ 700 КБ (%d)" % (f.get_length() if f else -1))
	# ноды
	var person := root.find_child("Person", true, false)
	check(person != null, "K4v2: нода Person")
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	check(skel != null, "K4v2: Skeleton3D")
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(ap != null, "K4v2: AnimationPlayer")
	var meshes := []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n)
	check(meshes.size() == 1, "K4v2: один меш на всё тело (%d)" % meshes.size())
	for n in root.find_children("*", "", true, false):
		for bad in BAD_NAMES:
			check(String(n.name).findn(bad) < 0, "K4v2: нет ноды %s (%s)" % [n.name, bad])
	if meshes.is_empty() or skel == null or ap == null:
		root.free()
		return
	var mi := meshes[0] as MeshInstance3D
	check(mi.name == "PersonBody", "K4v2: меш PersonBody (%s)" % mi.name)
	check(skel.is_ancestor_of(mi), "K4v2: PersonBody под Skeleton3D")
	# кости
	for b in BONES:
		check(skel.find_bone(b) >= 0, "K4v2: кость " + b)
	check(skel.get_bone_count() == BONES.size(), "K4v2: костей %d (нет подвески/кокона/фала)" % skel.get_bone_count())
	# бюджет, материалы, влияния
	var t := _tris(mi)
	check(t <= 4500, "K4v2: %d треугольников ≤ 4500" % t)
	var names := []
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		names.append(m.resource_name)
		check(m.resource_name in MATS, "K4v2: материал %s из контракта" % m.resource_name)
		for bad in BAD_NAMES:
			check(m.resource_name.findn(bad) < 0, "K4v2: нет материала %s" % m.resource_name)
	for m in MATS:
		check(m in names, "K4v2: материал %s есть" % m)
	check(names.size() <= 6, "K4v2: материалов %d ≤ 6" % names.size())
	var max_inf := 0
	var top := -INF
	var low := INF
	var xs := [INF, -INF]
	var zs_feet := [INF, -INF]
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var stride := w.size() / maxi(v.size(), 1)
		for i in v.size():
			var c := 0
			for k in stride:
				if w[i * stride + k] > 1e-4:
					c += 1
			max_inf = maxi(max_inf, c)
			top = maxf(top, v[i].y)
			low = minf(low, v[i].y)
			xs[0] = minf(xs[0], v[i].x)
			xs[1] = maxf(xs[1], v[i].x)
			if v[i].y < 0.05:
				zs_feet[0] = minf(zs_feet[0], v[i].z)
				zs_feet[1] = maxf(zs_feet[1], v[i].z)
	check(max_inf <= 4, "K4v2: влияний на вершину ≤ 4 (%d)" % max_inf)
	# вершины меша — в осях модели (поза покоя)
	check(absf(top - low - 1.78) <= 0.03 + 0.012, "K4v2: рост %.3f м ≈ 1,78 ±0,03" % (top - low))
	check(absf(low) <= 0.02, "K4v2: подошвы на земле (низ %.3f)" % low)
	check(absf(xs[0] + xs[1]) <= 0.08, "K4v2: центр по X между стоп (%.3f..%.3f)" % [xs[0], xs[1]])
	check(zs_feet[0] < -0.12 and zs_feet[1] < 0.15, "K4v2: лицом к −Z: носки вперёд (%.3f..%.3f)" % [zs_feet[0], zs_feet[1]])
	# анимации
	for a in ["idle", "wave", "wave_both", "walk"]:
		check(ap.has_animation(a), "K4v2: анимация " + a)
		if not ap.has_animation(a):
			continue
		var an := ap.get_animation(a)
		check(an.loop_mode == Animation.LOOP_LINEAR, "K4v2: %s зациклена" % a)
		if ANIMS.has(a):
			check(absf(an.length - ANIMS[a]) <= 0.25, "K4v2: %s %.2f с ≈ %.1f" % [a, an.length, ANIMS[a]])
		else:
			check(an.length >= 0.9 and an.length <= 1.3, "K4v2: walk %.2f с ~1,1" % an.length)
		# без смещения корня: Hips в конце = в начале, по горизонтали почти не уходит
		for ti in an.get_track_count():
			var p := String(an.track_get_path(ti))
			if p.ends_with(":Hips") and an.track_get_type(ti) == Animation.TYPE_POSITION_3D:
				var n := an.track_get_key_count(ti)
				var a0: Vector3 = an.track_get_key_value(ti, 0)
				var a1: Vector3 = an.track_get_key_value(ti, n - 1)
				check(a0.distance_to(a1) <= 0.002, "K4v2: %s: цикл Hips замкнут" % a)
				var hmax := 0.0
				for k in n:
					var q: Vector3 = an.track_get_key_value(ti, k)
					hmax = maxf(hmax, Vector2(q.x - a0.x, q.z - a0.z).length())
				check(hmax <= 0.06, "K4v2: %s: таз не уходит по горизонтали (%.3f м)" % [a, hmax])
	root.free()
