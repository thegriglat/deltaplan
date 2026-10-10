extends TestCase
## Контрактный тест PD-К3 (docs/contracts/pendulum.md): ключи, диапазоны, умолчания, сохранение «Аппарат».

const DOC := "res://docs/contracts/pendulum.md"
const SPEC := {
	"hang_shift_cm": [-4.0, 4.0, 0.5, 0.0],
	"hang_length_m": [1.0, 1.4, 0.05, 1.2],
	"sail_flex": [0.1, 1.0, 0.05, 0.2],
	"dihedral_eff_deg": [-2.0, 5.0, 0.5, 1.0],
}


func test_header() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(text.contains("## PD-К3. Настройки «Аппарат» (v1)"), "PD-К3 v1 заголовок")
	check(text.contains('{"id": "PD-К3", "version": 1}'), "PD-К3 v1 в frontmatter")


func test_keys_and_ranges() -> void:
	check(FlightSettings.APPARATUS_SPEC.size() == 4, "4 ключа")
	for k: String in SPEC:
		check(FlightSettings.APPARATUS_SPEC.has(k), "ключ " + k)
		var a: Array = FlightSettings.APPARATUS_SPEC[k]
		for i in 4:
			check(is_equal_approx(float(a[i]), float(SPEC[k][i])), "%s[%d]" % [k, i])
	var s := FlightSettings.defaults()
	check(s.apparatus.size() == 4, "в настройках 4 ключа")
	for k: String in SPEC:
		var def: float = s.apparatus.get(k, NAN)
		if not FileAccess.file_exists("res://configs/pendulum.json"):
			check(is_equal_approx(def, SPEC[k][3]), "умолчание " + k)
		check(def >= SPEC[k][0] and def <= SPEC[k][1], "умолчание в диапазоне " + k)


func test_roundtrip_and_clamp() -> void:
	var s := FlightSettings.defaults()
	s.apparatus = {
		"hang_shift_cm": 2.5, "hang_length_m": 1.3, "sail_flex": 0.55, "dihedral_eff_deg": -1.5
	}
	var r := FlightSettings.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	for k: String in SPEC:
		check(is_equal_approx(r.apparatus[k], s.apparatus[k]), "туда-обратно " + k)
	# пропуски — умолчания
	var d := s.to_dict()
	d.erase("apparatus")
	var base := FlightSettings.defaults()
	var m := FlightSettings.from_dict(d, base)
	check(m.apparatus.size() == 4, "нет блока — 4 ключа")
	var part := FlightSettings.from_dict({"apparatus": {"sail_flex": 0.7}})
	check(is_equal_approx(part.apparatus.sail_flex, 0.7), "частичный блок: заданный")
	check(
		is_equal_approx(part.apparatus.hang_length_m, FlightSettings.apparatus_defaults().hang_length_m),
		"частичный блок: умолчание"
	)
	# за диапазоном — зажимается
	var c := FlightSettings.from_dict({"apparatus": {"hang_shift_cm": 99, "sail_flex": -3}})
	check(is_equal_approx(c.apparatus.hang_shift_cm, 4.0), "зажим сверху")
	check(is_equal_approx(c.apparatus.sail_flex, 0.1), "зажим снизу")
	check(s.duplicate().apparatus == s.apparatus, "duplicate сохраняет")
