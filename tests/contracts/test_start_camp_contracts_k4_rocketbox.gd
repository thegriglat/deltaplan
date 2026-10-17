extends TestCase
## Контракт SC-K4 v3 (docs/contracts/start-camp.md): ближние люди лагеря — модели Microsoft Rocketbox
## (assets/models/world/rocketbox/<имя>/): скелет Biped из 20 костей «Bip01 …», меши Body_LOD0..2 на одном
## скелете, лицом к −Z, начало на земле, текстуры ≤ 512 с мипмапами, библиотека анимаций ретаргета
## (idle/wave/wave_both/walk, зациклены), метаданные, размер ≤ 5 МБ на человека, LICENSE рядом.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_camp_contracts_k4_rocketbox

const DIR := "res://assets/models/world/rocketbox/"
const ANIMS := ["idle", "wave", "wave_both", "walk"]
const BUDGET := [9000, 5000, 2500]
const BODY := ["Pelvis", "Spine", "Spine1", "Spine2", "Neck", "Head", "L Clavicle", "L UpperArm", "L Forearm",
	"L Hand", "R Clavicle", "R UpperArm", "R Forearm", "R Hand", "L Thigh", "L Calf", "L Foot", "R Thigh",
	"R Calf", "R Foot"]


func _names() -> Array:
	return Config.get_config("easter_eggs").eggs.people.near_models


func _tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return n


func test_license() -> void:
	var f := FileAccess.open(DIR + "LICENSE-rocketbox.md", FileAccess.READ)
	check(f != null, "LICENSE-rocketbox.md рядом с моделями")
	if f != null:
		var t := f.get_as_text()
		check(t.contains("Copyright (c) 2020 Microsoft") and t.contains("MIT"), "текст MIT и уведомление Microsoft")


func test_models() -> void:
	var names := _names()
	check(names.size() == 4, "четыре модели в near_models (%d)" % names.size())
	for nm in names:
		_check_model(String(nm))


func _check_model(nm: String) -> void:
	var glb := "%s%s/%s.glb" % [DIR, nm, nm]
	var ps := load(glb) as PackedScene
	check(ps != null, "%s: glb грузится" % nm)
	if ps == null:
		return
	var total := 0
	for fn in DirAccess.get_files_at(DIR + nm):
		if not fn.ends_with(".import"):
			var f := FileAccess.open(DIR + nm + "/" + fn, FileAccess.READ)
			total += f.get_length() if f else 0
	check(total <= 5 * 1024 * 1024, "%s: файлы ≤ 5 МБ (%.2f МБ)" % [nm, total / 1048576.0])
	var root := ps.instantiate()
	var sk := root.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	check(sk.get_bone_count() == BODY.size(), "%s: костей %d" % [nm, sk.get_bone_count()])
	for b in BODY:
		check(sk.find_bone("Bip01 " + b) >= 0, "%s: кость Bip01 %s" % [nm, b])
	var lo := INF
	var hi := -INF
	var toe_z := 0.0
	for j in 3:
		var mi := root.find_child("Body_LOD%d" % j, true, false) as MeshInstance3D
		check(mi != null and mi.get_parent() == sk, "%s: Body_LOD%d под Skeleton3D" % [nm, j])
		if mi == null:
			continue
		var t := _tris(mi.mesh)
		check(t <= BUDGET[j] and t > BUDGET[j] * 0.6, "%s: LOD%d %d треугольников (≤ %d)" % [nm, j, t, BUDGET[j]])
		if j != 0:
			continue
		check(mi.mesh.get_surface_count() == 3, "%s: 3 материала (тело, голова, волосы)" % nm)
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as BaseMaterial3D
			var tex := mat.albedo_texture if mat else null
			check(tex != null, "%s: у материала %d есть текстура" % [nm, s])
			if tex == null:
				continue
			check(tex.get_width() <= 512 and tex.get_height() <= 512, "%s: текстура ≤ 512 (%d)" % [nm, tex.get_width()])
			var img := tex.get_image()
			check(img != null and img.has_mipmaps() and img.is_compressed(), "%s: текстура сжата, с мипмапами" % nm)
		for s in mi.mesh.get_surface_count():  # рост — по всем материалам (макушка — волосы)
			for v in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
				lo = minf(lo, v.y)
				hi = maxf(hi, v.y)
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var low := 0
		for v in verts:
			if v.y < lo + 0.03:
				toe_z += v.z
				low += 1
		toe_z /= maxf(1.0, low)
	check(absf(lo) < 0.03, "%s: начало на земле (низ %.3f)" % [nm, lo])
	check(hi > 1.6 and hi < 1.9, "%s: рост %.2f м" % [nm, hi])
	check(toe_z < 0.0, "%s: лицом к −Z (носки впереди, z %.3f)" % [nm, toe_z])
	root.free()
	var lib := load("%s%s/%s_anims.res" % [DIR, nm, nm]) as AnimationLibrary
	check(lib != null, "%s: библиотека анимаций" % nm)
	if lib == null:
		return
	for a in ANIMS:
		var an := lib.get_animation(a)
		check(an != null and an.loop_mode == Animation.LOOP_LINEAR, "%s: %s есть и зациклена" % [nm, a])
		if an == null:
			continue
		for t in an.get_track_count():
			var path := String(an.track_get_path(t))
			check(path.begins_with("Skeleton/Skeleton3D:Bip01 "), "%s: дорожка %s" % [nm, path])
			if not path.begins_with("Skeleton/Skeleton3D:Bip01 "):
				break
	var stride := float(lib.get_meta("stride_m", 0.0))
	check(stride > 0.9 and stride < 1.3, "%s: шаг walk %.2f м" % [nm, stride])
	var cols: Dictionary = lib.get_meta("colors", {})
	for k in ["top", "bottom", "skin"]:
		check((cols.get(k, []) as Array).size() == 3, "%s: цвет %s" % [nm, k])
	check(absf(float(lib.get_meta("height_m", 0.0)) - hi) < 0.05, "%s: рост в метаданных" % nm)
