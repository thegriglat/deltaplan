extends TestCase
## Контрактный тест PD-К2 v4 (docs/contracts/pendulum.md), часть земли и посадки: configs/pendulum.json
## → contract «PD-К2 v4», блок ground.* (PD-3), ключи PD-14 (экранный эффект, C_L max полос по
## поляре) и добавки рыскания v4 (yaw.cn_p_add, yaw.cn_r_add). У каждого ключа — <ключ>_doc. Блок pendulum крыльев и прочие ключи —
## tests/contracts/test_pendulum_contracts_k2.gd.

const DOC := "res://docs/contracts/pendulum.md"
const CFG := "res://configs/pendulum.json"
## Ключ → ожидаемый тип: "pos" — число > 0, "num" — число, "bool".
const GROUND := {
	"leg_length_m": "pos", "leg_stiffness_n_per_m": "pos", "foot_friction": "pos",
	"side_damping_n_s_per_m": "pos", "stand_stiffness_n_per_m": "pos", "shoulder_forward_m": "num",
	"shoulder_up_m": "num", "grip_along_upright_m": "pos", "grip_stiffness_n_per_m": "pos",
	"grip_force_max_n": "pos", "grip_down_max_n": "pos", "pitch_hold_nm_per_deg": "pos",
	"pitch_moment_max_nm": "pos", "liftoff_feet_clear_m": "pos", "liftoff_strap_fraction": "pos",
	"bar_after_liftoff_s": "pos", "fell_cm_height_m": "pos",
}
const GROUND_EFFECT := {"enabled": "bool", "span_efficiency": "pos"}


func _cfg() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(CFG))
	return v if v is Dictionary else {}


func _check_block(blk: Dictionary, keys: Dictionary, name: String) -> void:
	check(blk.has("_doc"), "%s: _doc" % name)
	for k: String in keys:
		check(blk.has(k), "%s.%s есть" % [name, k])
		check(blk.has(k + "_doc"), "%s.%s_doc есть" % [name, k])
		if not blk.has(k):
			continue
		var v: Variant = blk[k]
		match keys[k]:
			"bool":
				check(v is bool, "%s.%s — bool" % [name, k])
			"pos":
				check((v is float or v is int) and is_finite(float(v)) and float(v) > 0.0, "%s.%s > 0" % [name, k])
			_:
				check((v is float or v is int) and is_finite(float(v)), "%s.%s — число" % [name, k])


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	var re := RegEx.create_from_string("(?m)^## PD-К2\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 5, "заголовок «## PD-К2. … (v5)»")


func test_contract_v4() -> void:
	var c := _cfg()
	check(c.get("contract") == "PD-К2 v5", "configs/pendulum.json → contract = PD-К2 v5 (%s)" % c.get("contract"))


func test_yaw_add_keys_v4() -> void:
	var c := _cfg()
	var yaw: Dictionary = c.get("yaw", {})
	for k in ["cn_p_add", "cn_r_add"]:
		check(yaw.has(k), "yaw.%s есть" % k)
		check(yaw.has(k + "_doc"), "yaw.%s_doc есть" % k)
		var v: Variant = yaw.get(k)
		check(v is float or v is int, "yaw.%s — число" % k)
		if v is float or v is int:
			check(absf(float(v)) < 1.0, "yaw.%s в (−1; 1): %s" % [k, v])


func test_ground_keys() -> void:
	var c := _cfg()
	check(c.has("ground") and c.ground is Dictionary, "ground есть")
	if c.has("ground"):
		_check_block(c.ground, GROUND, "ground")


func test_pd14_keys() -> void:
	var c := _cfg()
	check(c.has("ground_effect") and c.ground_effect is Dictionary, "ground_effect есть")
	if c.has("ground_effect"):
		_check_block(c.ground_effect, GROUND_EFFECT, "ground_effect")
		var e := float(c.ground_effect.get("span_efficiency", 0.0))
		check(e > 0.5 and e <= 1.0, "ground_effect.span_efficiency в (0,5; 1]")
	check(c.get("strip_cl_max_match_polar") is bool, "strip_cl_max_match_polar — bool")
	check(c.has("strip_cl_max_match_polar_doc"), "strip_cl_max_match_polar_doc есть")
	check(c.get("stall_cp_shift") is bool, "stall_cp_shift — bool")
	check(c.has("stall_cp_shift_doc"), "stall_cp_shift_doc есть")
