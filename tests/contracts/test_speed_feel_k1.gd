extends TestCase
## Контракт SPF-К1 (docs/contracts/speed-feel.md): тряска buzz — версия в заголовке, ключи конфига.

const DOC := "res://docs/contracts/speed-feel.md"


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (SPF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("SPF-К1", 0) == 2, "SPF-К1 (v2) в заголовках: %s" % found)


func test_config_keys() -> void:
	var b: Dictionary = Config.get_config("flight").visual.buzz
	check(not b.has("speed_ratio_range"), "speed_ratio_range убран")
	var r: Variant = b.get("freq_ratio_range")
	check(r is Array and r.size() == 2, "freq_ratio_range: [min, max]")
	if r is Array and r.size() == 2:
		check(absf(float(r[0]) - 0.7) < 1e-6 and absf(float(r[1]) - 2.0) < 1e-6, "по умолчанию [0,7; 2,0]")
		var fmax := 0.0
		for f in b.freqs_hz:
			fmax = maxf(fmax, float(f))
		check(fmax * float(r[1]) <= 15.0, "max(freqs_hz)·r_max ≤ 15 Гц")
	check(float(b.max_m) > 0.0, "max_m задан")
	check(b.has("_doc") and b.has("freq_ratio_range_doc"), "документация ключа")
