extends Node
## PH-К6: GliderVisual.feet_positions() у пилота со скелетом (Node — нужен узел в дереве).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## У пилота со скелетом — две точки подошв, ниже таза и близко к земле стоя.
func test_feet_positions_with_skeleton() -> void:
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/training"),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var f := v.feet_positions()
	check(f.size() == 2, "две подошвы (%d)" % f.size())
	if f.size() == 2:
		var hips := v.global_transform * v._hips_local_world()
		check(f[0].y < hips.y and f[1].y < hips.y, "подошвы ниже таза")
		check(f[0].distance_to(f[1]) < 1.0, "ноги рядом")
	v.free()
