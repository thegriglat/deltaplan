extends TestCase
## Контрактный тест pendulum PD-К2 (docs/contracts/pendulum.md): configs/pendulum.json и блок
## pendulum во всех configs/wings/*.json. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"
const WINGS_DIR := "res://configs/wings"
const WING_KEYS := ["contract", "_doc", "sweep_deg", "root_chord_m", "tip_chord_m", "washout_deg",
		"keel_len_m", "crossbar_from_nose_m", "hang_from_nose_m", "bar_x_from_nose_m", "bar_z_m",
		"cg_x_from_nose_m", "cg_z_m", "inertia_kgm2", "dcm0", "cd_scale", "apparatus_defaults", "ref",
		"cl_alpha_per_rad", "alpha_zero_lift_deg"]
const REF_KEYS := ["trim_kmh", "sink_ms", "alpha_trim_deg", "neutral_point_from_nose_m",
		"static_margin", "kmh_per_cm_hang"]


func _read_json(path: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


func _wing_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(WINGS_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out


func _finite(v: Variant) -> bool:
	if v is float:
		return is_finite(v)
	if v is Dictionary:
		for k: Variant in v:
			if not _finite(v[k]):
				return false
	return true


## Снижение по поляре игры (м/с) на скорости v (м/с) при эталонной массе: как FlightModel.steady_glide.
func _polar_sink(w: Dictionary, v: float) -> float:
	var m: float = float(w["pilot_mass_ref_kg"]) + float(w["wing_mass_kg"])
	var area := float(w["area_m2"])
	var pol := WingPolar.new(w["polar"]["points_kmh_ms"], m, 1.225, area)
	var cos_g := 1.0
	var ld := 1.0
	for i in 4:
		var cl := 2.0 * m * Units.G * cos_g / (1.225 * area * v * v)
		ld = cl / pol.cd_at(cl)
		cos_g = cos(atan(1.0 / ld))
	return v * sin(atan(1.0 / ld))


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/pendulum.md читается")
	var re := RegEx.create_from_string("(?m)^## PD-К2\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 9, "PD-К2 (v9) в заголовках")


func test_pendulum_config() -> void:
	var c := _read_json("res://configs/pendulum.json")
	check(not c.is_empty(), "configs/pendulum.json читается")
	check(c.get("contract") == "PD-К2 v9", "contract")
	var want := {
		"chain": {"links": 3, "strap_mass_kg": 1.0, "compliance_m_per_n": 4e-5, "substeps_per_s": 480, "substeps_min": 4},
		"arms": {"force_max_n": 300.0, "tau_s": 0.30, "ti_s": 0.0, "shift_y_max_m": 0.45,
				"shift_x_pull_m": 0.45, "shift_x_push_m": 0.30, "shift_x_pull_full_m": 0.7, "pull_full_release_m_s": 0.5,
				"release_event": true, "release_pull": 0.25, "release_settle_m": 0.05, "release_settle_periods": 1.0},
		"pitch_nl": {"enabled": 1.0, "sigma": 0.5, "width_deg": 1.0, "luff_cm_per_deg": 0.02, "luff_on_deg": 0.0},
		"strips": {"count": 16, "cp_chord": 0.25, "aero_hz": 60.0},
		"yaw": {"cn_beta": 0.05, "fin_arm_m": 1.6, "fin_slope_per_rad": 2.0, "cn_p_add": 0.15, "cn_r_add": -0.03},
		"head": {"forward_m": 0.75, "up_m": 0.15},
		"apparatus_defaults": {"hang_shift_cm": 0.0, "hang_length_m": 1.2, "sail_flex": 0.2, "dihedral_eff_deg": 1.0},
	}
	for sec: String in want:
		var d: Dictionary = c.get(sec, {})
		for k: String in want[sec]:
			check(d.has(k), "%s.%s есть" % [sec, k])
			check(d.has(k + "_doc"), "%s.%s_doc есть" % [sec, k])
			if d.has(k):
				check(is_equal_approx(float(d[k]), float(want[sec][k])), "%s.%s = %s (%s)" % [sec, k, want[sec][k], d[k]])
	check(int(c["strips"]["count"]) % 2 == 0, "strips.count чётное")
	# v6 (PD-22): срыв полос
	var st: Dictionary = c["strips"]
	check(st.get("stall_model") in ["viterna", "plate"], "strips.stall_model — viterna | plate")
	check(st.get("stall_criterion") in ["streamwise", "normal"], "strips.stall_criterion — streamwise | normal")
	check(is_equal_approx(float(st.get("stall_cd90_base", 0.0)), 1.11), "strips.stall_cd90_base = 1,11")
	check(is_equal_approx(float(st.get("stall_cd90_per_ar", 0.0)), 0.018), "strips.stall_cd90_per_ar = 0,018")
	check(is_equal_approx(float(st.get("stall_cp_blend_deg", 0.0)), 20.0), "strips.stall_cp_blend_deg = 20")
	for k in ["stall_model", "stall_cd90_base", "stall_cd90_per_ar", "stall_criterion", "stall_cp_blend_deg"]:
		check(st.has(k + "_doc"), "strips.%s_doc есть" % k)
	check(is_equal_approx(float(c.get("pilot_cda_m2", 0.0)), 0.21), "pilot_cda_m2")
	check(c.get("apparent_roll") == true, "apparent_roll")
	check(is_equal_approx(float(c.get("billow_shift_deg", 0.0)), 40.0), "billow_shift_deg (PD-24: перекос пузыря)")
	for k in ["pilot_cda_m2", "apparent_roll", "billow_shift_deg", "contract"]:
		check(c.has(k + "_doc"), "%s_doc есть" % k)


func test_wings_pendulum_block() -> void:
	var ids := _wing_ids()
	check(ids.size() >= 48, "крыльев ≥ 48: %d" % ids.size())
	for id in ids:
		var w := _read_json("%s/%s.json" % [WINGS_DIR, id])
		var b: Dictionary = w.get("pendulum", {})
		check(not b.is_empty(), "%s: блок pendulum" % id)
		if b.is_empty():
			continue
		check(b.get("contract") == "PD-К2 v8", "%s: contract" % id)
		for k in WING_KEYS:
			check(b.has(k), "%s: pendulum.%s" % [id, k])
		check(_finite(b), "%s: числа конечны" % id)
		for k in ["ixx", "iyy", "izz", "ixz"]:
			check(b.get("inertia_kgm2", {}).has(k), "%s: inertia_kgm2.%s" % [id, k])
		var r: Dictionary = b.get("ref", {})
		for k in REF_KEYS:
			check(r.has(k), "%s: ref.%s" % [id, k])
		if not (r.has("trim_kmh") and b.has("inertia_kgm2") and b.has("root_chord_m")):
			continue
		check(float(b["root_chord_m"]) > float(b["tip_chord_m"]) and float(b["tip_chord_m"]) > 0.0, "%s: хорды" % id)
		var kn := float(r["static_margin"])
		check(kn > 0.0 and kn < 0.4, "%s: static_margin %.3f в (0; 0,4)" % [id, kn])
		check(absf(float(r["trim_kmh"]) - float(w["trim_speed_kmh"])) <= 0.3,
				"%s: трим %.2f vs %.2f" % [id, float(r["trim_kmh"]), float(w["trim_speed_kmh"])])
		var ps := _polar_sink(w, float(r["trim_kmh"]) / 3.6)
		check(absf(float(r["sink_ms"]) - ps) <= 0.02, "%s: снижение %.3f vs поляра %.3f" % [id, float(r["sink_ms"]), ps])
		var ad: Dictionary = b.get("apparatus_defaults", {})
		check(ad.has("dihedral_eff_deg") and ad.has("sail_flex"), "%s: apparatus_defaults.{dihedral_eff_deg, sail_flex}" % id)
		if ad.has("dihedral_eff_deg") and ad.has("sail_flex"):
			check(float(ad["dihedral_eff_deg"]) >= -2.0 and float(ad["dihedral_eff_deg"]) <= 6.0, "%s: V в −2…+6 (PD-К3)" % id)
			check(float(ad["sail_flex"]) >= 0.1 and float(ad["sail_flex"]) <= 1.0, "%s: гибкость в 0,1…1 (PD-К3)" % id)
		var I: Dictionary = b["inertia_kgm2"]
		check(float(I["ixx"]) > 0.0 and float(I["iyy"]) > 0.0 and float(I["izz"]) > 0.0, "%s: инерция > 0" % id)
		check(float(b["cd_scale"]) > 0.0, "%s: cd_scale > 0" % id)
		check(float(b["cl_alpha_per_rad"]) > 3.0 and float(b["cl_alpha_per_rad"]) < 6.0, "%s: cl_alpha_per_rad" % id)
		check(float(b["alpha_zero_lift_deg"]) < 0.0 and float(b["alpha_zero_lift_deg"]) > -15.0, "%s: alpha_zero_lift_deg" % id)


## Нелинейная Cm(α) (v8): ΔCm полос игры (PendulumWingStrips.pitch_nl_dcm, без dcm0, σ 0,5) против эталона
## прототипа — docs/research/pendulum/pitch-nonlinear.md «Порт в игру», допуск ±0,002.
## Столбцы: α_t, α_zl (°) и ΔCm при α_t, α_t − 5°, 0°, α_zl, α_zl − 5°.
const NL_REF := {
	"training": [10.43, -6.08, -0.0041, -0.0435, -0.0902, -0.1338, -0.0863],
	"atlas": [9.47, -6.06, -0.0031, -0.0338, -0.0637, -0.0957, -0.0386],
	"laminar": [10.61, -6.00, -0.0020, -0.0229, -0.0483, -0.0667, 0.0012],
	"sport": [11.74, -6.01, -0.0018, -0.0201, -0.0470, -0.0622, 0.0084],
	"ww_t2c": [12.58, -6.01, -0.0018, -0.0208, -0.0520, -0.0679, 0.0021],
}


func test_pitch_nl_reference() -> void:
	for id: String in NL_REF:
		var m := PendulumModel.new()
		m.setup(Config.get_config("wings/" + id), Config.get_config("pilot"))
		var st: PendulumWingStrips = m.strips
		check(st.nl_on, "%s: pitch_nl включена" % id)
		var e: Array = NL_REF[id]
		var b: Dictionary = Config.get_config("wings/" + id).pendulum
		var at := float(b.ref.alpha_trim_deg)
		var azl := float(b.alpha_zero_lift_deg)
		check(absf(at - float(e[0])) <= 0.02 and absf(azl - float(e[1])) <= 0.05,
				"%s: α_t %.2f (%.2f), α_zl %.2f (%.2f)" % [id, at, e[0], azl, e[1]])
		var angles := [at, at - 5.0, 0.0, azl, azl - 5.0]
		for i in angles.size():
			var got := st.pitch_nl_dcm(deg_to_rad(float(angles[i])))
			check(absf(got - float(e[i + 2])) <= 0.002,
					"%s: ΔCm(%.2f°) = %.4f, эталон %.4f" % [id, angles[i], got, e[i + 2]])
	# выключено — прежняя модель
	var pend: Dictionary = Config.get_config("pendulum").duplicate(true)
	pend.pitch_nl.enabled = false
	var w: Dictionary = Config.get_config("wings/laminar")
	var s2 := PendulumWingStrips.new()
	var flex := float(w.pendulum.apparatus_defaults.sail_flex)
	s2.setup(w, w.pendulum, pend, WingPolar.new(w.polar.points_kmh_ms, 100.0, 1.225, float(w.area_m2)), 0.0, flex, Vector3(2.0, 0.0, 0.3))
	check(not s2.nl_on and s2.pitch_nl_dcm(0.0) == 0.0, "pitch_nl.enabled = false — ΔCm = 0")
