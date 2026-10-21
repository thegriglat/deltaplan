extends TestCase
## Контракт TK-K1 (docs/contracts/trike-model.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TK-K\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TK-K1", 0) == VERSION, "TK-K1 (v%d) в заголовках: %s" % [VERSION, found])


const PARAMS := "res://tools/blender/trike_params.json"
const DIM_KEYS := [
	"length", "width", "hang_height", "wheelbase", "track", "wheel_front_d", "wheel_rear_d", "tire_front_w",
	"tire_rear_w", "mast_tilt_deg", "seat_height", "engine", "engine_l", "engine_w", "engine_h", "prop_d",
	"prop_blades", "prop_axis_height", "prop_tilt_deg", "prop_rpm", "prop_cw_from_behind"
]
const SEAT_KEYS := [
	"eye", "hip", "seat_pan", "seat_pan_size", "backrest_base", "backrest_angle_deg", "backrest_size", "foot_l",
	"foot_r", "throttle_pedal", "hand_l", "hand_r"
]


func _load_params() -> Dictionary:
	var text := FileAccess.get_file_as_string(PARAMS)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(PARAMS))
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}


func test_trike_params_interface() -> void:
	var p := _load_params()
	check(not p.is_empty(), "trike_params.json читается")
	if p.is_empty():
		return
	check(int(p.get("version", 0)) == VERSION, "version = 1")
	check(p.get("prototype") is Dictionary and p.prototype.has("name") and p.prototype.has("sources"), "prototype")
	var dims: Dictionary = p.get("dims", {})
	for k in DIM_KEYS:
		check(dims.has(k), "dims.%s" % k)
	for k in dims:
		var e: Variant = dims[k]
		check(e is Dictionary and e.has("value") and not String(e.get("src", "")).strip_edges().is_empty(), "dims.%s: value и непустой src" % k)
	check(absf(float(p.get("ground_z", 0.0)) + float(dims.hang_height.value)) < 1e-6, "ground_z = −hang_height")
	var em: Dictionary = p.get("eye_measured", {})
	for k in ["training", "apogee", "how"]:
		check(em.has(k), "eye_measured.%s" % k)
	var seat: Dictionary = p.get("seat", {})
	for k in SEAT_KEYS:
		check(seat.has(k), "seat.%s" % k)
	if seat.has("eye") and em.has("training"):
		for i in 3:
			check(absf(float(seat.eye[i]) - float(em.training[i])) <= 0.01, "seat.eye = eye_measured.training, ось %d" % i)
	for base in ["foot", "hand"]:
		var l: Array = seat.get(base + "_l", [0, 0, 0])
		var r: Array = seat.get(base + "_r", [0, 0, 0])
		check(absf(float(l[0]) + float(r[0])) <= 0.01, "%s_l/_r симметричны по x" % base)
		check(absf(float(l[1]) - float(r[1])) <= 0.01 and absf(float(l[2]) - float(r[2])) <= 0.01, "%s_l/_r: y, z совпадают" % base)
