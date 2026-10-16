extends TestCase
## Контракт CLF-К1 (docs/contracts/cloud-field.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/cloud-field.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (CLF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("CLF-К1", 0) == VERSION, "CLF-К1 (v%d) в заголовках: %s" % [VERSION, found])


func test_cloud_field_interface() -> void:
	var scr: Script = load("res://scripts/atmosphere/cloud_field.gd")
	check(scr != null, "cloud_field.gd грузится")
	if scr == null:
		return
	check(int(scr.get_script_constant_map().get("FORMAT_VERSION", -1)) == 1, "FORMAT_VERSION = 1")
	var props := {}
	for p in scr.get_script_property_list():
		props[p.name] = p
	for name in ["nx", "ny", "dx", "x0", "y0", "base_msl", "cover", "depth", "stage", "activity", "bg_cover", "bg_depth"]:
		check(props.has(name), "CloudField.%s" % name)
	for name in ["cover", "depth", "stage", "activity"]:
		if props.has(name):
			check(props[name].type == TYPE_PACKED_FLOAT32_ARRAY, "%s — PackedFloat32Array" % name)
	var methods := {}
	for m in scr.get_script_method_list():
		methods[m.name] = m
	var want := {
		"setup_grid": 5, "set_inputs": 1, "reset": 1, "step_to": 1, "sample": 1, "density_at": 1,
		"shade_at": 2, "to_image": 0, "snapshot": 0, "apply_snapshot": 2, "signature": 0,
	}
	for name in want:
		check(methods.has(name), "CloudField.%s" % name)
		if methods.has(name):
			check(methods[name].args.size() == int(want[name]), "%s: %d аргументов" % [name, want[name]])
	var cf := CloudField.new({})
	cf.setup_grid(8, 6, 400.0, -1600.0, -1200.0)
	check(cf.signature() == "400.000,-1600.000,-1200.000,8,6", "signature как AirThermals.grid_sig: %s" % cf.signature())
	cf.step_to(100.0)
	check(cf.cover.size() == 48 and cf.cover.count(0.0) == 48, "без входов — пустое поле")
	var s := cf.sample(Vector3(0, 0, 0))
	check(s is Vector4 and s.x == 0.0, "sample → Vector4")
