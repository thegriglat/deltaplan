extends TestCase
## Контрактный тест PD-К5 (docs/contracts/pendulum.md): поза пилота в визуале и у чужих пилотов —
## GliderVisual.set_hang_pose, поля BotAgent.pilot_rel / pilot_rel_valid, поставщики данных
## (PD-К1: pilot_rel, pilot_basis, head_position). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/pendulum.md читается")
	var re := RegEx.create_from_string("(?m)^## PD-К5\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 2, "заголовок «## PD-К5. … (v2)»")


func _method(o: Object, name: String) -> Dictionary:
	for md: Dictionary in o.get_method_list():
		if md.name == name:
			return md
	return {}


func test_set_hang_pose_signature() -> void:
	var v := GliderVisual.new()
	var md := _method(v, "set_hang_pose")
	check(not md.is_empty(), "GliderVisual.set_hang_pose есть")
	if not md.is_empty():
		var args: Array = md.args
		check(args.size() == 3, "set_hang_pose: 3 параметра (%d)" % args.size())
		if args.size() == 3:
			check(int(args[0].type) == TYPE_VECTOR3, "pilot_rel: Vector3")
			check(int(args[1].type) == TYPE_BOOL, "on_ground: bool")
			check(int(args[2].type) == TYPE_FLOAT, "dt: float")
	check(not _method(v, "set_pose").is_empty(), "прежний set_pose на месте")
	check("hang_pose_active" in v, "признак позы от маятника (для камеры)")
	v.free()


func test_bot_agent_fields() -> void:
	var a := BotAgent.new()
	var types := {}
	for p: Dictionary in a.get_property_list():
		types[String(p.name)] = int(p.type)
	check(types.get("pilot_rel", -1) == TYPE_VECTOR3, "BotAgent.pilot_rel: Vector3")
	check(types.get("pilot_rel_valid", -1) == TYPE_BOOL, "BotAgent.pilot_rel_valid: bool")
	check(a.pilot_rel_valid == false, "pilot_rel_valid по умолчанию false")
	check(a.pilot_rel == Vector3.ZERO, "pilot_rel по умолчанию 0")


func test_model_supplies_pose_data() -> void:
	var m := PendulumModel.new()
	var types := {}
	for p: Dictionary in m.get_property_list():
		types[String(p.name)] = int(p.type)
	check(types.get("pilot_rel", -1) == TYPE_VECTOR3, "PendulumModel.pilot_rel: Vector3 (PD-К1)")
	check(types.get("pilot_basis", -1) == TYPE_BASIS, "PendulumModel.pilot_basis: Basis (PD-К1)")
	check(types.get("head_position", -1) == TYPE_VECTOR3, "PendulumModel.head_position: Vector3 (PD-К1)")


func test_glider_update_pilot_exists() -> void:
	var g := Glider.new()
	check(not _method(g, "_update_pilot").is_empty(), "Glider._update_pilot есть")
	g.free()
