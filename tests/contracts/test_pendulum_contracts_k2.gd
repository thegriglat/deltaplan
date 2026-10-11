extends TestCase
## Контрактный тест pendulum PD-К2 (docs/contracts/pendulum.md): configs/pendulum.json и блок
## pendulum во всех configs/wings/*.json. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"
const WINGS_DIR := "res://configs/wings"
const WING_KEYS := ["contract", "_doc", "sweep_deg", "root_chord_m", "tip_chord_m", "washout_deg",
		"keel_len_m", "crossbar_from_nose_m", "hang_from_nose_m", "bar_x_from_nose_m", "bar_z_m",
		"cg_x_from_nose_m", "cg_z_m", "inertia_kgm2", "dcm0", "cd_scale", "apparatus_defaults", "ref"]
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
	check(m != null and int(m.get_string(1)) == 3, "PD-К2 (v3) в заголовках")


func test_pendulum_config() -> void:
	var c := _read_json("res://configs/pendulum.json")
	check(not c.is_empty(), "configs/pendulum.json читается")
	check(c.get("contract") == "PD-К2 v3", "contract")
	var want := {
		"chain": {"links": 3, "strap_mass_kg": 1.0, "compliance_m_per_n": 4e-5, "substeps_per_s": 480, "substeps_min": 4},
		"arms": {"force_max_n": 300.0, "tau_s": 0.30, "ti_s": 0.0, "shift_y_max_m": 0.45,
				"shift_x_pull_m": 0.45, "shift_x_push_m": 0.30},
		"strips": {"count": 16, "cp_chord": 0.25, "aero_hz": 60.0},
		"yaw": {"cn_beta": 0.06, "fin_arm_m": 1.6, "fin_slope_per_rad": 2.0},
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
	check(is_equal_approx(float(c.get("pilot_cda_m2", 0.0)), 0.21), "pilot_cda_m2")
	check(c.get("apparent_roll") == true, "apparent_roll")
	check(is_equal_approx(float(c.get("billow_shift_deg", 1.0)), 0.0), "billow_shift_deg")
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
		check(b.get("contract") == "PD-К2 v3", "%s: contract" % id)
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
