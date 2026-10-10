extends TestCase
## Контрактный тест PD-К2 v3 (docs/contracts/pendulum.md), часть земли и посадки: configs/pendulum.json
## → contract «PD-К2 v3», блок ground.* (PD-3) и ключи PD-14 (экранный эффект, динамический срыв,
## C_L max полос по поляре). У каждого ключа — <ключ>_doc. Блок pendulum крыльев и прочие ключи —
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
const DYNAMIC_STALL := {"enabled": "bool", "t_sep_c_per_v": "pos", "t_alpha_c_per_v": "pos"}


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
	check(m != null and int(m.get_string(1)) == 3, "заголовок «## PD-К2. … (v3)»")


func test_contract_v3() -> void:
	var c := _cfg()
	check(c.get("contract") == "PD-К2 v3", "configs/pendulum.json → contract = PD-К2 v3 (%s)" % c.get("contract"))


func test_ground_keys() -> void:
	var c := _cfg()
	check(c.has("ground") and c.ground is Dictionary, "ground есть")
	if c.has("ground"):
		_check_block(c.ground, GROUND, "ground")


func test_pd14_keys() -> void:
	var c := _cfg()
	for k in ["ground_effect", "dynamic_stall"]:
		check(c.has(k) and c[k] is Dictionary, "%s есть" % k)
	if c.has("ground_effect"):
		_check_block(c.ground_effect, GROUND_EFFECT, "ground_effect")
		var e := float(c.ground_effect.get("span_efficiency", 0.0))
		check(e > 0.5 and e <= 1.0, "ground_effect.span_efficiency в (0,5; 1]")
	if c.has("dynamic_stall"):
		_check_block(c.dynamic_stall, DYNAMIC_STALL, "dynamic_stall")
	for k in ["strip_cl_max_match_polar", "stall_cp_shift"]:
		check(c.get(k) is bool, "%s — bool" % k)
		check(c.has(k + "_doc"), "%s_doc есть" % k)
