extends Node
## Кулак краг на базовой штанге обхватывает трубу у всех крыльев (в том числе с изогнутой вперёд
## штангой, PV3): точка хвата кисти (HandL/HandR) лежит на оси трубы, а ось кулака (X кости кисти)
## идёт по касательной трубы в этой точке. Истинная ось — закон дуги из glider_params.json
## (тот же, что в tools/blender/aframe_geom.bow_at), маркеры BarGripL/R лежат на ней.

const PARAMS := "res://tools/blender/glider_params.json"
## Расстояние точки хвата кисти до оси трубы, м (кулак — 4 см, труба — 1,8 см в диаметре).
const MAX_AXIS_DIST_M := 0.01
## Угол между осью кулака и касательной трубы, °.
const MAX_AXIS_ANGLE_DEG := 6.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _bow_at(x: float, w: float, bow: float, straight_len: float) -> float:
	var half := w - maxf(straight_len, 0.45 * w)
	var flat := 0.2 * w
	var a := absf(x)
	if bow <= 0.0 or a >= half:
		return 0.0
	if a <= flat:
		return bow
	var k := (half - a) / (half - flat)
	return bow * (3.0 * k * k - 2.0 * k * k * k)


func test_fist_on_bar_axis_all_wings() -> void:
	var params: Dictionary = JSON.parse_string(
		FileAccess.open(PARAMS, FileAccess.READ).get_as_text()
	)
	var cf: Dictionary = params.control_frame
	var worst_d := 0.0
	var worst_a := 0.0
	var worst_straight_a := 0.0
	var n_curved := 0
	for wid: String in params.wings:
		var bb: Dictionary = params.wings[wid].get("basebar", cf.basebar_default)
		var bow := float(bb.get("bow_m", 0.0)) if bb.shape == "curved" else 0.0
		var sl := float(bb.get("straight_len_m", 0.0)) if bb.shape == "curved" else 0.0
		if bow > 0.0:
			n_curved += 1
		var v := GliderVisual.new()
		add_child(v)
		v.build(
			Config.get_config("wings/" + wid),
			Config.get_config("pilot"),
			Config.get_config("flight").visual
		)
		var ap := v.find_children("*", "AnimationPlayer", true, false)
		if v.arm_ik == null or ap.is_empty():
			check(false, "%s: у пилота есть IK рук" % wid)
			v.free()
			continue
		(ap[0] as AnimationPlayer).play("prone", 0.0)
		(ap[0] as AnimationPlayer).advance(0.5)
		v.set_pose(0.0, 0.0, true, 1.0e6)
		for i in 4:
			await get_tree().process_frame
		v.set_pose(0.0, 0.0, true, 1.0e6)
		for i in 4:
			await get_tree().process_frame
		var l := v.to_local(v.get_marker("UprightBottomL").global_position)
		var r := v.to_local(v.get_marker("UprightBottomR").global_position)
		var w := (r.x - l.x) * 0.5
		for side in [-1, 1]:
			var g := v.bar_grip(side)
			var x := g.x - (l.x + r.x) * 0.5
			var eps := 1e-3
			var dz := -(_bow_at(x + eps, w, bow, sl) - _bow_at(x - eps, w, bow, sl)) / (2.0 * eps)
			var tan := Vector3(1.0, 0.0, dz).normalized()
			var hand := v.find_child("HandL" if side < 0 else "HandR", true, false) as Node3D
			var hp := v.to_local(hand.global_position)
			# ось кулака — X кости кисти: пустышка хвата — ребёнок BoneAttachment3D этой кости
			var bone_basis := hand.global_transform.basis * hand.transform.basis.inverse()
			var hx := (v.global_transform.basis.inverse() * bone_basis.x).normalized()
			var rel := hp - g
			var dist := (rel - tan * rel.dot(tan)).length()
			var ang := rad_to_deg(acos(clampf(absf(hx.dot(tan)), 0.0, 1.0)))
			worst_d = maxf(worst_d, dist)
			worst_a = maxf(worst_a, ang)
			if bow <= 0.0:
				worst_straight_a = maxf(worst_straight_a, ang)
			check(
				dist < MAX_AXIS_DIST_M,
				"%s (изгиб %.2f) рука %d: кисть↔ось трубы %.4f м" % [wid, bow, side, dist]
			)
			check(
				ang < MAX_AXIS_ANGLE_DEG,
				"%s (изгиб %.2f) рука %d: ось кулака↔касательная %.1f°" % [wid, bow, side, ang]
			)
		v.free()
	check(n_curved > 0, "есть крылья с изогнутой штангой")
	print(
		"         худшее: кисть↔ось %.4f м, угол %.1f° (прямые штанги — %.1f°)"
		% [worst_d, worst_a, worst_straight_a]
	)
