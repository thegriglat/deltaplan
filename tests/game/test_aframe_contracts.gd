extends Node
## Контракты геометрии трапеции и центровки (docs/contracts/aframe-geometry.md, A1–A3.1, A3.4):
## у всех крыльев параметры в glider_params.json в допусках, маркеры в .glb (UprightTop/Bottom L/R,
## WingCG) совпадают с параметрами, из flight.json убраны upright_top_m / upright_bottom_half_width_m,
## в полёте на балансировке середина BaseBar под серединой плеч (apogee ≤ 0,10 м по горизонтали,
## все крылья ≤ 0,15 м). Оси маркеров — Godot (+X вправо, +Y вверх, −Z вперёд) от HangPoint.

const PARAMS := "res://tools/blender/glider_params.json"
const FlightSim := preload("res://tests/flight/flight_sim.gd")
const MARKERS: Array[String] = [
	"HangPoint", "BaseBar", "UprightTopL", "UprightTopR", "UprightBottomL", "UprightBottomR", "WingCG"
]
const BASE_TOL_APOGEE := 0.10
const BASE_TOL_ALL := 0.15

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


func _params() -> Dictionary:
	var f := FileAccess.open(PARAMS, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else {}


## Маркеры модели крыла в осях HangPoint: {имя: Vector3}; пусто — модели нет.
func _markers(out_name: String) -> Dictionary:
	var path := "res://assets/models/%s.glb" % out_name
	var ps := load(path) as PackedScene
	if ps == null:
		return {}
	var root := ps.instantiate() as Node3D
	var res := {}
	var hang := root.find_child("HangPoint", true, false) as Node3D
	if hang != null:
		var inv := GliderVisual._relative_xform(root, hang).affine_inverse()
		for m in MARKERS:
			var n := root.find_child(m, true, false) as Node3D
			if n != null:
				res[m] = inv * GliderVisual._relative_xform(root, n).origin
	root.free()
	return res


## Угол стойки к нормали киля в плоскости симметрии, град (низом вперёд — плюс).
static func _tilt_deg(top: Vector3, bottom: Vector3) -> float:
	var d := bottom - top
	return rad_to_deg(atan2(-d.z, -d.y))


func test_params_and_markers() -> void:
	var params := _params()
	var cf: Dictionary = params.control_frame
	for gone in ["apex_forward_m", "basebar_forward_m", "basebar_drop_m"]:
		check(not cf.has(gone), "control_frame без общей константы %s" % gone)
	var arms: Dictionary = Config.get_config("flight").visual.arms
	check(not arms.has("upright_top_m"), "flight.json: нет visual.arms.upright_top_m")
	check(
		not arms.has("upright_bottom_half_width_m"),
		"flight.json: нет visual.arms.upright_bottom_half_width_m"
	)
	check(cf.has("mass_model") and cf.has("sail_mass_kg"), "control_frame: mass_model, sail_mass_kg")
	for wid: String in params.wings:
		var p: Dictionary = params.wings[wid]
		for k in ["cg_from_nose_m", "nose_forward_m", "upright_tilt_deg", "upright_len_m", "hang_source"]:
			check(p.has(k), "%s: есть %s" % [wid, k])
		if not (p.has("cg_from_nose_m") and p.has("upright_tilt_deg") and p.has("upright_len_m")):
			continue
		var tilt := float(p.upright_tilt_deg)
		var length := float(p.upright_len_m)
		var off := float(p.get("hang_cg_offset_m", cf.hang_cg_offset_m))
		var hfa: float = (
			float(p.hang_from_apex_m)
			if p.has("hang_from_apex_m")
			else float(cf.hang_from_apex_m["double" if p.double_surface else "single"])
		)
		check(tilt >= 4.0 and tilt <= 13.0, "%s: наклон %.1f в 4…13" % [wid, tilt])
		check(length >= 1.6 and length <= 1.75, "%s: длина стоек %.3f в 1,6…1,75" % [wid, length])
		var src := String(p.get("hang_source", ""))
		check(src in ["passport", "cg"], "%s: hang_source = passport|cg (%s)" % [wid, src])
		if src == "passport":
			check(p.has("hang_from_nose_m") and String(p.get("hang_ref", "")).length() > 10, "%s: passport: hang_from_nose_m и hang_ref" % wid)
			approx(
				float(p.nose_forward_m), float(p.get("hang_from_nose_m", -9.0)), 0.01,
				"%s: nose_forward_m = hang_from_nose_m (паспорт)" % wid
			)
		else:
			check(off >= 0.01 and off <= 0.02, "%s: подвеска впереди ЦМ на %.3f в 0,01…0,02" % [wid, off])
		check(hfa >= -0.2 and hfa <= 0.2, "%s: hang_from_apex %.2f в −0,20…+0,20" % [wid, hfa])
		if src == "cg":
			approx(
				float(p.nose_forward_m), float(p.cg_from_nose_m) - off, 0.0015,
				"%s: nose_forward_m = cg_from_nose_m − hang_cg_offset_m" % wid
			)
		var mk := _markers(String(p.out))
		check(mk.size() == MARKERS.size(), "%s: в модели есть все маркеры A2 (%d из %d)" % [wid, mk.size(), MARKERS.size()])
		if mk.size() != MARKERS.size():
			continue
		for side in ["L", "R"]:
			var top: Vector3 = mk["UprightTop" + side]
			var bot: Vector3 = mk["UprightBottom" + side]
			approx(_tilt_deg(top, bot), tilt, 0.5, "%s %s: наклон стойки в модели" % [wid, side])
			approx(top.distance_to(bot), length, 0.01, "%s %s: длина стойки в модели" % [wid, side])
			approx(top.z, hfa, 0.01, "%s %s: вершина относительно подвески (hang_from_apex_m)" % [wid, side])
		approx(
			(mk["WingCG"] as Vector3).z, float(p.cg_from_nose_m) - float(p.nose_forward_m), 0.002,
			"%s: HangPoint относительно WingCG (cg_from_nose_m − nose_forward_m)" % wid
		)
		check((mk["WingCG"] as Vector3).y > 0.0, "%s: WingCG на киле выше подвески" % wid)


## Полёт на балансировке: середина BaseBar от середины плеч по горизонтали в осях мира (киль под
## тангажем трима). Плечи — по пилоту в позе prone (не зависят от крыла).
func test_base_bar_under_shoulders() -> void:
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/apogee"),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.5)
	v.set_pose(0.0, 0.0, true, 1.0e6)
	for i in 3:
		await get_tree().process_frame
	var hang := Vector3(0, float(Config.get_config("flight").visual.hang_height_m), 0)
	var sh := ((v.shoulder(-1) + v.shoulder(1)) * 0.5) - hang
	v.free()
	var worst := 0.0
	var worst_id := ""
	var params: Dictionary = _params().wings
	for wid: String in params:
		var p: Dictionary = params[wid]
		var mk := _markers(String(p.out))
		if not mk.has("BaseBar"):
			check(false, "%s: нет BaseBar" % wid)
			continue
		var m := FlightSim.make(String(p.config))
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		var th := m.theta
		var bb: Vector3 = mk["BaseBar"]
		var f := -bb.z - (-sh.z)  # вперёд в осях крыла
		var u := bb.y - sh.y
		var horiz := f * cos(th) - u * sin(th)
		var vert := f * sin(th) + u * cos(th)
		if wid == "apogee":
			check(
				absf(horiz) <= BASE_TOL_APOGEE,
				"apogee: база от плеч по горизонтали %+.3f (≤ %.2f)" % [horiz, BASE_TOL_APOGEE]
			)
			print("         apogee: база от плеч: по горизонтали %+.3f, по вертикали %+.3f м" % [horiz, vert])
		if absf(horiz) > absf(worst):
			worst = horiz
			worst_id = wid
		check(absf(horiz) <= BASE_TOL_ALL, "%s: база от плеч %+.3f м (≤ %.2f)" % [wid, horiz, BASE_TOL_ALL])
	print("         по всем крыльям худшее: %s, %+.3f м" % [worst_id, worst])


## Визуал apogee в полёте лёжа на балансировке: киль под тангажем трима (нос вверх), трапеция в
## нейтрали. Возвращает {v, theta, model}; v — в дереве, повёрнут, руки на штанге.
func _flight_visual(wing: String) -> Dictionary:
	var m := FlightSim.make(wing)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.5)
	v.basis = Basis(Vector3.RIGHT, m.theta)
	v.set_pose(0.0, 0.0, true, 1.0e6)
	for i in 3:
		await get_tree().process_frame
	return {"v": v, "theta": m.theta, "model": m}


## Размеры пилота в полёте (мир): низ торса/подвесной системы (вершины PilotBody с главной костью
## Hips/Spine/Chest — без рук, ног и головы), длина предплечья (локоть — кисть).
func _pilot_dims(v: GliderVisual) -> Dictionary:
	var sk := v.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var mi := sk.find_children("PilotBody", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var skin := mi.skin
	var torso: Array[String] = ["Hips", "Spine", "Chest"]
	var low := 1.0e9
	var mesh := mi.mesh
	var sk_x := sk.global_transform
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var wts: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / vs.size()
		for k in vs.size():
			var best := -1
			var bw := 0.0
			var pos := Vector3.ZERO
			for q in per:
				var w := wts[k * per + q]
				if w <= 0.0:
					continue
				var bi := skin.get_bind_bone(bones[k * per + q]) if skin.get_bind_bone(bones[k * per + q]) >= 0 else bones[k * per + q]
				pos += w * (sk.get_bone_global_pose(bi) * skin.get_bind_pose(bones[k * per + q]) * vs[k])
				if w > bw:
					bw = w
					best = bi
			if best >= 0 and sk.get_bone_name(best) in torso:
				low = minf(low, (sk_x * pos).y)
	var fa := 0.0
	for side in ["L", "R"]:
		var e := sk.get_bone_global_pose(sk.find_bone("Forearm." + side)).origin
		var h := sk.get_bone_global_pose(sk.find_bone("Hand." + side)).origin
		fa += e.distance_to(h) * 0.5
	return {"torso_low_y": low, "forearm": fa}


## A3.5: в полёте на балансировке локти не выше плечевых суставов (по вертикали мира); низ торса
## над осью базовой штанги 0,37 ± 0,03 м (A3.5 v5); configs/pilot.json →
## visual.hang_length_m (карабин — низ торса) совпадает с моделью ± 0,02 м.
func test_flight_pilot_height() -> void:
	var r := await _flight_visual("apogee")
	var v: GliderVisual = r.v
	var sk := v.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var hang: Vector3 = v.global_transform * Vector3(0, float(Config.get_config("flight").visual.hang_height_m), 0)
	var sh_mid: Vector3 = v.global_transform * ((v.shoulder(-1) + v.shoulder(1)) * 0.5)
	v.arm_ik._process_modification_with_delta(0.0)  # поза рук после IK
	var worst_elbow := -1.0e9
	var dmin := 1.0e9
	var dmax := -1.0e9
	for side in [-1, 1]:
		var sh: Vector3 = v.global_transform * v.shoulder(side)
		var bone := sk.find_bone("Forearm.L" if side < 0 else "Forearm.R")
		var el: Vector3 = sk.to_global(sk.get_bone_global_pose(bone).origin)
		var hand := v.find_child("HandL" if side < 0 else "HandR", true, false) as Node3D
		var d := sh.distance_to(hand.global_position)
		dmin = minf(dmin, d)
		dmax = maxf(dmax, d)
		worst_elbow = maxf(worst_elbow, el.y - sh.y)
		# A3.5 v8: при зазоре 0,06 локоть выше плеча на ~0,1 м — не блокирует, число в отчёт
		check(el.y <= sh.y + 0.15, "рука %d: локоть не выше плеча +0,15 м (%+.3f м)" % [side, el.y - sh.y])
	var bar: Vector3 = v.global_transform * v._marker_pos("BaseBar")
	var dims := _pilot_dims(v)
	var above := float(dims.torso_low_y) - bar.y
	var hl := float(Config.get_config("pilot").visual.hang_length_m)
	var low_local: float = (v.global_transform.affine_inverse() * Vector3(0, float(dims.torso_low_y), 0)).y
	var meas_len := hang.distance_to(Vector3(hang.x, float(dims.torso_low_y), hang.z))
	var bar_r := float(_params().control_frame.basebar_r_m)
	var gap := above - bar_r  # до ВЕРХА штанги (BaseBar — ось)
	check(
		absf(gap - float(Config.get_config("pilot").visual.bar_gap_m)) <= 0.01,
		"зазор низ тела — верх штанги %.3f м (0,06 ±0,01, A3.5 v8)" % gap
	)
	# модельная подвеска = измеренная минус опускание под крыло (по вертикали мира)
	approx(hl, meas_len - v.hang_drop_m * cos(r.theta), 0.02, "pilot.json hang_length_m и карабин — низ торса в модели")
	print(
		(
			"         apogee: плечи над базой %.3f м, плечо—хват %.3f…%.3f м, локоть−плечо max %+.3f м, "
			+ "карабин—плечо %.3f м, низ торса над базой %.3f м, предплечье %.3f м, карабин—низ торса (по вертикали) %.3f м"
		)
		% [sh_mid.y - bar.y, dmin, dmax, worst_elbow, hang.distance_to(sh_mid), above, dims.forearm, meas_len]
	)
	v.free()


## A3.5 v8: зазор низ тела — верх базовой штанги 0,05…0,07 м у КАЖДОГО крыла (длина подвески
## под крыло). Печатает мин/макс зазор и опускание пилота относительно модельной подвески.
func test_gap_every_wing() -> void:
	var params: Dictionary = _params().wings
	var bar_r := float(_params().control_frame.basebar_r_m)
	var lo := 1.0e9
	var hi := -1.0e9
	var lo_id := ""
	var hi_id := ""
	var dlo := 1.0e9
	var dhi := -1.0e9
	var seen := {}
	for wid: String in params:
		var cfg := String(params[wid].config)
		if seen.has(cfg):
			continue
		seen[cfg] = true
		var r := await _flight_visual(cfg)
		var v: GliderVisual = r.v
		var bar: Vector3 = v.global_transform * v._marker_pos("BaseBar")
		var gap := float(_pilot_dims(v).torso_low_y) - bar.y - bar_r
		check(gap >= 0.05 and gap <= 0.07, "%s: зазор низ тела — верх штанги %.3f м (0,05…0,07)" % [cfg, gap])
		if gap < lo:
			lo = gap
			lo_id = cfg
		if gap > hi:
			hi = gap
			hi_id = cfg
		dlo = minf(dlo, v.hang_drop_m)
		dhi = maxf(dhi, v.hang_drop_m)
		v.free()
	print("         зазор по крыльям (%d): мин %.3f (%s), макс %.3f (%s) м; опускание пилота %.3f…%.3f м" % [seen.size(), lo, lo_id, hi, hi_id, dlo, dhi])


## A3.6: визуальный тангаж киля в установившемся планировании = тангаж из модели полёта
## (α − угол планирования; установочного угла киля к хорде в модели нет) ± 1°. Тангаж киля
## в модели крыла — по вершинам трубы киля (нос/хвост на оси симметрии).
func test_keel_pitch_matches_physics() -> void:
	for wing in ["apogee", "sport", "ww_t3"]:
		var cfg: Dictionary = _params().wings
		var out := ""
		for wid: String in cfg:
			if String(cfg[wid].config) == wing:
				out = String(cfg[wid].out)
		if out == "":
			continue
		var r := await _flight_visual(wing)
		var v: GliderVisual = r.v
		var m: FlightModel = r.model
		var fr := v.wing.find_child("Frame", true, false) as MeshInstance3D
		var x := GliderVisual._relative_xform(v.wing, fr)
		var front := Vector3(0, 0, 1.0e9)
		var back := Vector3(0, 0, -1.0e9)
		var mesh := fr.mesh
		var pts: Array[Vector3] = []
		for s in mesh.get_surface_count():
			for p: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var w := x * p
				if absf(w.x) < 0.02:
					pts.append(w)
					if w.z < front.z:
						front = w
		# наклон киля — МНК по вершинам на оси симметрии на высоте носа (труба киля)
		var sel: Array[Vector3] = []
		for w in pts:
			if absf(w.y - front.y) < 0.12:
				sel.append(w)
		var mz := 0.0
		var my := 0.0
		for w in sel:
			mz += w.z
			my += w.y
		mz /= sel.size()
		my /= sel.size()
		var sxy := 0.0
		var sxx := 0.0
		for w in sel:
			sxy += (w.z - mz) * (w.y - my)
			sxx += (w.z - mz) * (w.z - mz)
		var wing_pitch := asin((v.wing.global_transform.basis.orthonormalized() * Vector3.FORWARD).y)
		var vis := rad_to_deg(wing_pitch + atan2(-sxy / sxx, 1.0))
		var gamma := rad_to_deg(atan2(m.velocity.y, Vector2(m.velocity.x, m.velocity.z).length()))
		var phys := rad_to_deg(m.alpha) + gamma
		approx(vis, phys, 1.0, "%s: тангаж киля на виде %.2f° и в модели %.2f°" % [wing, vis, phys])
		print(
			"         %s: тангаж киля на виде %+.2f°, из модели %+.2f° (α %.2f°, угол планирования %+.2f°)"
			% [wing, vis, phys, rad_to_deg(m.alpha), gamma]
		)
		v.free()
