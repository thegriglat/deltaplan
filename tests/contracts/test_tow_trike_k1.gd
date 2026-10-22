extends TestCase
## Контракт TT-К1 v1 (docs/contracts/tow-trike.md): configs/tow_tug.json - параметры буксировщика-дельталёта.

const KEYS := {
	"cart": ["empty_mass_kg", "pilot_mass_kg", "fuel_kg", "mass_kg", "cg_below_hang_m", "cda_m2", "arms_force_max_n", "tow_hook", "tow_hook_on"],
	"engine": ["name", "gear_ratio", "power_max_kw", "prop_d_m", "prop_blades", "prop_rpm_idle", "prop_rpm_max", "thrust_tilt_deg"],
	"ground": ["keel_angle_deg", "rotate_deg", "rolling_crr", "wheel_base_agl_m"],
	"tow": ["tow_speed_kmh", "slack_speed_ms", "glider_hold_agl_m", "rotate_speed_kmh", "power_reduce_agl_m", "climb_limit_ms", "circuit_start_agl_m", "circuit_bank_deg"],
	"away": ["throttle", "turn_deg", "turn_s", "away_s"],
}


func _cfg() -> Dictionary:
	return Config.get_config("tow_tug")


func _num_keys_have_doc(block: Dictionary, name: String) -> void:
	for k in block:
		var k_s := String(k)
		if k_s.ends_with("_doc") or k_s.begins_with("_"):
			continue
		var v: Variant = block[k]
		if v is float or v is int or v is Array:
			check(block.has(k_s + "_doc") or block.has(k_s.rsplit("_", true, 1)[0] + "_doc") or block.has("_doc"), "%s.%s: есть _doc" % [name, k_s])


func test_keys_and_docs() -> void:
	var c := _cfg()
	check(String(c.get("contract", "")) == "TT-К1 v1", "contract")
	check(c.has("_doc"), "_doc верхнего уровня")
	check(c.has("wing") and c.has("wing_doc"), "wing + wing_doc")
	for blk in KEYS:
		check(c.has(blk) and c[blk] is Dictionary, "блок %s" % blk)
		for k in KEYS[blk]:
			check((c[blk] as Dictionary).has(k), "%s.%s есть" % [blk, k])
		for k in KEYS[blk]:
			var v: Variant = c[blk][k]
			if k != "name" and k != "tow_hook_on" and k != "tow_hook":
				check(v is float or v is int, "%s.%s числовой" % [blk, k])
		_num_keys_have_doc(c[blk], blk)
	check(c.has("thrust") and c.thrust.has("_doc"), "thrust._doc")
	check(String(c.cart.tow_hook_on) in ["pilot", "hang"], "tow_hook_on")
	check((c.cart.tow_hook as Array).size() == 3, "tow_hook - 3 числа")
	# старые ключи TW-К9 верхнего уровня убраны
	for k in ["roll_accel_ms2", "climb_rate_ms", "circuit_radius_m", "tail_height_m", "away_descent_ms", "tow_speed_kmh"]:
		check(not c.has(k), "старый ключ TW-К9 %s удалён" % k)


func test_thrust_table() -> void:
	var th: Dictionary = _cfg().thrust
	var n := (th.v_ms as Array).size()
	check((th.full_n as Array).size() == n and (th.idle_n as Array).size() == n and (th.rpm_full as Array).size() == n, "таблицы одной длины")
	check(float(th.v_ms[0]) == 0.0 and float(th.v_ms[n - 1]) >= 30.0, "v_ms от 0 до ≥ 30")
	for i in n:
		if i > 0:
			check(float(th.v_ms[i]) > float(th.v_ms[i - 1]), "v_ms возрастает [%d]" % i)
		check(float(th.full_n[i]) >= float(th.idle_n[i]) and float(th.idle_n[i]) >= 0.0, "full ≥ idle ≥ 0 [%d]" % i)


func test_masses_rpm_wing_speed() -> void:
	var c := _cfg()
	var cart: Dictionary = c.cart
	var sum := float(cart.empty_mass_kg) + float(cart.pilot_mass_kg) + float(cart.fuel_kg)
	check(absf(float(cart.mass_kg) - sum) <= 0.5, "mass_kg = сумма ± 0,5: %.1f против %.1f" % [float(cart.mass_kg), sum])
	var tp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
	var dims: Dictionary = tp.dims
	for k in ["prop_rpm_idle", "prop_rpm_max"]:
		var want := float(dims[k].value)
		check(absf(float(c.engine[k]) - want) <= 0.01 * want, "%s = trike_params ± 1 %%: %s против %s" % [k, c.engine[k], want])
	check(ResourceLoader.exists("res://configs/wings/%s.json" % String(c.wing)) or FileAccess.file_exists("res://configs/wings/%s.json" % String(c.wing)), "крыло %s есть в configs/wings" % c.wing)
	var v := float(c.tow.tow_speed_kmh)
	check(v >= 55.0 and v <= 65.0, "tow_speed_kmh ∈ [55; 65]: %.1f" % v)


func test_autopilot_block() -> void:
	var ap: Dictionary = _cfg().get("autopilot", {})
	check(not ap.is_empty() and ap.has("_doc"), "блок autopilot с _doc")
	for k in ap:
		var k_s := String(k)
		if k_s.begins_with("_") or k_s.ends_with("_doc"):
			continue
		check(ap[k] is float or ap[k] is int, "autopilot.%s числовой" % k_s)
		check(ap.has(k_s + "_doc"), "autopilot.%s: есть _doc" % k_s)
	for k in ["bar_kp", "bar_ki", "bar_kd", "roll_kp", "roll_kd", "slack_kp", "slack_ki", "throttle_rate_per_s", "climb_throttle_ki"]:
		check(ap.has(k), "autopilot.%s есть" % k)
