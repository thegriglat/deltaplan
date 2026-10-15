extends TestCase
## Контракт SPF-К3 (docs/contracts/speed-feel.md): воздушная скорость → эоловый тон тросов.
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/speed-feel.md"


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/speed-feel.md читается")
	var re := RegEx.create_from_string("(?m)^## (SPF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("SPF-К3", 0) == 1, "SPF-К3 (v1) в заголовках: %s" % found)


func test_wire_tone_interface() -> void:
	var t := WireTone.new()
	for m in ["setup", "set_airspeed", "frequencies", "fill"]:
		check(t.has_method(m), "WireTone.%s" % m)
	var cfg: Dictionary = Config.get_config("audio").flight.airflow
	var wt: Dictionary = cfg.get("wire_tone", {})
	for k in ["strouhal", "diameters_m", "mix_rate_hz", "wander_frac", "env_hz", "env_depth"]:
		check(wt.has(k), "wire_tone.%s" % k)
		check(wt.has(k + "_doc"), "wire_tone.%s_doc" % k)
	t.setup(wt, 22050.0, 1)
	t.set_airspeed(10.0)
	check(t.frequencies().size() == wt.diameters_m.size(), "frequencies() — по числу тросов")
	check(t.fill(100).size() == 100, "fill(n) — n кадров")


func test_mix_contract() -> void:
	var cfg: Dictionary = Config.get_config("audio").flight
	check(not cfg.airflow.files.has("wires"), "files.wires убран")
	var m := FlightSoundMix.new()
	m.setup(cfg, 7)
	for kmh in [30.0, 55.0, 90.0]:
		m.airspeed_kmh = kmh
		var lv: Dictionary = m.compute()
		check(lv.has("wires"), "compute()[wires] есть на %d км/ч" % kmh)
		check(lv.wires.x < lv.rush.x, "wires.x < rush.x на %d км/ч" % kmh)
		check(is_equal_approx(lv.wires.y, 1.0), "wires pitch = 1")
	m.airspeed_kmh = 30.0
	check(m.compute().wires.x >= float(cfg.silence_db), "на 30 км/ч не ниже silence_db")
