extends SceneTree
## Ретаргет анимаций лагеря camp_pilot.glb (idle, wave, wave_both, walk; скелет MPFB 16 костей) на людей
## Rocketbox (скелет Biped «Bip01 …», 20 костей, build_camp_rocketbox.py) → assets/models/world/rocketbox/<имя>/
## <имя>_anims.res (AnimationLibrary; дорожки «Skeleton/Skeleton3D:Bip01 …» от корня glb).
##   godot --headless --path . --script tools/blender/camp_rocketbox_retarget.gd
## Способ (прототип tools/research/rocketbox/godot_probe/retarget.gd): туловище, голова, ключицы, стопы —
## поворот относительно покоя в мировых осях; плечо, предплечье, бедро, голень — по направлению звена (дуга
## без скручивания); кисть — жёстко к предплечью (как в покое: кисть у camp_pilot в этих анимациях не гнётся).
## Таз — положение пилота, умноженное на отношение высот таза в покое (ноги Rocketbox на 5–9 % короче:
## иначе стопы висят над землёй). Ключи — 30 к/с, зацикливание линейное, как у источника.
## Метаданные библиотеки: stride_m (шаг walk: 1,2 м × отношение длин ног), height_m, colors (из <имя>.json).
## Печатает: высоту лодыжек над землёй (min/max по анимациям) и наибольшее расхождение суставов с пилотом
## относительно таза, см (от разных длин звеньев).

const P := "Bip01 "
const SRC := "res://assets/models/world/camp_pilot.glb"
const DIR := "res://assets/models/world/rocketbox/"
const NAMES := ["Male_Adult_06", "Male_Adult_10", "Female_Adult_12", "Female_Adult_17"]
const ANIMS := ["idle", "wave", "wave_both", "walk"]
const FPS := 30.0
const STRIDE_SRC_M := 1.2  ## длина шага walk у camp_pilot (SC-11)
## [кость Rocketbox, способ, кость пилота, ребёнок пилота (для «dir»), ребёнок Rocketbox (для «dir»)]
const CHAIN := [
	["Pelvis", "delta", "Hips", "", ""],
	["Spine", "delta", "Spine", "", ""],
	["Spine1", "delta", "Chest", "", ""],
	["Spine2", "delta", "Chest", "", ""],
	["Neck", "delta", "Head", "", ""],
	["Head", "delta", "Head", "", ""],
	["L Clavicle", "delta", "Chest", "", ""],
	["R Clavicle", "delta", "Chest", "", ""],
	["L UpperArm", "dir", "UpperArm.L", "Forearm.L", "L Forearm"],
	["L Forearm", "dir", "Forearm.L", "Hand.L", "L Hand"],
	["L Hand", "rigid", "", "", ""],
	["R UpperArm", "dir", "UpperArm.R", "Forearm.R", "R Forearm"],
	["R Forearm", "dir", "Forearm.R", "Hand.R", "R Hand"],
	["R Hand", "rigid", "", "", ""],
	["L Thigh", "dir", "Thigh.L", "Shin.L", "L Calf"],
	["L Calf", "dir", "Shin.L", "Foot.L", "L Foot"],
	["L Foot", "delta", "Foot.L", "", ""],
	["R Thigh", "dir", "Thigh.R", "Shin.R", "R Calf"],
	["R Calf", "dir", "Shin.R", "Foot.R", "R Foot"],
	["R Foot", "delta", "Foot.R", "", ""],
]


static func arc(a: Vector3, b: Vector3) -> Basis:
	var an := a.normalized()
	var bn := b.normalized()
	var c := an.cross(bn)
	var d := clampf(an.dot(bn), -1.0, 1.0)
	if c.length() < 1e-6:
		if d > 0.0:
			return Basis.IDENTITY
		var o := an.cross(Vector3.RIGHT)
		if o.length() < 1e-3:
			o = an.cross(Vector3.UP)
		return Basis(o.normalized(), PI)
	return Basis(c.normalized(), atan2(c.length(), d))


func _initialize() -> void:
	var pilot := (load(SRC) as PackedScene).instantiate() as Node3D
	root.add_child(pilot)
	var psk := pilot.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var ap := pilot.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var p2w := _to_root(psk, pilot)
	var p_hip_rest := (p2w * psk.get_bone_global_rest(psk.find_bone("Hips"))).origin
	var fails := 0
	for nm in NAMES:
		var rb := (load(DIR + nm + "/" + nm + ".glb") as PackedScene).instantiate() as Node3D
		root.add_child(rb)
		var rsk := rb.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
		var r2w := _to_root(rsk, rb)
		var track_base := String(rb.get_path_to(rsk))
		var r_hip_rest := (r2w * rsk.get_bone_global_rest(rsk.find_bone(P + "Pelvis"))).origin
		var k := r_hip_rest.y / p_hip_rest.y
		var lib := AnimationLibrary.new()
		var foot_lo := INF
		var foot_hi := -INF
		var err := {}
		for an in ANIMS:
			var src: Animation = ap.get_animation(an)
			var dst := Animation.new()
			dst.length = src.length
			dst.loop_mode = src.loop_mode
			var tr := {}
			for e in CHAIN:
				var bi := rsk.find_bone(P + e[0])
				var t := dst.add_track(Animation.TYPE_ROTATION_3D)
				dst.track_set_path(t, NodePath("%s:%s" % [track_base, P + e[0]]))
				tr[bi] = t
			var tpos := dst.add_track(Animation.TYPE_POSITION_3D)
			dst.track_set_path(tpos, NodePath("%s:%s" % [track_base, P + "Pelvis"]))
			var n := maxi(1, int(round(src.length * FPS)))
			for f in n:
				var time := src.length * float(f) / float(n)
				_pose_src(psk, src, time)
				var pg := _globals(psk)
				var g := _retarget(psk, pg, p2w, rsk, r2w, k, p_hip_rest, r_hip_rest)
				for bi in tr:
					var par := rsk.get_bone_parent(bi)
					var gp: Transform3D = g[par] if par >= 0 else Transform3D.IDENTITY
					var loc: Transform3D = gp.affine_inverse() * g[bi]
					dst.rotation_track_insert_key(tr[bi], time, loc.basis.get_rotation_quaternion())
				var pel := rsk.find_bone(P + "Pelvis")
				dst.position_track_insert_key(tpos, time, (g[pel] as Transform3D).origin)
				# контроль: стопы над землёй, расхождение суставов с пилотом
				for s in ["L", "R"]:
					var fy := (r2w * (g[rsk.find_bone(P + s + " Foot")] as Transform3D)).origin.y
					foot_lo = minf(foot_lo, fy)
					foot_hi = maxf(foot_hi, fy)
				for pair in [["Hand.R", "R Hand"], ["Head", "Head"], ["Foot.L", "L Foot"]]:
					# относительно таза: начало camp_pilot сдвинуто от таза на 0,2 м по Z
					var pw := (p2w * (pg[psk.find_bone(pair[0])] as Transform3D)).origin - (
						p2w * (pg[psk.find_bone("Hips")] as Transform3D)
					).origin
					var rw := (r2w * (g[rsk.find_bone(P + pair[1])] as Transform3D)).origin - (
						r2w * (g[rsk.find_bone(P + "Pelvis")] as Transform3D)
					).origin
					var key: String = an + ":" + pair[0]
					err[key] = maxf(float(err.get(key, 0.0)), pw.distance_to(rw) * 100.0)
			lib.add_animation(an, dst)
		var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + nm + "/" + nm + ".json"))
		var leg_r := r_hip_rest.y / p_hip_rest.y
		lib.set_meta("stride_m", snappedf(STRIDE_SRC_M * leg_r, 0.001))
		lib.set_meta("height_m", float(info.height_m))
		lib.set_meta("colors", info.colors_srgb)
		var out: String = DIR + nm + "/" + nm + "_anims.res"
		var rc := ResourceSaver.save(lib, out, ResourceSaver.FLAG_COMPRESS)
		fails += 1 if rc != OK else 0
		var e2 := {}
		for key in err:
			e2[key] = snappedf(err[key], 0.1)
		print("RETARGET %s k=%.3f stride=%.3f foot_y=[%.3f, %.3f] err_cm=%s -> %s (%d)" % [
			nm, k, float(lib.get_meta("stride_m")), foot_lo, foot_hi, JSON.stringify(e2), out, rc])
		rb.queue_free()
	quit(1 if fails else 0)


## Трансформ узла n в осях корня сцены top (вне дерева global_transform недоступен).
func _to_root(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c: Node = n
	while c != top and c is Node3D:
		t = (c as Node3D).transform * t
		c = c.get_parent()
	return t


## Глобальные позы костей (в осях скелета) из локальных: {индекс: Transform3D}; родители раньше детей.
func _globals(sk: Skeleton3D) -> Dictionary:
	var g := {}
	for i in sk.get_bone_count():
		var loc := Transform3D(
			Basis(sk.get_bone_pose_rotation(i)).scaled(sk.get_bone_pose_scale(i)), sk.get_bone_pose_position(i)
		)
		var par := sk.get_bone_parent(i)
		g[i] = (g[par] as Transform3D) * loc if par >= 0 else loc
	return g


## Поза пилота в момент time: покой + значения дорожек (поворот, положение) анимации.
func _pose_src(sk: Skeleton3D, a: Animation, time: float) -> void:
	sk.reset_bone_poses()
	for t in a.get_track_count():
		var b := sk.find_bone(String(a.track_get_path(t).get_subname(0)))
		if b < 0:
			continue
		match a.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				sk.set_bone_pose_rotation(b, a.rotation_track_interpolate(t, time))
			Animation.TYPE_POSITION_3D:
				sk.set_bone_pose_position(b, a.position_track_interpolate(t, time))
			Animation.TYPE_SCALE_3D:
				sk.set_bone_pose_scale(b, a.scale_track_interpolate(t, time))


## Глобальные (в осях скелета Rocketbox) позы костей цепочки: {индекс кости: Transform3D}.
func _retarget(
	psk: Skeleton3D, pg: Dictionary, p2w: Transform3D, rsk: Skeleton3D, r2w: Transform3D, k: float,
	p_hip_rest: Vector3, r_hip_rest: Vector3
) -> Dictionary:
	var g := {}
	var w2r := r2w.affine_inverse()
	for i in rsk.get_bone_count():
		var e: Array = []
		for c in CHAIN:
			if P + c[0] == rsk.get_bone_name(i):
				e = c
		var par := rsk.get_bone_parent(i)
		var gpar: Transform3D = g.get(par, Transform3D.IDENTITY) if par >= 0 else Transform3D.IDENTITY
		var gp: Transform3D = gpar * rsk.get_bone_rest(i)
		if e.is_empty():
			g[i] = gp
			continue
		var rest_w := r2w * rsk.get_bone_global_rest(i)
		var q_w := rest_w.basis
		match String(e[1]):
			"delta":
				var b := psk.find_bone(e[2])
				var pr := (p2w * (pg[b] as Transform3D)).basis
				var prr := (p2w * psk.get_bone_global_rest(b)).basis
				q_w = pr * prr.inverse() * rest_w.basis
			"dir":
				var b0 := (p2w * (pg[psk.find_bone(e[2])] as Transform3D)).origin
				var b1 := (p2w * (pg[psk.find_bone(e[3])] as Transform3D)).origin
				var ch := rsk.find_bone(P + e[4])
				var src_dir := (r2w * rsk.get_bone_global_rest(ch)).origin - rest_w.origin
				q_w = arc(src_dir, b1 - b0) * rest_w.basis
			"rigid":
				q_w = (r2w * gp).basis
		var org := gp.origin
		if e[0] == "Pelvis":
			var hw := (p2w * (pg[psk.find_bone("Hips")] as Transform3D)).origin
			var d := hw - p_hip_rest
			org = (w2r * Transform3D(Basis.IDENTITY, r_hip_rest + d * k)).origin
		g[i] = Transform3D((w2r.basis * q_w).orthonormalized(), org)
	return g
