extends TestCase
## Контракт TK-K1 (docs/contracts/trike-model.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 3


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
	"prop_blades", "prop_axis_height", "prop_tilt_deg", "prop_rpm", "prop_cw_from_behind", "prop_chord_max",
	"prop_chord_tip", "prop_hub_d", "engine_cyl_count", "engine_cyl_layout", "engine_cyl_d", "engine_gearbox",
	"engine_exhaust_d", "engine_exhaust_l", "muffler_d", "muffler_l", "rear_seat_rise", "tank_volume_l", "tank_l", "tank_w", "tank_h", "tube_keel_d", "tube_mast_d",
	"tube_strut_d", "tube_frame_d", "prop_rpm_idle", "prop_rpm_max", "prop_spin_period_s"
]
const SEAT_REAR_KEYS := [
	"seat_pan", "seat_pan_size", "backrest_base", "backrest_angle_deg", "backrest_size", "foot_l", "foot_r"
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
	check(int(p.get("version", 0)) == VERSION, "version = %d" % VERSION)
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


func test_trike_params_v2() -> void:
	var p := _load_params()
	if p.is_empty():
		check(false, "trike_params.json читается")
		return
	var dims: Dictionary = p.get("dims", {})
	var blades := int(dims.get("prop_blades", {}).get("value", 0))
	check(blades == 2 or blades == 3, "prop_blades ∈ {2, 3}: %d" % blades)
	check(float(dims.get("prop_chord_max", {}).get("value", 0.0)) >= float(dims.get("prop_chord_tip", {}).get("value", 1.0)), "хорда у законцовки ≤ наибольшей")
	check(float(dims.get("prop_chord_max", {}).get("value", 1.0)) < 0.25 * float(dims.get("prop_d", {}).get("value", 0.0)), "лопасть узкая: хорда < 0.25 диаметра")
	check(["inline", "boxer"].has(String(dims.get("engine_cyl_layout", {}).get("value", ""))), "engine_cyl_layout: inline | boxer")
	check(int(dims.get("engine_cyl_count", {}).get("value", 0)) >= 1, "engine_cyl_count >= 1")
	for k in ["tube_keel_d", "tube_mast_d", "tube_strut_d"]:
		check(absf(float(dims.get(k, {}).get("value", 0.0)) - 0.06) < 1e-6, "v3: dims.%s = 0.06 (решение Q1)" % k)
	for k in ["engine_exhaust_d", "engine_exhaust_l", "muffler_d", "muffler_l"]:
		var ev := float(dims.get(k, {}).get("value", 0.0))
		check(ev > 0.05 and ev < 1.0, "v3: dims.%s в пределах 5-100 см: %s" % [k, ev])
	for k in ["tube_keel_d", "tube_mast_d", "tube_strut_d", "tube_frame_d"]:
		var d := float(dims.get(k, {}).get("value", 0.0))
		check(d >= 0.02 and d <= 0.1, "dims.%s в разумных пределах (2-10 см): %s" % [k, d])
	var idle := float(dims.get("prop_rpm_idle", {}).get("value", 0.0))
	var rmax := float(dims.get("prop_rpm_max", {}).get("value", 0.0))
	check(idle > 0.0 and idle < rmax, "prop_rpm_idle < prop_rpm_max: %s < %s" % [idle, rmax])
	check(float(dims.get("prop_rpm", {}).get("value", 0.0)) <= rmax, "prop_rpm <= prop_rpm_max")
	check(absf(float(dims.get("prop_spin_period_s", {}).get("value", 0.0)) - 1.0) < 1e-6, "prop_spin_period_s = 1.0")
	var seat: Dictionary = p.get("seat", {})
	var rear: Dictionary = p.get("seat_rear", {})
	for k in SEAT_REAR_KEYS:
		check(rear.has(k), "seat_rear.%s" % k)
	if not (rear.has("foot_l") and rear.has("foot_r") and rear.has("seat_pan") and seat.has("seat_pan")):
		return
	var l: Array = rear.foot_l
	var r: Array = rear.foot_r
	check(absf(float(l[0]) + float(r[0])) <= 0.01, "seat_rear foot_l/_r симметричны по x")
	check(absf(float(l[1]) - float(r[1])) <= 0.01 and absf(float(l[2]) - float(r[2])) <= 0.01, "seat_rear foot_l/_r: y, z совпадают")
	var rise := float(dims.get("rear_seat_rise", {}).get("value", 0.0))
	check(rise > 0.0, "rear_seat_rise > 0")
	check(absf((float(rear.seat_pan[2]) - float(seat.seat_pan[2])) - rise) <= 0.01, "seat_rear.seat_pan.z − seat.seat_pan.z = rear_seat_rise")
	check(float(rear.seat_pan[1]) < float(seat.seat_pan[1]), "заднее сиденье позади переднего")
	var tank: Dictionary = p.get("tank", {})
	for k in ["center", "size", "filler"]:
		check(tank.has(k), "tank.%s" % k)
	if tank.has("size") and tank.has("center") and tank.has("filler"):
		var sz: Array = tank.size
		check(float(sz[2]) >= 0.6 * float(sz[0]), "бак: высота ≥ 0.6 ширины")
		var vol := float(sz[0]) * float(sz[1]) * float(sz[2]) * 1000.0
		var want := float(dims.get("tank_volume_l", {}).get("value", 0.0))
		check(want > 0.0 and absf(vol - want) <= 0.15 * want, "объём габарита бака %.1f л ≈ tank_volume_l %.1f ± 15 %%" % [vol, want])
		for i in 3:
			check(absf(float(tank.filler[i]) - float(tank.center[i])) <= float(sz[i]) * 0.5 + 0.01, "горловина в пределах габарита, ось %d" % i)
		check(float(tank.center[2]) + float(sz[2]) * 0.5 <= float(rear.seat_pan[2]) + 0.001, "бак под задней подушкой")
		# v3: бак над килем. Ось киля KZ = −2.12 (tools/blender/build_trike.py), верх киля = KZ + tube_keel_d/2.
		check(tank.has("keel_clear") and float(tank.get("keel_clear", 0.0)) >= 0.03, "v3: tank.keel_clear >= 0.03")
		var keel_top := -2.12 + float(dims.get("tube_keel_d", {}).get("value", 0.0)) * 0.5
		var bottom := float(tank.center[2]) - float(sz[2]) * 0.5
		check(absf(bottom - keel_top - float(tank.get("keel_clear", 0.0))) <= 0.002, "v3: низ бака = верх киля + keel_clear: %.4f" % (bottom - keel_top))
		check(float(rear.seat_pan[2]) - (float(tank.center[2]) + float(sz[2]) * 0.5) >= 0.02 - 1e-6, "v3: зазор бак-подушка >= 2 см")
		check(absf(float(tank.filler[2]) - (float(tank.center[2]) + float(sz[2]) * 0.5)) <= 0.01, "v3: горловина сверху бака")
