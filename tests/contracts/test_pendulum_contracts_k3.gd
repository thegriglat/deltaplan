extends TestCase
## Контрактный тест PD-К3 v2 (docs/contracts/pendulum.md): ключи, диапазоны, хранение по крылу, порядок умолчаний.

const DOC := "res://docs/contracts/pendulum.md"
const SPEC := {
	"hang_shift_cm": [-4.0, 4.0, 0.5, 0.0],
	"hang_length_m": [1.0, 1.4, 0.05, 1.2],
	"sail_flex": [0.1, 1.0, 0.05, 0.2],
	"dihedral_eff_deg": [-2.0, 6.0, 0.5, 1.0],
}


func test_header() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(text.contains("## PD-К3. Настройки «Аппарат» (v2)"), "PD-К3 v2 заголовок")
	check(text.contains('{"id": "PD-К3", "version": 2}'), "PD-К3 v2 в frontmatter")


func test_keys_and_ranges() -> void:
	check(FlightSettings.APPARATUS_SPEC.size() == 4, "4 ключа")
	for k: String in SPEC:
		check(FlightSettings.APPARATUS_SPEC.has(k), "ключ " + k)
		var a: Array = FlightSettings.APPARATUS_SPEC[k]
		for i in 4:
			check(is_equal_approx(float(a[i]), float(SPEC[k][i])), "%s[%d]" % [k, i])
	var s := FlightSettings.defaults()
	check(s.apparatus.is_empty(), "по умолчанию пилот ничего не менял")
	var r := s.resolved_apparatus("sport")
	check(r.size() == 4, "resolved: 4 ключа")
	for k: String in SPEC:
		var def: float = r.get(k, NAN)
		if not FileAccess.file_exists("res://configs/pendulum.json"):
			check(is_equal_approx(def, SPEC[k][3]), "умолчание " + k)
		check(def >= SPEC[k][0] and def <= SPEC[k][1], "умолчание в диапазоне " + k)


func test_per_wing_storage_roundtrip() -> void:
	var s := FlightSettings.defaults()
	s.apparatus = {
		"sport": {"hang_shift_cm": 2.5, "hang_length_m": 1.3},
		"laminar": {"sail_flex": 0.55, "dihedral_eff_deg": 5.5},
	}
	var r := FlightSettings.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(r.apparatus == s.apparatus, "туда-обратно: только изменённое, по крылу")
	check(s.duplicate().apparatus == s.apparatus, "duplicate сохраняет")
	check(is_equal_approx(r.resolved_apparatus("sport").hang_shift_cm, 2.5), "sport: своё")
	check(
		is_equal_approx(r.resolved_apparatus("laminar").sail_flex, 0.55)
		and is_equal_approx(r.resolved_apparatus("laminar").dihedral_eff_deg, 5.5),
		"laminar: своё (V до +6)"
	)
	# смена крыла не затрагивает значения другого
	var def_sport := FlightSettings.apparatus_defaults("sport")
	check(
		is_equal_approx(r.resolved_apparatus("laminar").hang_length_m, FlightSettings.apparatus_defaults("laminar").hang_length_m),
		"laminar: пропуск — умолчание крыла"
	)
	check(is_equal_approx(r.resolved_apparatus("sport").sail_flex, def_sport.sail_flex), "sport: пропуск")
	# крыло без записей — умолчания
	check(r.resolved_apparatus("nonexistent_wing") == FlightSettings.apparatus_defaults(), "неизвестное крыло")


func test_defaults_order_and_clamp() -> void:
	# пропуски в записи — умолчания; зажим в диапазон
	var part := FlightSettings.from_dict({"apparatus": {"sport": {"sail_flex": 0.7}}})
	check(is_equal_approx(part.resolved_apparatus("sport").sail_flex, 0.7), "частичный блок: заданный")
	check(
		is_equal_approx(part.resolved_apparatus("sport").hang_length_m, FlightSettings.apparatus_defaults("sport").hang_length_m),
		"частичный блок: умолчание"
	)
	var c := FlightSettings.from_dict({"apparatus": {"sport": {"hang_shift_cm": 99, "sail_flex": -3, "dihedral_eff_deg": 99}}})
	check(is_equal_approx(c.resolved_apparatus("sport").hang_shift_cm, 4.0), "зажим сверху")
	check(is_equal_approx(c.resolved_apparatus("sport").sail_flex, 0.1), "зажим снизу")
	check(is_equal_approx(c.resolved_apparatus("sport").dihedral_eff_deg, 6.0), "V зажим +6")
	var nb := FlightSettings.from_dict({})
	check(nb.apparatus.is_empty(), "нет блока — пусто")
	# порядок: пилот → крыло (pendulum.apparatus_defaults) → configs/pendulum.json
	var wing_ad: Variant = Config.get_config("wings/sport").get("pendulum", {}).get("apparatus_defaults")
	if wing_ad is Dictionary:
		for k: String in wing_ad:
			check(is_equal_approx(FlightSettings.apparatus_defaults("sport")[k], float(wing_ad[k])), "умолчание крыла " + k)
	else:
		check(FlightSettings.apparatus_defaults("sport") == FlightSettings.apparatus_defaults(), "нет блока крыла — общие")
