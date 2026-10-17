extends TestCase
## Контракт CLF-К3 (docs/contracts/cloud-field.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

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
	check(found.get("CLF-К3", 0) == VERSION, "CLF-К3 (v%d) в заголовках: %s" % [VERSION, found])


func test_air_thermals_fields() -> void:
	var scr: Script = load("res://scripts/atmosphere/air_model/air_thermals.gd")
	check(scr != null, "air_thermals.gd грузится")
	if scr == null:
		return
	var props := {}
	for p in scr.get_script_property_list():
		props[p.name] = p
	for name in ["c_top", "col_wstar", "phi"]:
		check(props.has(name) and props[name].type == TYPE_PACKED_FLOAT32_ARRAY, "AirThermals.%s — PackedFloat32Array" % name)
	var air := AirThermals.new()
	check(air.c_top.size() == 0 and air.col_wstar.size() == 0, "до build — пусто")
